"""Checked, synchronous Lua bridge for the Windows x64 HELLDIVERS executable."""
import ctypes as C
from ctypes import wintypes as W
from pathlib import Path
import struct
import threading
import time
import os

k = C.WinDLL('kernel32', use_last_error=True)
INVALID = C.c_void_p(-1).value
class ProcessEntry(C.Structure):
    _fields_ = [('size',W.DWORD),('usage',W.DWORD),('pid',W.DWORD),('heap',C.c_size_t),('module',W.DWORD),('threads',W.DWORD),('parent',W.DWORD),('priority',W.LONG),('flags',W.DWORD),('name',W.CHAR*260)]
class ModuleEntry(C.Structure):
    _fields_ = [('size',W.DWORD),('id',W.DWORD),('pid',W.DWORD),('global_count',W.DWORD),('process_count',W.DWORD),('base',C.c_void_p),('length',W.DWORD),('module',W.HMODULE),('name',W.CHAR*256),('path',W.CHAR*260)]
def api(name,restype,args):
    fn=getattr(k,name);fn.restype=restype;fn.argtypes=args;return fn
snapshot=api('CreateToolhelp32Snapshot',W.HANDLE,[W.DWORD,W.DWORD])
pfirst=api('Process32First',W.BOOL,[W.HANDLE,C.POINTER(ProcessEntry)])
pnext=api('Process32Next',W.BOOL,[W.HANDLE,C.POINTER(ProcessEntry)])
mfirst=api('Module32First',W.BOOL,[W.HANDLE,C.POINTER(ModuleEntry)])
mnext=api('Module32Next',W.BOOL,[W.HANDLE,C.POINTER(ModuleEntry)])
open_process=api('OpenProcess',W.HANDLE,[W.DWORD,W.BOOL,W.DWORD])
close=api('CloseHandle',W.BOOL,[W.HANDLE])
read_mem=api('ReadProcessMemory',W.BOOL,[W.HANDLE,C.c_void_p,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)])
write_mem=api('WriteProcessMemory',W.BOOL,[W.HANDLE,C.c_void_p,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)])
alloc=api('VirtualAllocEx',C.c_void_p,[W.HANDLE,C.c_void_p,C.c_size_t,W.DWORD,W.DWORD])
protect=api('VirtualProtectEx',W.BOOL,[W.HANDLE,C.c_void_p,C.c_size_t,W.DWORD,C.POINTER(W.DWORD)])
flush=api('FlushInstructionCache',W.BOOL,[W.HANDLE,C.c_void_p,C.c_size_t])
exit_code=api('GetExitCodeProcess',W.BOOL,[W.HANDLE,C.POINTER(W.DWORD)])
query_path=api('QueryFullProcessImageNameW',W.BOOL,[W.HANDLE,W.DWORD,W.LPWSTR,C.POINTER(W.DWORD)])

SIGNATURES={
    'gettop': bytes.fromhex('48 8b 41 18 48 2b 41 10 48 c1 f8 03 c3'),
    'loadstring': bytes.fromhex('40 57 48 83 ec 30 4c 8b d1'),
    'pcall': bytes.fromhex('48 89 5c 24 08 57 48 83 ec 20 8b 59 08 4c 8b'),
    'settop': bytes.fromhex('40 53 48 83 ec 20 48 8b d9 85'),
}

def scan_executable(path):
    """Translate file positions to RVAs through the PE section table."""
    data=Path(path).read_bytes()
    if data[:2]!=b'MZ': raise RuntimeError('Target is not a PE executable.')
    pe=struct.unpack_from('<I',data,60)[0]
    if data[pe:pe+4]!=b'PE\0\0' or struct.unpack_from('<H',data,pe+4)[0]!=0x8664:
        raise RuntimeError('Use the x64 version of HELLDIVERS.')
    count=struct.unpack_from('<H',data,pe+6)[0]
    optsize=struct.unpack_from('<H',data,pe+20)[0]
    sections=[]
    for n in range(count):
        off=pe+24+optsize+n*40
        size,rva,rawsize,raw=struct.unpack_from('<IIII',data,off+8)
        flags=struct.unpack_from('<I',data,off+36)[0]
        if flags&0x20000000: sections.append((rva,raw,data[raw:raw+rawsize]))
    found={}
    for name,pattern in SIGNATURES.items():
        hits=[]
        for rva,raw,blob in sections:
            start=0
            while (pos:=blob.find(pattern,start))>=0:
                hits.append(rva+pos);start=pos+1
        if len(hits)!=1:raise RuntimeError(f'Unsupported game build: {name} has {len(hits)} matches.')
        found[name]=hits[0]
    return found

class Assembler:
    def __init__(self,base):self.base=base;self.code=bytearray();self.labels={};self.fixups=[]
    def emit(self,s):self.code.extend(bytes.fromhex(s) if isinstance(s,str) else s)
    def rip(self,prefix,target,suffix=b''):
        prefix=bytes.fromhex(prefix);rel=target-(self.base+len(self.code)+len(prefix)+4+len(suffix))
        self.emit(prefix+struct.pack('<i',rel)+suffix)
    def call(self,addr):self.rip('e8',addr)
    def branch(self,opcode,label):
        self.emit(opcode);self.fixups.append((len(self.code),label));self.emit(b'\0'*4)
    def label(self,name):self.labels[name]=len(self.code)
    def finish(self):
        for pos,label in self.fixups:struct.pack_into('<i',self.code,pos,self.labels[label]-pos-4)
        return bytes(self.code)

class Bridge:
    SIZE=0x12000
    CODE=0x200
    COMMAND=0x1000
    CAPACITY=0x10000
    MAGIC=b'LONESURVIVOR2\0\0\0'
    def __init__(self,game_dir=None):
        self.game_dir=Path(game_dir).resolve() if game_dir else None
        self.handle=None;self.pid=None;self.base=None;self.remote=None
        self.lock=threading.RLock();self.functions={};self.path=None
    def read(self,addr,size):
        data=C.create_string_buffer(size);done=C.c_size_t()
        if not read_mem(self.handle,addr,data,size,C.byref(done)) or done.value!=size:
            raise OSError(C.get_last_error(),f'Cannot read game memory at {addr:x}.')
        return data.raw
    def write(self,addr,data,verify=True):
        done=C.c_size_t();buf=C.create_string_buffer(data)
        if not write_mem(self.handle,addr,buf,len(data),C.byref(done)) or done.value!=len(data):
            raise OSError(C.get_last_error(),'Cannot write game memory.')
        if verify and self.read(addr,len(data))!=data:raise RuntimeError('Game memory write did not verify.')
    def running(self):
        status=W.DWORD()
        return bool(self.handle and exit_code(self.handle,C.byref(status)) and status.value==259)
    def disconnect(self):
        if self.handle:close(self.handle)
        self.handle=None;self.pid=None;self.remote=None;self.base=None
    def attach(self):
        with self.lock:
            if self.running():return True
            self.disconnect()
            snap=snapshot(2,0)
            if snap==INVALID:raise C.WinError(C.get_last_error())
            candidates=[]
            try:
                entry=ProcessEntry();entry.size=C.sizeof(entry);ok=pfirst(snap,C.byref(entry))
                while ok:
                    # The old substring check attached to Start HELLDIVERS.exe.
                    if entry.name.decode(errors='replace').lower()=='helldivers.exe':candidates.append(entry.pid)
                    ok=pnext(snap,C.byref(entry))
            finally:close(snap)
            for pid in candidates:
                handle=open_process(0x438,False,pid)
                if not handle:raise C.WinError(C.get_last_error())
                pathbuf=C.create_unicode_buffer(32768);length=W.DWORD(len(pathbuf))
                if not query_path(handle,0,pathbuf,C.byref(length)):
                    close(handle);continue
                path=Path(pathbuf.value)
                if self.game_dir and path.resolve()!=self.game_dir/'binaries'/'x64'/'helldivers.exe':
                    close(handle);continue
                mods=snapshot(0x18,pid)
                if mods==INVALID:close(handle);raise C.WinError(C.get_last_error())
                try:
                    me=ModuleEntry();me.size=C.sizeof(me);ok=mfirst(mods,C.byref(me));base=None
                    while ok:
                        if me.name.decode(errors='replace').lower()=='helldivers.exe':base=me.base;break
                        ok=mnext(mods,C.byref(me))
                finally:close(mods)
                if not base:close(handle);continue
                self.handle=handle;self.pid=pid;self.base=base;self.path=path
                self.functions={n:base+rva for n,rva in scan_executable(path).items()}
                return True
            return False
    def _hook(self,remote):
        a=Assembler(remote+self.CODE)
        # Entry is gettop+4, after mov rax,[rcx+18].
        a.emit('48 2b 41 10 48 c1 f8 03')
        # Preserve volatile registers, flags, and XMM0..5. Win64 call alignment
        # and 32 bytes of shadow space are preserved for every Lua API call.
        a.emit('9c 50 51 52 41 50 41 51 41 52 41 53 53 48 81 ec a0 00 00 00')
        for i in range(6):a.emit(bytes([0xf3,0x0f,0x7f,0x44+i*8,0x24,0x20+i*16]))
        a.emit('b8 01 00 00 00 b2 02');a.rip('f0 0f b0 15',remote)
        a.branch(bytes.fromhex('0f 85'),'exit')
        a.rip('48 89 0d',remote+8)
        a.emit('48 8b 41 18 48 2b 41 10 48 c1 f8 03');a.rip('48 89 05',remote+16)
        # This build disables text and bytecode loaders after startup. Save and
        # restore those two flags within the same game-thread command.
        a.emit('8b 41 08 0f b7 90 98 01 00 00');a.rip('66 89 15',remote+112)
        a.emit('66 c7 80 98 01 00 00 00 00')
        a.rip('48 8b 15',remote+104)
        a.rip('4c 8b 05',remote+48);a.rip('4c 8d 0d',remote+80)
        a.emit('48 8b d9');a.call(self.functions['loadstring']-0x20)
        a.rip('89 05',remote+24)
        a.rip('48 8b 0d',remote+8);a.emit('8b 51 08');a.rip('66 44 8b 05',remote+112)
        a.emit('66 44 89 82 98 01 00 00');a.rip('8b 05',remote+24)
        a.emit('85 c0');a.branch(bytes.fromhex('0f 85'),'result')
        a.rip('48 8b 0d',remote+8);a.emit('31 d2 41 b8 01 00 00 00 45 31 c9')
        a.emit('48 8b d9');a.call(self.functions['pcall']);a.rip('89 05',remote+24)
        a.label('result')
        a.rip('48 8b 0d',remote+8);a.emit('48 8b 41 18 48 8b 40 f8');a.rip('48 89 05',remote+32)
        a.rip('48 8b 15',remote+16);a.emit('48 8b c1');a.call(self.functions['settop'])
        a.rip('c6 05',remote,b'\x03')
        a.label('exit')
        for i in range(6):a.emit(bytes([0xf3,0x0f,0x6f,0x44+i*8,0x24,0x20+i*16]))
        a.emit('48 81 c4 a0 00 00 00 5b 41 5b 41 5a 41 59 41 58 5a 59 58 9d c3')
        return a.finish()
    def install(self):
        with self.lock:
            if not self.running():raise RuntimeError('HELDIVERS is not running.')
            if self.remote:return
            target=self.functions['gettop']+4
            current=self.read(target,8)
            if current[0]==0xe9:
                code=target+5+struct.unpack_from('<i',current,1)[0];remote=code-self.CODE
                if self.read(remote+64,16)!=self.MAGIC or self.read(code,len(self._hook(remote)))!=self._hook(remote):
                    raise RuntimeError('Another trainer owns the Lua hook. Restart the game and close the old trainer.')
                self.remote=remote;return
            if current!=SIGNATURES['gettop'][4:12]:raise RuntimeError('Lua entry point was modified. Restart the game.')
            for name in ['loadstring','pcall','settop']:
                if self.read(self.functions[name],len(SIGNATURES[name]))!=SIGNATURES[name]:
                    raise RuntimeError(f'{name} signature does not match the running game.')
            for delta,pattern in [(0x4c3,'80 b8 98 01 00 00 00'),(0x4aa,'80 b8 99 01 00 00 00'),(0x20,'48 83 ec 38 48 c7 44 24 20 00 00 00 00')]:
                expected=bytes.fromhex(pattern)
                if self.read(self.functions['loadstring']-delta,len(expected))!=expected:
                    raise RuntimeError('Unsupported Lua loader layout. No hook installed.')
            # Windows allocations use 64 KiB granularity, not arbitrary addresses.
            center=target&~0xffff;remote=None
            for off in range(0x10000,0x70000000,0x10000):
                for candidate in (center-off,center+off):
                    if candidate<=0:continue
                    remote=alloc(self.handle,candidate,self.SIZE,0x3000,0x40)
                    if remote:break
                if remote:break
            if not remote:raise C.WinError(C.get_last_error())
            self.write(remote,b'\0'*80);self.write(remote+64,self.MAGIC)
            code=self._hook(remote);self.write(remote+self.CODE,code)
            patch=b'\xe9'+struct.pack('<i',remote+self.CODE-target-5)+b'\x90'*3
            old=W.DWORD()
            if not protect(self.handle,target,8,0x40,C.byref(old)):raise C.WinError(C.get_last_error())
            try:self.write(target,patch);flush(self.handle,target,8)
            finally:
                unused=W.DWORD();protect(self.handle,target,8,old.value,C.byref(unused))
            self.remote=remote
    def execute(self,script,timeout=8):
        # Pin the response in Lua until the next command, including runtime errors.
        script='local ok,v=pcall(function()\n'+script+'\nend); __LoneSurvivorReply=(ok and "OK|" or "ERROR|")..tostring(v); return __LoneSurvivorReply'
        data=script.encode('utf-8')+b'\0'
        if len(data)>self.CAPACITY:raise ValueError(f'Lua command exceeds {self.CAPACITY-1} bytes; nothing sent.')
        with self.lock:
            self.install()
            state=self.read(self.remote,1)[0]
            if state in (1,2):raise RuntimeError('Previous command is still pending. Resume the game or restart it.')
            self.write(self.remote+self.COMMAND,data)
            self.write(self.remote+104,struct.pack('<Q',self.remote+self.COMMAND))
            self.write(self.remote+48,struct.pack('<Q',len(data)-1));self.write(self.remote+80,b'LoneSurvivor\0')
            self.write(self.remote+24,struct.pack('<i',-999))
            # The game may claim the command before a read-back; acknowledge via
            # the completion protocol instead of comparing this volatile flag.
            self.write(self.remote,b'\x01',verify=False)
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                if not self.running():raise RuntimeError('Game exited while executing Lua.')
                if self.read(self.remote,1)==b'\x03':
                    status=struct.unpack('<i',self.read(self.remote+24,4))[0]
                    value=self.read(self.remote+32,8)
                    ptr,tag=struct.unpack('<II',value)
                    result=None
                    if tag==0xfffffffb and ptr:
                        size=struct.unpack('<I',self.read(ptr+12,4))[0]
                        if size<=200000:result=self.read(ptr+16,size).decode('utf-8',errors='replace')
                    if status:raise RuntimeError(f'Lua error ({status}): {result or value.hex()}')
                    if result is None:raise RuntimeError('Lua ran but did not return a verification message.')
                    if result.startswith('ERROR|'):raise RuntimeError(result[6:])
                    if not result.startswith('OK|'):raise RuntimeError('Unrecognized Lua response: '+result)
                    return result[3:]
                time.sleep(.01)
            raise TimeoutError('Game did not acknowledge the command. No success was reported; resume the game and retry.')

DEFAULT_SETTINGS=dict(stratagems=True,autoreload=True,stamina=True,playerhealth=True,
                      playerrespawns=True,playergrenades=True,rewards=True,
                      health_multiplier=2.5,respawn_count=4,grenade_count=3,multiplier=3)
NUMERIC_SETTINGS={'health_multiplier':(2.5,.5),'respawn_count':(4,1),
                  'grenade_count':(3,1),'multiplier':(3,1)}


def setting_number(key,value):
    import math
    step=NUMERIC_SETTINGS[key][1]
    try:number=float(value)
    except (TypeError,ValueError,OverflowError):raise ValueError('Invalid '+key)
    if isinstance(value,bool) or not math.isfinite(number) or not 1<=number<=10 or number/step!=round(number/step):
        raise ValueError('Invalid '+key+': expected 1 to 10 in steps of '+str(step))
    return number if step!=1 else int(number)


def menu_settings(saved):
    """Migrate the former shared supplies switch; tolerate malformed saved values."""
    settings=DEFAULT_SETTINGS.copy()
    if not isinstance(saved,dict):return settings
    saved=saved.copy()
    for key in ('playerrespawns','playergrenades'):
        if key not in saved and isinstance(saved.get('playersupplies'),bool):saved[key]=saved['playersupplies']
    for key,default in settings.items():
        if key in NUMERIC_SETTINGS:
            try:settings[key]=setting_number(key,saved.get(key,default))
            except ValueError:pass
        elif isinstance(saved.get(key),bool):settings[key]=saved[key]
    return settings


def pause_command(enabled=True):
    pause = Path(__file__).with_name('offline_pause.lua').read_text(encoding='utf-8')
    return ('local p=(function()\n' + pause + '\nend)();p.set_enabled(' + str(bool(enabled)).lower()
            + ');p.sync();return "Offline pause "..p.revision..": "..tostring(p.status)')


def lua_command(settings, *, offline_pause=True):
    # Only validated numeric primitives and literal booleans enter Lua source.
    numbers={key:setting_number(key,settings.get(key,1 if key=='multiplier' else default)) for key,(default,step) in NUMERIC_SETTINGS.items()}
    flags={key:settings.get(key,settings.get('playersupplies',False)) if key in ('playerrespawns','playergrenades')
           else settings.get(key,False) for key in ('stratagems','autoreload','stamina','playerhealth','playerrespawns','playergrenades')}
    numbers['multiplier']=numbers['multiplier'] if settings.get('rewards',True) else 1
    values=','.join(key+'='+('true' if value else 'false') for key,value in flags.items())
    values+=','+','.join(key+'='+str(value) for key,value in numbers.items())
    health=Path(__file__).with_name('player_health.lua').read_text(encoding='utf-8')
    supplies=Path(__file__).with_name('player_supplies.lua').read_text(encoding='utf-8')
    pause=Path(__file__).with_name('offline_pause.lua').read_text(encoding='utf-8')
    return ('local config={'+values+'};\nlocal OfflinePause=(function()\n'+pause+'\nend)();'
            +'OfflinePause.set_enabled('+str(bool(offline_pause)).lower()+');\nlocal PlayerHealth=(function()\n'+health+'\nend)();\n'
            +'local PlayerSupplies=(function()\n'+supplies+'\nend)();\n'
            +'local result=(function()\n'+Path(__file__).with_name('lone_survivor.lua').read_text(encoding='utf-8')
            +'\nend)();return result.."\\nMain player health: "..(PlayerHealth.enabled and tostring(PlayerHealth.multiplier).."x" or "normal")'
            +'.."\\nRespawns: "..(PlayerSupplies.respawns_enabled and tostring(PlayerSupplies.respawn_count) or "normal")'
            +'.."\\nGrenades: "..(PlayerSupplies.grenades_enabled and tostring(PlayerSupplies.grenade_count) or "normal")')
