"""Standalone mission recorder transport; shares the menu's existing bridge queue."""
from pathlib import Path
import time

HERE = Path(__file__).resolve().parent


def enable_command():
    script = ('local Telemetry=(function()\n' + (HERE/'ai_squadmates_telemetry.lua').read_text(encoding='utf-8') +
              '\nend)();local config={instance="' + str(time.time_ns()) + '"};\n' +
              (HERE/'gameplay_recorder.lua').read_text(encoding='utf-8'))
    if len(script.encode('utf-8')) >= 65536-512:
        raise ValueError('Gameplay recorder exceeds bridge capacity')
    return script


def collect(bridge, diagnostics, *, stop=False):
    journal = diagnostics.journal
    if stop:
        bridge.execute('local r=rawget(_G,"HelldiversGameplayRecorder");'
                       'if r then r.stop();rawset(_G,"HelldiversGameplayRecorderStopped",r) end;return "Recorder stopped"')
    for _ in range(512 if stop else 16):
        # Instance identifiers originate locally as numeric time_ns values.
        if not journal.instance.isdigit() and journal.instance:
            raise ValueError('Unexpected recorder instance')
        script = ('local r=rawget(_G,"HelldiversGameplayRecorder")' +
                  (' or rawget(_G,"HelldiversGameplayRecorderStopped")' if stop else '') +
                  ';if not r then return "MISSING" end;return r.telemetry(' +
                  str(journal.cursor) + ',"' + journal.instance + '")')
        reply = bridge.execute(script)
        if reply == 'MISSING':
            if stop: return
            raise RuntimeError('Gameplay recorder missing')
        result = journal.consume(reply, bridge.pid)
        if not result.get('has_more'): break
    if stop:
        if result.get('has_more'):
            journal.write({'kind':'drain_incomplete','source':'gameplay','cursor':journal.cursor})
            return
        bridge.execute('rawset(_G,"HelldiversGameplayRecorderStopped",nil);return "Recorder drained"')
