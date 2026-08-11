#!/usr/bin/env python3
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib
import os, sys, json, subprocess

STATE_FILE = '/tmp/qs_kwin_windows.json'
CONTROL_FILE = '/tmp/qs_kwin_control.json'
KWIN_SCRIPT_PATH = os.path.expanduser(
    "~/.local/share/kwin/scripts/quickshell-kde-bridge/contents/code/main.js"
)

class QSKWinBridge(dbus.service.Object):
    def __init__(self, bus, path_name):
        super().__init__(bus, path_name)
        self.windows_json = "[]"
        if os.path.exists(STATE_FILE):
            try:
                with open(STATE_FILE, 'r') as f:
                    self.windows_json = f.read().strip() or "[]"
            except:
                pass
        # Emit cached state immediately so overview shows last-known windows
        print(self.windows_json, flush=True)

    def trigger_kwin_update(self):
        """Reload the KWin bridge script so its initial updateWindows() fires with us on the bus.

        Also used by the control channel: when the Quickshell side writes a
        control request, reloading the script makes it call getPendingAction()
        and execute the request.
        """
        try:
            bus = dbus.SessionBus()
            scripting = bus.get_object("org.kde.KWin", "/Scripting")
            try:
                scripting.unloadScript("quickshell-kde-bridge", signature="s")
            except Exception:
                pass
            # NOTE: dbus-python binds overloaded methods to the first signature
            # in introspection XML ('s'), so pass the pluginName explicitly via
            # signature="ss". This registers the name so unloadScript works and
            # the script cannot stack duplicate instances across restarts.
            scripting.loadScript(
                KWIN_SCRIPT_PATH, "quickshell-kde-bridge", signature="ss"
            )
            # loadScript() only loads; start() actually executes the script.
            scripting.start(signature="")
        except Exception:
            pass
        return False  # Don't repeat

    def check_control_file(self):
        """Poll the control file; if the Quickshell side wrote a request,
        reload the KWin script so it can pull and execute the action."""
        try:
            with open(CONTROL_FILE, 'r') as f:
                content = f.read().strip()
            if content:
                self.trigger_kwin_update()
        except Exception:
            pass
        return True  # keep polling

    @dbus.service.method("org.kde.qs.bridge", in_signature='', out_signature='s')
    def getPendingAction(self):
        """Return the pending control request (JSON string) and clear the file.

        Called by the KWin script right after it loads; the script executes the
        action (activate/close window) using the workspace API.
        """
        try:
            with open(CONTROL_FILE, 'r') as f:
                content = f.read().strip()
            if content:
                with open(CONTROL_FILE, 'w') as f:
                    f.write("")
            return content
        except Exception:
            return ""

    @dbus.service.method("org.kde.qs.bridge", in_signature='s', out_signature='')
    def updateWindows(self, win_json):
        # Validate JSON before printing (avoid corrupting the stdout stream)
        try:
            parsed = json.loads(str(win_json))
        except Exception:
            return
        self.windows_json = str(win_json)
        try:
            with open(STATE_FILE, 'w') as f:
                f.write(self.windows_json)
        except:
            pass
        # Print only valid JSON lines — no debug output to stdout
        print(self.windows_json, flush=True)

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
session_bus = dbus.SessionBus()
name = dbus.service.BusName("org.kde.qs", session_bus)
bridge = QSKWinBridge(session_bus, '/bridge')

# After 500ms, reload the KWin script so its initial updateWindows() fires with us on the bus
GLib.timeout_add(500, bridge.trigger_kwin_update)

# Control channel: poll for window control requests (activate/close) from QML
GLib.timeout_add(400, bridge.check_control_file)

loop = GLib.MainLoop()
loop.run()
