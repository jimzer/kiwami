pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Layout comes from Nix, via /etc/kiwami/bar.json. Setting kiwami.bar.right in
// a consumer's flake moves things here without touching any QML.
Singleton {
    id: root

    readonly property var fallback: ({
        enable: true, position: "top", height: 32,
        left: ["workspaces"], center: ["window"],
        right: ["tray", "battery", "clock"]
    })

    property var bar: fallback

    FileView {
        id: file
        path: "/etc/kiwami/bar.json"
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: root.bar = root.fallback
        onLoaded: {
            try {
                root.bar = JSON.parse(file.text());
            } catch (e) {
                console.warn("bar.json unreadable, using defaults:", e);
                root.bar = root.fallback;
            }
        }
    }
}
