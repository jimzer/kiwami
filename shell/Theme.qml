pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// The palette is read straight from the active theme and watched, so a colour
// change retints the shell with no regeneration and no restart. Ghostty and
// Hyprland cannot do that, so kiwami-theme generates files for them instead.
Singleton {
    id: root

    readonly property string themePath:
        Quickshell.env("HOME") + "/.local/state/kiwami/current/theme/colors.json"

    // Fallback palette: used before the file loads, and if a theme is missing
    // a key. Without it a broken theme would render an invisible shell.
    readonly property var fallback: ({
        accent: "#7ad07a", accent_dim: "#4f8f56",
        background: "#0f1411", surface: "#151d18",
        lighter_background: "#1a221d", selection: "#2a3830",
        foreground: "#d6e0d8", dark_foreground: "#6d7a72",
        red: "#e06c75", muted: "#4b5a52"
    })

    property var palette: fallback

    function c(key) {
        return palette[key] !== undefined ? palette[key] : (fallback[key] ?? "#ff00ff");
    }

    FileView {
        id: file
        path: root.themePath
        watchChanges: true
        onFileChanged: reload()
        // A failed read (theme mid-write, or missing) otherwise leaves the
        // watch dead and the shell stuck on the fallback palette forever.
        onLoadFailed: retry.restart()
        onLoaded: {
            try {
                root.palette = JSON.parse(file.text());
            } catch (e) {
                console.warn("theme: could not parse", root.themePath, e);
                root.palette = root.fallback;
            }
        }
    }

    Timer {
        id: retry
        interval: 500
        onTriggered: file.reload()
    }

    readonly property color bg:      c("background")
    readonly property color bgAlt:   c("lighter_background")
    readonly property color surface: c("surface")
    readonly property color fg:      c("foreground")
    readonly property color fgDim:   c("dark_foreground")
    readonly property color accent:  c("accent")
    readonly property color urgent:  c("red")

    readonly property int barHeight: 32
    readonly property int gap:       8
    readonly property int radius:    6
    readonly property string font:   "JetBrainsMono Nerd Font"
    readonly property int fontSize:  13
}
