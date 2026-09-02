import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import QtQuick

// Volume / brightness feedback.
//
// It reacts to state changing rather than being told to appear: the keybinds
// just run wpctl or brightnessctl, and this watches the result. One less IPC
// path, and it also shows when something else changes them - a laptop's own
// function keys, or the auto-dimming that happens on battery.
//
// The brightness half went missing for a long time: this comment described it,
// the keybinds called brightnessctl, and nothing here watched the backlight.
// The VM has no backlight, so it rendered correctly as nothing and no test
// could tell the difference.
PanelWindow {
    id: root
    visible: false

    anchors { bottom: true }
    margins.bottom: 80
    implicitWidth: 260
    implicitHeight: 56
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "kiwami-osd"

    property string icon: ""
    property real value: 0
    property bool ready: false

    readonly property var sink: Pipewire.defaultAudioSink

    // Binding a node is required before its audio properties are populated.
    PwObjectTracker { objects: root.sink ? [root.sink] : [] }

    function show(icon, value) {
        root.icon = icon;
        root.value = Math.max(0, Math.min(1, value));
        root.visible = true;
        hideTimer.restart();
    }

    Timer {
        id: hideTimer
        interval: 1600
        onTriggered: root.visible = false
    }

    Connections {
        target: root.sink && root.sink.audio ? root.sink.audio : null

        function onVolumeChanged() {
            // Skip the initial binding, or an OSD pops up at login.
            if (!root.ready) { root.ready = true; return; }
            root.show(root.sink.audio.muted ? "󰝟" : "󰕾", root.sink.audio.volume);
        }
        function onMutedChanged() {
            if (!root.ready) { root.ready = true; return; }
            root.show(root.sink.audio.muted ? "󰝟" : "󰕾", root.sink.audio.volume);
        }
    }

    // The backlight, read straight from sysfs rather than by polling
    // brightnessctl. The kernel updates these files whoever changes the
    // brightness, so this catches the function keys and anything else.
    property int brightnessMax: 0
    property int brightnessRaw: -1

    FileView {
        // Whichever backlight this machine has - the directory name differs by
        // driver (intel_backlight, amdgpu_bl0, nvidia_wmi_ec_backlight), so it
        // is discovered rather than assumed.
        id: backlightMax
        path: root.backlightDir ? root.backlightDir + "/max_brightness" : ""
        onLoaded: root.brightnessMax = parseInt(text()) || 0
    }

    FileView {
        id: backlight
        path: root.backlightDir ? root.backlightDir + "/brightness" : ""
        watchChanges: true
        onLoaded: root.onBrightness(parseInt(text()))
        onFileChanged: reload()
    }

    property string backlightDir: ""

    Process {
        // One shot at startup: find the first backlight, if there is one. A
        // desktop has none and everything below stays inert.
        id: findBacklight
        running: true
        command: ["sh", "-c", "ls -d /sys/class/backlight/*/ 2>/dev/null | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const dir = text.trim().replace(/\/$/, "");
                if (dir.length > 0) root.backlightDir = dir;
            }
        }
    }

    property bool brightnessReady: false

    function onBrightness(raw) {
        if (isNaN(raw) || root.brightnessMax <= 0) return;
        root.brightnessRaw = raw;
        // Same reason as the volume guard: the first read is the current
        // value, not a change, and an OSD at login is noise.
        if (!root.brightnessReady) { root.brightnessReady = true; return; }
        root.show("󰃟", raw / root.brightnessMax);
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius * 2
        color: Theme.bg
        border.color: Theme.accent
        border.width: 1

        Row {
            anchors.fill: parent
            anchors.margins: Theme.gap * 2
            spacing: Theme.gap * 2

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.icon
                color: Theme.accent
                font.family: Theme.font
                font.pixelSize: Theme.fontSize + 6
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 90
                height: 6
                radius: 3
                color: Theme.bgAlt

                Rectangle {
                    width: parent.width * root.value
                    height: parent.height
                    radius: parent.radius
                    color: Theme.accent
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Math.round(root.value * 100)
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: Theme.fontSize
            }
        }
    }
}
