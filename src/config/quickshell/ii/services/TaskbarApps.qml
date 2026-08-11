pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    function isPinned(appId) {
        return Config.options.dock.pinnedApps.indexOf(appId) !== -1;
    }

    function togglePin(appId) {
        if (root.isPinned(appId)) {
            Config.options.dock.pinnedApps = Config.options.dock.pinnedApps.filter(id => id !== appId)
        } else {
            Config.options.dock.pinnedApps = Config.options.dock.pinnedApps.concat([appId])
        }
    }

    // ── KWin window data (via qs-kwin-bridge) ─────────────────────────────────
    // KWin does not implement wlr-foreign-toplevel / ext-foreign-toplevel-list,
    // so Quickshell's ToplevelManager is empty on KDE. Instead we read the
    // window list JSON written by the bridge service
    // (KWin script → DBus → bridge.py → /tmp/qs_kwin_windows.json).
    FileView {
        id: windowsFile
        path: "/tmp/qs_kwin_windows.json"
        watchChanges: true
        onFileChanged: windowsFile.reload()
        onLoaded: root.rebuildApps()
    }

    // Control channel: writing a request here makes the bridge reload the KWin
    // script, which pulls the action and activates/closes the window.
    FileView {
        id: controlFile
        path: "/tmp/qs_kwin_control.json"
    }

    function requestWindowAction(action, internalId) {
        controlFile.setText(JSON.stringify({ action: action, internalId: internalId }));
    }

    function makeToplevel(w) {
        const appId = (w.class || "unknown").toLowerCase();
        return {
            appId: appId,
            title: w.title || "",
            internalId: w.internalId,
            activated: w.activated === true,
            activate: () => root.requestWindowAction("activate", w.internalId),
            close: () => root.requestWindowAction("close", w.internalId)
        };
    }

    function buildApps() {
        var map = new Map();
        var anyActive = false;

        // Pinned apps
        const pinnedApps = Config.options?.dock.pinnedApps ?? [];
        for (const appId of pinnedApps) {
            if (!map.has(appId.toLowerCase())) map.set(appId.toLowerCase(), ({
                pinned: true,
                toplevels: []
            }));
        }

        // Separator
        if (pinnedApps.length > 0) {
            map.set("SEPARATOR", { pinned: false, toplevels: [] });
        }

        // Ignored apps
        const ignoredRegexStrings = Config.options?.dock.ignoredAppRegexes ?? [];
        const ignoredRegexes = ignoredRegexStrings.map(pattern => new RegExp(pattern, "i"));

        // Open windows (from the bridge JSON)
        var bridgeWindows = [];
        if (windowsFile.loaded) {
            try {
                bridgeWindows = JSON.parse(windowsFile.text());
            } catch (e) {
                bridgeWindows = [];
            }
        }
        for (const w of bridgeWindows) {
            const appId = (w.class || "unknown").toLowerCase();
            if (ignoredRegexes.some(re => re.test(appId))) continue;
            if (w.activated === true) anyActive = true;
            if (!map.has(appId)) map.set(appId, { pinned: false, toplevels: [] });
            map.get(appId).toplevels.push(root.makeToplevel(w));
        }

        root.hasActiveToplevel = anyActive;

        var values = [];

        for (const [key, value] of map) {
            values.push(appEntryComp.createObject(null, { appId: key, toplevels: value.toplevels, pinned: value.pinned }));
        }

        return values;
    }

    property var apps: buildApps()

    // True when at least one window in the bridge JSON is activated.
    // Used by Dock.qml to decide whether the dock should auto-hide
    // (KWin has no ToplevelManager, so the upstream Hyprland condition
    // `!ToplevelManager.activeToplevel?.activated` is always true on KDE).
    property bool hasActiveToplevel: false

    function rebuildApps() {
        root.apps = root.buildApps();
    }

    component TaskbarAppEntry: QtObject {
        id: wrapper
        required property string appId
        required property list<var> toplevels
        required property bool pinned
    }
    Component {
        id: appEntryComp
        TaskbarAppEntry {}
    }
}
