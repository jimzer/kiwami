pragma Singleton
import Quickshell
import QtQuick

// One place for colours and metrics. Everything else reads from here, so the
// theme pipeline later has a single file to generate.
Singleton {
    readonly property color bg:       "#181825"
    readonly property color bgAlt:    "#1e1e2e"
    readonly property color fg:       "#cdd6f4"
    readonly property color fgDim:    "#6c7086"
    readonly property color accent:   "#89b4fa"
    readonly property color urgent:   "#f38ba8"

    readonly property int barHeight:  32
    readonly property int gap:        8
    readonly property int radius:     6
    readonly property string font:    "JetBrainsMono Nerd Font"
    readonly property int fontSize:   13
}
