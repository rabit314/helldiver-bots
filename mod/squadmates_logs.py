"""Rotating AI diagnostic files beside the installed mod menu."""
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path
import json
import logging
import re
import struct
import time
import traceback
import uuid
from gameplay_storage import GameplayJournal,RECORDER_VERSION

FILES = {
    'events': ('AI_Squadmates_Events.jsonl', 2*1024*1024, 4),
    'behavior': ('AI_Squadmates_Behavior.jsonl', 4*1024*1024, 4),
    'errors': ('AI_Squadmates_Errors.jsonl', 1024*1024, 3),
    'stratagems': ('AI_Squadmates_Stratagems.jsonl', 2*1024*1024, 3),
    'navigation': ('AI_Squadmates_Navigation.jsonl', 1024*1024, 3),
}


def read_native_crash(path):
    """Read crash metadata only; no debugger, process injection or external tools."""
    path=Path(path)
    with path.open('rb') as stream:
        length=path.stat().st_size
        def read(at,size):
            if at<0 or size<0 or at+size>length:raise ValueError('Truncated minidump')
            stream.seek(at);data=stream.read(size)
            if len(data)!=size:raise ValueError('Truncated minidump')
            return data
        def unpack(fmt,at):
            return struct.unpack('<'+fmt,read(at,struct.calcsize('<'+fmt)))
        if read(0,4)!=b'MDMP':raise ValueError('Invalid minidump signature')
        count,directory=unpack('II',8)
        if count>4096:raise ValueError('Invalid minidump directory')
        entries={}
        for i in range(count):
            kind,size,rva=unpack('III',directory+12*i);entries[kind]=(rva,size)
        misc,_=entries[15];flags,pid=unpack('II',misc+4)
        if not flags&1:raise ValueError('Crash dump has no process identity')
        exception,_=entries[6]
        code=unpack('I',exception+8)[0];address=unpack('Q',exception+24)[0]
        mode=None;access=None
        if code==0xc0000005 and unpack('I',exception+32)[0]>=2:
            operation,access=unpack('QQ',exception+40)
            mode={0:'read',1:'write',8:'execute'}.get(operation,'unknown')
        modules,_=entries[4];number=unpack('I',modules)[0]
        if number>4096:raise ValueError('Invalid minidump module list')
        module=None;offset=None
        for i in range(number):
            entry=modules+4+108*i;base,size=unpack('QI',entry)
            if base<=address<base+size:
                name=unpack('I',entry+20)[0];size=unpack('I',name)[0]
                if size>65536:raise ValueError('Invalid minidump module name')
                module=Path(read(name+4,size).decode('utf-16-le')).name;offset=address-base;break
    return {'pid':pid,'dump':path.name,'dump_utc':datetime.fromtimestamp(path.stat().st_mtime,timezone.utc).isoformat(),
            'exception_code':hex(code),'fault_address':hex(address),'module':module,
            'module_offset':hex(offset) if offset is not None else None,
            'access_type':mode,'access_address':hex(access) if access is not None else None}


class StrictRotatingFileHandler(RotatingFileHandler):
    def handleError(self,record):
        raise


class Diagnostics:
    def __init__(self, directory, *, limits=None):
        self.directory=Path(directory)
        self.directory.mkdir(parents=True,exist_ok=True)
        self.controller_session=uuid.uuid4().hex
        self.journal=GameplayJournal(self.directory,self.controller_session)
        self.instance='';self.cursor=0;self.pid=None
        self.crashes_seen=set()
        self.loggers={}
        for channel,(name,size,backups) in FILES.items():
            if limits:size,backups=limits
            handler=StrictRotatingFileHandler(self.directory/name,maxBytes=size,backupCount=backups,encoding='utf-8')
            handler.setFormatter(logging.Formatter('%(message)s'))
            logger=logging.Logger('squadmates.'+channel+'.'+self.controller_session,logging.INFO)
            logger.propagate=False;logger.addHandler(handler)
            self.loggers[channel]=logger
        self.write('events',{'kind':'controller_started','data':{'format_version':2,'recorder_version':RECORDER_VERSION}})

    def write(self,channel,record):
        # Keep every line valid JSON; bound unusually long engine error strings.
        def bounded(v):
            if isinstance(v,str):return v[:3000]
            if isinstance(v,dict):return {str(k):bounded(x) for k,x in v.items()}
            if isinstance(v,list):return [bounded(x) for x in v]
            return v
        kind=record.get('kind','')
        if channel!='errors':
            if kind.startswith('stratagem_'):channel='stratagems'
            elif kind.startswith(('navigation_','route_','hidden_recovery_','rejoin_','foot_contact_')):channel='navigation'
        row=bounded(dict(record))
        row['log_stream']=channel
        row['utc']=datetime.now(timezone.utc).isoformat(timespec='milliseconds')
        row['controller_session']=self.controller_session
        self.loggers.get(channel,self.loggers['errors']).info(json.dumps(row,ensure_ascii=False,allow_nan=False,separators=(',',':')))
        # Surface filesystem errors to the menu instead of silently losing logs.
        for handler in self.loggers.get(channel,self.loggers['errors']).handlers:handler.flush()

    def consume(self,reply,pid):
        payload=json.loads(reply)
        instance=payload['instance']
        if pid!=self.pid or instance!=self.instance:
            self.pid=pid;self.instance=instance;self.cursor=0
            self.write('events',{'kind':'runtime_connected','pid':pid,'runtime':instance})
        if payload.get('gap'):
            self.write('errors',{'kind':'telemetry_gap','runtime':instance,'missing_records':payload['gap']})
        for record in payload['events']:
            if record['seq']<=self.cursor:continue
            self.write(record['channel'],{**record,'pid':pid,'runtime':instance})
            self.cursor=record['seq']
        self.cursor=max(self.cursor,payload['cursor'])
        return payload

    def error(self,kind,error):
        self.write('errors',{'kind':kind,'data':{'message':str(error),'traceback':traceback.format_exc()}})

    def record_native_crash(self,pid):
        if not pid:return
        for path in self.directory.glob('sse-*.dmp'):
            key=(path.name,path.stat().st_mtime_ns)
            if key in self.crashes_seen:continue
            try:report=read_native_crash(path)
            except (OSError,ValueError,KeyError,struct.error,UnicodeError):continue
            if report['pid']!=pid:continue
            self.write('errors',{'kind':'native_crash','pid':pid,'data':report})
            self.crashes_seen.add(key)

    def close(self):
        try:self.journal.close()
        finally:
            for logger in self.loggers.values():
                for handler in logger.handlers:handler.close()


def configure_controller_log(directory):
    handler=StrictRotatingFileHandler(Path(directory)/'LoneSurvivor.log',maxBytes=2*1024*1024,backupCount=3,encoding='utf-8')
    logging.basicConfig(handlers=[handler],level=logging.INFO,format='%(asctime)s %(message)s',force=True)
