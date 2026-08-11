console.info("Quickshell KDE Bridge script starting...");

// ── Control channel ───────────────────────────────────────────────────────────
// The Quickshell side (TaskbarApps) writes {"action":"activate"|"close","internalId":"..."}
// to /tmp/qs_kwin_control.json and the bridge service polls it. When a request
// appears, the bridge reloads this script; on load we pull the pending action
// via DBus and execute it with the workspace API.
function fetchPendingAction() {
    print("KDE bridge: fetching pending action");
    callDBus("org.kde.qs", "/bridge", "org.kde.qs.bridge", "getPendingAction", (reply) => {
        print("KDE bridge: got reply: '" + reply + "'");
        if (!reply) return;
        try {
            let req = JSON.parse(reply);
            if (!req.action || !req.internalId) return;
            let wins = workspace.windowList();
            for (let i = 0; i < wins.length; ++i) {
                let w = wins[i];
                if (w.internalId.toString() === req.internalId) {
                    print("KDE bridge: matched window, action=" + req.action);
                    if (req.action === "activate") {
                        workspace.activeWindow = w;
                    } else if (req.action === "close") {
                        w.close();
                    }
                    break;
                }
            }
        } catch (e) {
            print("KDE bridge: control parse error: " + e);
        }
    });
}

function updateWindows() {
    let wins = workspace.windowList();
    let result = [];
    for (let i = 0; i < wins.length; ++i) {
        let w = wins[i];
        if (w.normalWindow) {
            let desktopId = 0;
            if (w.desktops && w.desktops.length > 0) {
                // In KWin 6, desktop might have an x11DesktopNumber or similar
                // We'll just grab the id if it has one, or assume desktop sequence
                desktopId = w.desktops[0].x11DesktopNumber || 1;
            }
            result.push({
                title: w.caption,
                class: w.resourceClass,
                workspace: { id: desktopId },
                at: [w.frameGeometry ? w.frameGeometry.x : 0, w.frameGeometry ? w.frameGeometry.y : 0],
                size: [w.frameGeometry ? w.frameGeometry.width : 0, w.frameGeometry ? w.frameGeometry.height : 0],
                internalId: w.internalId.toString(),
                activated: w === workspace.activeWindow,
                floating: !w.tile,
                fullscreen: w.fullScreen,
                xwayland: w.xwayland
            });
        }
    }
    callDBus("org.kde.qs", "/bridge", "org.kde.qs.bridge", "updateWindows", JSON.stringify(result));
}

// ── Control channel: pull and execute a pending window control request ───────
// Called on every script load. The bridge service reloads this script whenever
// the Quickshell side writes a control request, so the async callDBus reply is
// our only "event loop" — no timers or file APIs exist in KWin JS scripts.
fetchPendingAction();

workspace.windowAdded.connect((w) => {
    try { w.frameGeometryChanged.connect(updateWindows); } catch(e) {}
    try { w.desktopsChanged.connect(updateWindows); } catch(e) {}
    try { w.desktopChanged.connect(updateWindows); } catch(e) {}
    updateWindows();
});
workspace.windowRemoved.connect(updateWindows);
workspace.windowActivated.connect(updateWindows);
try { workspace.currentDesktopChanged.connect(updateWindows); } catch(e) {}

// Initial connect to existing windows
let wins = workspace.windowList();
for (let i = 0; i < wins.length; ++i) {
    let w = wins[i];
    try { w.frameGeometryChanged.connect(updateWindows); } catch(e) {}
    try { w.desktopsChanged.connect(updateWindows); } catch(e) {}
    try { w.desktopChanged.connect(updateWindows); } catch(e) {}
}

// Initial update
updateWindows();
