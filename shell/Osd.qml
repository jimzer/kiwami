import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import QtQuick

// Volume / brightness feedback.
//
// It reacts to state changing rather than being told to appear: the keybinds
// just run wpctl or brightnessctl, and this watches the result. One less IPC
// path, and it also shows when something else changes the volume.
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
