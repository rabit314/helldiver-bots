"""Independent, bounded recorder streams. Only owned closed segments expire."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import time

MIB=1024*1024
RECORDER_VERSION='2.1'
# name: segment bytes, total bytes across sessions, maximum age in days
STREAM_LIMITS={
    'events':('Events',MIB,16*MIB,30),
    'combat':('Combat',4*MIB,48*MIB,7),
    'positions':('Positions',2*MIB,16*MIB,2),
    'errors':('Errors',MIB,8*MIB,30),
}
SESSION_RE=re.compile(r'\d{8}-\d{6}Z-[A-Za-z0-9]{1,64}')

def record_stream(row):
    kind=row.get('kind','')
    if kind=='retention_cleanup':
        owner=row.get('stream','').lower()
        if owner in STREAM_LIMITS:return owner
    if ('error' in kind or 'gap' in kind or kind in ('hook_unavailable','drain_incomplete')):
        return 'errors'
    if kind in ('positions','entity_no_longer_observed'):
        return 'positions'
    if kind in ('shot_fired','enemy_shot_fired','enemy_attack_started','weapon_activity'):
        return 'combat'
    if kind=='component_action' and (row.get('data') or {}).get('component') in (
            'HealthComponent','FirearmComponent','LauncherComponent','LauncherTurretComponent',
            'ArcweaponComponent','BeamweaponComponent','FlameweaponComponent','MeleeWeaponComponent','EnemyComponent'):
        return 'combat'
    return 'events'

class _Stream:
    def __init__(self,root,directory,prefix,segment_bytes,total_bytes,days):
        self.root=root;self.directory=directory;self.prefix=prefix
        self.segment_bytes=segment_bytes;self.total_limit=total_bytes
        self.max_age_seconds=days*86400;self.stream=None;self.size=0;self.part=0
        self.total_size=0;self.next_prune=0;self.notice=None
        self.pattern=re.compile(re.escape(prefix)+r'-\d{4,}\.jsonl')
        self.prune()

    def prune(self,incoming=0):
        files=[];total=0;now=time.time();removed=freed=failed=0
        active=Path(self.stream.name).resolve() if self.stream is not None else None
        for directory in self.root.iterdir():
            if not SESSION_RE.fullmatch(directory.name):continue
            if directory.is_symlink() or getattr(directory,'is_junction',lambda:False)() or not directory.is_dir():continue
            if directory.resolve().parent!=self.root:continue
            for path in directory.iterdir():
                if not self.pattern.fullmatch(path.name):continue
                if path.is_symlink() or not path.is_file() or path.resolve().parent!=directory.resolve():continue
                info=path.stat();total+=info.st_size;files.append((info.st_mtime,path,info.st_size))
        for modified,path,size in sorted(files):
            if now-modified<=self.max_age_seconds and total+incoming<=self.total_limit:continue
            if path.resolve()==active:continue
            try:
                if path.resolve().parent.parent!=self.root or path.is_symlink():continue
                path.unlink();total-=size;removed+=1;freed+=size
                if path.parent!=self.directory:
                    try:path.parent.rmdir()
                    except OSError:pass
            except OSError:failed+=1
        self.total_size=total;self.next_prune=time.monotonic()+60
        if removed or failed:
            self.notice=dict(kind='retention_cleanup',stream=self.prefix,segments_removed=removed,
                             bytes_freed=freed,locked_or_failed=failed)

    def write(self,encoded):
        if len(encoded)>self.total_limit:raise OSError(self.prefix+' log record exceeds storage limit')
        if self.stream is None or (self.size and self.size+len(encoded)>self.segment_bytes):
            if self.stream is not None:self.stream.close()
            self.part+=1;self.stream=(self.directory/f'{self.prefix}-{self.part:04d}.jsonl').open('xb');self.size=0
        if self.total_size+len(encoded)>self.total_limit or time.monotonic()>=self.next_prune:
            self.prune(len(encoded))
        if self.total_size+len(encoded)>self.total_limit:
            raise OSError(self.prefix+' log storage limit reached; old segments are locked or unavailable')
        written=self.stream.write(encoded)
        if written!=len(encoded):raise OSError('Incomplete '+self.prefix+' journal write')
        self.stream.flush();self.size+=written;self.total_size+=written

    def close(self):
        if self.stream is not None:self.stream.close();self.stream=None

class GameplayJournal:
    def __init__(self,directory,session,*,segment_bytes=None,total_bytes=None,max_age_days=None,limits=None):
        if not re.fullmatch(r'[A-Za-z0-9]{1,64}',session):raise ValueError('Invalid session identifier')
        expected=Path(directory).resolve()/'Gameplay_Logs';self.root=expected.resolve()
        if self.root!=expected or expected.is_symlink() or getattr(expected,'is_junction',lambda:False)():
            raise ValueError('Gameplay log folder must be a real folder directly inside the game folder')
        stamp=datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%SZ')
        self.directory=self.root/(stamp+'-'+session);self.directory.mkdir(parents=True,exist_ok=False)
        self.session=session;self.cursor=0;self.instance='';self.pid=None;self.closed=False
        policies=limits or STREAM_LIMITS
        self.streams={key:_Stream(self.root,self.directory,prefix,
                      segment_bytes if segment_bytes is not None else segment,
                      total_bytes if total_bytes is not None else total,
                      max_age_days if max_age_days is not None else days)
                      for key,(prefix,segment,total,days) in policies.items()}
        # Previously recorded files keep their existing 256 MiB/seven-day policy.
        # No new legacy files are created and no history is rewritten.
        legacy=_Stream(self.root,self.directory,'Gameplay',16*MIB,256*MIB,7)
        self.write(dict(kind='journal_started',format_version=3,recorder_version=RECORDER_VERSION,
                        streams={key:dict(prefix=s.prefix,segment_bytes=s.segment_bytes,
                                  total_bytes=s.total_limit,max_age_days=s.max_age_seconds/86400)
                                 for key,s in self.streams.items()},
                        squad_records='AI_Squadmates_*.jsonl; not duplicated here'))
        if legacy.notice:self.write(legacy.notice)

    @property
    def stream(self):return self.streams['events'].stream

    def write(self,record):
        if self.closed:raise OSError('Gameplay journal is closed')
        row=dict(record);key=record_stream(row);stream=self.streams[key]
        row.setdefault('utc',datetime.now(timezone.utc).isoformat(timespec='milliseconds'))
        row['controller_session']=self.session;row['log_stream']=key
        encoded=(json.dumps(row,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n').encode('utf-8')
        stream.write(encoded)
        if stream.notice:
            notice=stream.notice;stream.notice=None;self.write(notice)

    def consume(self,reply,pid):
        payload=json.loads(reply);instance=payload['instance'];dropped={}
        if pid!=self.pid or instance!=self.instance:
            self.pid=pid;self.instance=instance;self.cursor=0
            self.write(dict(kind='recorder_connected',pid=pid,runtime=instance))
        if payload.get('gap'):
            self.write(dict(kind='telemetry_gap',source='gameplay',runtime=instance,
                            missing_records=payload['gap'],pid=pid))
        for record in payload['events']:
            if record['seq']<=self.cursor:continue
            try:self.write({**record,'pid':pid,'runtime':instance,'source':'gameplay'})
            except OSError as exc:
                key=record_stream(record)
                if key=='errors':raise
                loss=dropped.setdefault(key,dict(count=0,first_seq=record['seq'],message=str(exc)))
                loss['count']+=1;loss['last_seq']=record['seq']
            self.cursor=record['seq']
        self.cursor=max(self.cursor,payload['cursor'])
        for key,loss in dropped.items():
            self.write(dict(kind='stream_storage_error',source='gameplay',stream=key,
                            runtime=instance,pid=pid,**loss))
        return payload

    def close(self):
        if self.closed:return
        try:self.write(dict(kind='journal_closed'))
        finally:
            self.closed=True
            for stream in self.streams.values():stream.close()
