"""Loader/diagnostics for the experimental HELLDIVERS companion squad."""
from pathlib import Path
import argparse
import re
import time
from game_path import game_directory

HERE = Path(__file__).resolve().parent
GAME = game_directory(HERE)
SOURCE_LIMIT = 0x10000 - 512  # Leave room for Bridge.execute's response wrapper.


def _bounded_source(script):
    if len(script.encode('utf-8')) >= SOURCE_LIMIT:
        raise ValueError('AI loader exceeds the bridge command capacity')
    return script


def _module_source(filename):
    source = (HERE / filename).read_text(encoding='utf-8')
    # Preserve multiline literals verbatim. Otherwise indentation, blank lines
    # and whole-line comments are safe to omit from the staged command.
    if re.search(r'\[=*\[|\\\r?\n', source):
        return source
    return '\n'.join(line.lstrip() for line in source.splitlines()
                     if line.strip() and not line.lstrip().startswith('--')) + '\n'


def ai_module_command():
    """Stage native Lua values through the bridge; the game has no loadstring."""
    modules = ''.join('local ' + symbol + '=(function()\n' +
                      _module_source(filename) + '\nend)();'
                      for symbol, filename in [('Behaviors', 'ai_squadmates_behaviors.lua'),
                                               ('Navigation', 'ai_squadmates_navigation.lua'),
                                               ('Support', 'ai_squadmates_support.lua'),
                                               ('Orders', 'ai_squadmates_orders.lua'),
                                               ('Takeover', 'ai_squadmates_takeover.lua'),
                                               ('CameraFocus', 'ai_squadmates_camera.lua'),
                                               ('Surface', 'ai_squadmates_surface.lua')])
    return _bounded_source(modules +
        'rawset(_G,"HelldiversSquadAIStage",{revision="0.23.1",Behaviors=Behaviors,'
        'Navigation=Navigation,Support=Support,Orders=Orders,Takeover=Takeover,CameraFocus=CameraFocus,Surface=Surface});return "AI modules staged"')


def ai_control_command():
    modules = ''.join('local ' + symbol + '=(function()\n' +
                      _module_source(filename) + '\nend)();'
                      for symbol, filename in [('Exosuit', 'ai_squadmates_exosuit.lua'),
                                               ('ExoNavigation', 'ai_squadmates_exo_navigation.lua'),
                                               ('Vehicles', 'ai_squadmates_vehicles.lua'),
                                               ('RandomLoadout', 'ai_squadmates_random.lua'),
                                               ('Core', 'ai_squadmates_core.lua'),
                                               ('Loadouts', 'ai_squadmates_loadouts.lua'),
                                               ('Telemetry', 'ai_squadmates_telemetry.lua')])
    return _bounded_source(modules +
        'local s=assert(rawget(_G,"HelldiversSquadAIStage"));assert(s.revision=="0.23.1");'
        's.Exosuit=Exosuit;s.ExoNavigation=ExoNavigation;s.RandomLoadout=RandomLoadout;'
        's.Vehicles=Vehicles;s.Core=Core;s.Loadouts=Loadouts;s.Telemetry=Telemetry;s.controls=true;return "AI controls staged"')


def ai_recovery_command():
    modules = ''.join('local ' + symbol + '=(function()\n' +
                      _module_source(filename) + '\nend)();'
                      for symbol, filename in [('Recovery', 'ai_squadmates_recovery.lua'),
                                               ('Rejoin', 'ai_squadmates_rejoin.lua'),
                                               ('TerminalLifecycle', 'ai_squadmates_terminal_lifecycle.lua')])
    return _bounded_source(modules +
        'local s=assert(rawget(_G,"HelldiversSquadAIStage"));assert(s.revision=="0.23.1");'
        's.Recovery=Recovery;s.Rejoin=Rejoin;s.TerminalLifecycle=TerminalLifecycle;s.recovery=true;return "AI recovery staged"')


def ai_mobility_command():
    modules = ''.join('local ' + symbol + '=(function()\n' +
                      _module_source(filename) + '\nend)();'
                      for symbol, filename in [('Mobility', 'ai_squadmates_mobility.lua'),
                                               ('Extraction', 'ai_squadmates_extraction.lua'),
                                               ('ActionSafety', 'ai_squadmates_action_safety.lua'),
                                               ('Grenades', 'ai_squadmates_grenades.lua'),
                                               ('Companion', 'ai_squadmates_companion.lua'),
                                               ('SeatPolicy', 'ai_squadmates_seat_policy.lua'),
                                               ('Display', 'ai_squadmates_display.lua')])
    return _bounded_source(modules +
        'local s=assert(rawget(_G,"HelldiversSquadAIStage"));assert(s.revision=="0.23.1");'
        's.Mobility=Mobility;s.Extraction=Extraction;s.ActionSafety=ActionSafety;s.Grenades=Grenades;s.Companion=Companion;s.SeatPolicy=SeatPolicy;s.Display=Display;s.mobility=true;return "AI mobility staged"')


def ai_task_command():
    modules = ''.join('local ' + symbol + '=(function()\n' +
                      _module_source(filename) + '\nend)();'
                      for symbol, filename in [('Perimeter', 'ai_squadmates_perimeter.lua'),
                                               ('Objectives', 'ai_squadmates_objectives.lua'),
                                               ('Interactions', 'ai_squadmates_interactions.lua'),
                                               ('NavTrace', 'ai_squadmates_navtrace.lua')])
    return _bounded_source(modules +
        'local s=assert(rawget(_G,"HelldiversSquadAIStage"));assert(s.revision=="0.23.1");'
        's.Perimeter=Perimeter;s.Objectives=Objectives;s.Interactions=Interactions;s.NavTrace=NavTrace;s.tasks=true;return "AI tasks staged"')


def ai_tactics_command():
    modules = ''.join('local ' + symbol + '=(function()\n' +
                      _module_source(filename) + '\nend)();'
                      for symbol, filename in [('StratagemModel', 'ai_squadmates_stratagem_model.lua'),
                                               ('StratagemTactics', 'ai_squadmates_stratagem_tactics.lua')])
    return _bounded_source(modules +
        'local s=assert(rawget(_G,"HelldiversSquadAIStage"));assert(s.revision=="0.23.1");'
        's.StratagemModel=StratagemModel;'
        's.StratagemTactics=StratagemTactics;return "AI tactics staged"')


def ai_readiness_command():
    modules = ''.join('local ' + symbol + '=(function()\n' +
                      _module_source(filename) + '\nend)();'
                      for symbol, filename in [('StratagemNative', 'ai_squadmates_stratagem_native.lua'),
                                               ('Readiness', 'ai_squadmates_readiness.lua')])
    return _bounded_source(modules +
        'local s=assert(rawget(_G,"HelldiversSquadAIStage"));assert(s.revision=="0.23.1");'
        's.StratagemNative=StratagemNative;s.Readiness=Readiness;'
        's.readiness=true;return "AI readiness staged"')


def ai_equipment_command():
    modules = ''.join('local ' + symbol + '=(function()\n' + _module_source(filename) + '\nend)();'
                      for symbol, filename in [('StratagemFamilies', 'ai_squadmates_stratagem_families.lua'),
                                               ('OrderInheritance', 'ai_squadmates_order_inheritance.lua'),
                                               ('Equipment', 'ai_squadmates_equipment.lua')])
    return _bounded_source(modules + 'local s=assert(rawget(_G,"HelldiversSquadAIStage"));'
                           's.StratagemFamilies=StratagemFamilies;s.OrderInheritance=OrderInheritance;s.Equipment=Equipment;s.equipment=true;return "AI equipment staged"')


def enable_ai(bridge, *, auto_deploy=False, target_count=3, seed=None):
    # Validate every command before sending any. The existing menu worker and
    # bridge serialize them; only proceed when the staging command succeeds.
    modules = ai_module_command()
    controls = ai_control_command()
    recovery = ai_recovery_command()
    tasks = ai_task_command()
    tactics = ai_tactics_command()
    readiness = ai_readiness_command()
    mobility = ai_mobility_command()
    equipment = ai_equipment_command()
    runtime = ai_command(True, auto_deploy=auto_deploy, target_count=target_count, seed=seed)
    bridge.execute(modules)
    bridge.execute(controls)
    bridge.execute(recovery)
    bridge.execute(tasks)
    bridge.execute(tactics)
    bridge.execute(readiness)
    bridge.execute(mobility)
    bridge.execute(equipment)
    return bridge.execute(runtime)


def ai_command(enabled, *, auto_deploy=False, target_count=3, seed=None):
    if not enabled:
        return ('local m=rawget(_G,"HelldiversSquadAI"); '
                'if m then m.disable("Disabled from controller");return m.status() end;return "AI disabled"')
    runtime = _module_source('ai_squadmates.lua')
    if seed is None:
        seed = time.time_ns() % 2147483647
    seed = int(seed) % 2147483647
    migration = ('local previous=rawget(_G,"HelldiversSquadAI");'
                 'if previous and previous.revision~="0.23.1" then '
                 'previous.uninstall();rawset(_G,"HelldiversSquadAI",nil) end;\n')
    staged = ('local stage=rawget(_G,"HelldiversSquadAIStage");'
              'assert(stage and stage.revision=="0.23.1" and stage.controls and stage.tasks and stage.recovery and stage.mobility,"AI modules must be staged before enabling");'
              'local Behaviors,Navigation,Support,Perimeter,Orders,Takeover,Objectives=stage.Behaviors,stage.Navigation,stage.Support,stage.Perimeter,stage.Orders,stage.Takeover,stage.Objectives;'
              'local RandomLoadout,Telemetry,Vehicles,CameraFocus=stage.RandomLoadout,stage.Telemetry,stage.Vehicles,stage.CameraFocus;')
    script = (staged + migration + 'local Core=assert(stage.Core);local Loadouts=assert(stage.Loadouts);'
              'local config={enabled=true,auto_deploy=' + str(bool(auto_deploy)).lower()
              + ',target_count=' + str(squad_settings({'squad_target_count': target_count})['squad_target_count'])
              + ',seed=' + str(seed) + ',instance="' + str(time.time_ns()) + '"};\n' + runtime)
    return _bounded_source(script)


def squad_settings(saved):
    saved = saved if isinstance(saved, dict) else {}
    target = saved.get('squad_target_count', 3)
    if isinstance(target, bool) or not isinstance(target, (int, float)) or not 1 <= target < float('inf') or int(target) != target:
        target = 3
    return {'squad_auto_deploy': saved.get('squad_auto_deploy') is True, 'squad_target_count': int(target)}


def configure_command(settings, *, resume=False):
    options = squad_settings(settings)
    return ('local m=rawget(_G,"HelldiversSquadAI");if not m or not m.set_auto_deploy then return "AI not loaded" end;'
            + ('m.auto_paused=nil;' if resume and options['squad_auto_deploy'] else '')
            + 'm.heartbeat=0;return m.set_auto_deploy(' + str(options['squad_auto_deploy']).lower() + ','
            + str(options['squad_target_count']) + ')')


def dismiss_command():
    return 'local m=rawget(_G,"HelldiversSquadAI");if not m then return "AI not loaded" end;return m.dismiss()'


def status_command(heartbeat=False):
    return ('local m=rawget(_G,"HelldiversSquadAI");if not m then return "AI not loaded" end;'
            + ('m.heartbeat=0;' if heartbeat else '') + 'return m.status()')


def deploy_command():
    return ('local m=rawget(_G,"HelldiversSquadAI");if not m then return "AI not loaded" end;'
            'm.heartbeat=0;return m.request_deploy()')


def order_command(action):
    if action not in ('guard_bot', 'recall_bot', 'recall_all', 'original_player', 'switch_bot', 'home_player'):
        raise ValueError('Unknown squad order')
    method = {'guard_bot': 'request_guard()', 'recall_bot': 'request_follow(false)',
              'recall_all': 'request_follow(true)',
              'original_player': 'request_original()', 'switch_bot': 'request_switch(false)',
              'home_player': 'request_switch(true)'}[action]
    return ('local m=rawget(_G,"HelldiversSquadAI");if not m then return "Deploy a bot first (F6)" end;'
            'm.heartbeat=0;return m.' + method)


def telemetry_command(cursor=0, instance=''):
    import re
    if not re.fullmatch(r'[0-9]*',str(instance)):
        raise ValueError('Unexpected runtime instance identifier')
    return ('local m=rawget(_G,"HelldiversSquadAI");'
            'if not m or not m.telemetry then return '
            '\'{"instance":"0","cursor":0,"gap":0,"has_more":false,"events":[],"status":"AI runtime missing"}\' end;'
            'm.heartbeat=0;return m.telemetry(' + str(max(0,int(cursor))) + ',"' + str(instance) + '",48)')


def collect_telemetry(bridge, diagnostics, *, drain=False):
    result=None
    for _ in range(64 if drain else 4):
        reply=bridge.execute(telemetry_command(diagnostics.cursor,diagnostics.instance))
        result=diagnostics.consume(reply,bridge.pid)
        if not result.get('has_more'):break
    return result['status']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['enable', 'deploy', 'disable', 'status', 'events', 'watch', 'unload'])
    parser.add_argument('--seconds', type=float, default=0,
                        help='Bounded watch duration; zero waits until Ctrl+C')
    parser.add_argument('--auto-deploy', action='store_true', help='Deploy at mission start (diagnostic mode)')
    args = parser.parse_args()
    # Importing the bridge declares Windows APIs but does not attach by itself.
    from lone_survivor import Bridge
    from squadmates_logs import Diagnostics
    b = Bridge(GAME)
    diagnostics=Diagnostics(GAME)
    try:
        if not b.attach():
            raise RuntimeError('The x64 game is not running')
        if args.action in ('enable', 'deploy', 'watch'):
            print(enable_ai(b, auto_deploy=args.auto_deploy), flush=True)
            if args.action == 'deploy':
                print(b.execute(deploy_command()), flush=True)
        elif args.action == 'disable':
            print(b.execute(ai_command(False)), flush=True)
        elif args.action == 'events':
            print(b.execute('local m=rawget(_G,"HelldiversSquadAI");return m and table.concat(m.events,"\\n") or "AI not loaded"'), flush=True)
        elif args.action == 'unload':
            print(b.execute('local m=rawget(_G,"HelldiversSquadAI");return m and m.uninstall() or "AI not loaded"'), flush=True)
        else:
            print(b.execute(status_command()), flush=True)
        collect_telemetry(b,diagnostics,drain=True)
        if args.action == 'watch':
            end = time.monotonic() + args.seconds if args.seconds > 0 else float('inf')
            last = None
            try:
                while b.running() and time.monotonic() < end:
                    reply = collect_telemetry(b,diagnostics)
                    if reply != last:
                        print(reply, flush=True)
                        last = reply
                    time.sleep(1)
            except KeyboardInterrupt:
                pass
            finally:
                if b.running():
                    print(b.execute(ai_command(False)), flush=True)
                    collect_telemetry(b,diagnostics,drain=True)
    except Exception as exc:
        diagnostics.error('cli_error',exc)
        if not b.running():diagnostics.record_native_crash(b.pid)
        raise
    finally:
        b.disconnect()
        diagnostics.close()


if __name__ == '__main__':
    main()
