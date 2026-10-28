"""Foreground-only squad controls, serialized through the menu's bridge queue."""

import time


class HotkeyEdges:
    def __init__(self):
        self.previous = {'deploy_bot': False, 'dismiss_bot': False, 'guard_bot': False,
                         'original_player': False, 'switch_bot': False}
        self.holds = {}

    def _gesture(self, key, down, focused, now, tap, hold):
        if not focused:
            self.holds.pop(key, None)
            return []
        if down and not self.previous[key]:
            self.holds[key] = (now, False)
        pending = self.holds.get(key)
        if pending is None:
            return []
        started, sent = pending
        actions = []
        if now - started >= .7 and not sent:
            actions.append(hold)
            sent = True
        if not down:
            if not sent:
                actions.append(tap)
            self.holds.pop(key, None)
        else:
            self.holds[key] = (started, sent)
        return actions

    def update(self, *, focused, deploy_down, dismiss_down, guard_down=False, recall_down=False,
               original_down=False, now=None):
        now = time.monotonic() if now is None else now
        current = {'deploy_bot': bool(deploy_down), 'dismiss_bot': bool(dismiss_down),
                   'guard_bot': bool(guard_down), 'original_player': bool(original_down),
                   'switch_bot': bool(recall_down)}
        actions = self._gesture('dismiss_bot', dismiss_down, focused, now,
                                'dismiss_bot', 'auto_deploy_off')
        # F7 cancels other in-progress gestures, including on its release frame.
        controls_allowed = focused and not dismiss_down and not actions
        for key, tap, hold in [('deploy_bot', 'deploy_bot', 'auto_deploy_on'),
                               ('guard_bot', 'guard_bot', 'recall_all'),
                               ('switch_bot', 'switch_bot', 'home_player')]:
            actions.extend(self._gesture(key, current[key], controls_allowed, now, tap, hold))
        if controls_allowed and original_down and not self.previous['original_player']:
            actions.append('original_player')
        self.previous = current
        return actions


class GameHotkeys:
    def __init__(self):
        import ctypes
        from ctypes import wintypes
        self.ctypes = ctypes
        self.wintypes = wintypes
        self.user32 = ctypes.WinDLL('user32', use_last_error=True)
        self.user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
        self.user32.GetAsyncKeyState.restype = wintypes.SHORT
        self.user32.GetForegroundWindow.argtypes = []
        self.user32.GetForegroundWindow.restype = wintypes.HWND
        self.user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        self.user32.GetWindowThreadProcessId.restype = wintypes.DWORD
        self.edges = HotkeyEdges()

    def poll(self, game_pid):
        pid = self.wintypes.DWORD()
        window = self.user32.GetForegroundWindow()
        if window:
            self.user32.GetWindowThreadProcessId(window, self.ctypes.byref(pid))
        return self.edges.update(focused=bool(game_pid and pid.value == game_pid),
                                 deploy_down=bool(self.user32.GetAsyncKeyState(0x75) & 0x8000),
                                 dismiss_down=bool(self.user32.GetAsyncKeyState(0x76) & 0x8000),
                                 guard_down=bool(self.user32.GetAsyncKeyState(0x77) & 0x8000),
                                 recall_down=bool(self.user32.GetAsyncKeyState(0x78) & 0x8000),
                                 original_down=bool(self.user32.GetAsyncKeyState(0x7A) & 0x8000))
