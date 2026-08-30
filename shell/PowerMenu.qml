import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

PanelWindow {
    id: root
    visible: false

    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive
                                         : WlrKeyboardFocus.None
    WlrLayershell.namespace: "kiwami-power"

    // hyprlock stays the locker. A shell that draws its own lock screen can
    // lock you out of your own machine when it crashes.
    readonly property var actions: [
        { icon: "󰌾", label: "Lock",      exec: ["hyprlock"] },
        { icon: "󰤄", label: "Suspend",   exec: ["systemctl", "suspend"] },
        { icon: "󰗽", label: "Log out",   exec: ["hyprctl", "dispatch", "exit"] },
        { icon: "󰜉", label: "Reboot",    exec: ["systemctl", "reboot"] },
        { icon: "󰐥", label: "Shut down", exec: ["systemctl", "poweroff"] }
    ]

    property int index: 0

    function open() { index = 0; visible = true; }
    function run(a) { Quickshell.execDetached(a.exec); visible = false; }

    MouseArea {
        anchors.fill: parent
        onClicked: root.visible = false
    }

    Rectangle {
        anchors.centerIn: parent
        width: row.implicitWidth + Theme.gap * 4
        height: row.implicitHeight + Theme.gap * 4
        radius: Theme.radius * 2
        color: Theme.bg
        border.color: Theme.accent
        border.width: 1

        MouseArea { anchors.fill: parent }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.gap

            Repeater {
                model: root.actions

                Rectangle {
                    required property var modelData
                    required property int index
                    width: 92
                    height: 92
                    radius: Theme.radius
                    color: index === root.index ? Theme.bgAlt : "transparent"
                    border.color: index === root.index ? Theme.accent : "transparent"
                    border.width: 1

                    Column {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.icon
                            color: index === root.index ? Theme.accent : Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 26
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.label
                            color: index === root.index ? Theme.fg : Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 1
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.index = index
                        onClicked: root.run(modelData)
                    }
                }
            }
        }
    }

    Item {
        focus: root.visible
        Keys.onEscapePressed: root.visible = false
        Keys.onLeftPressed: root.index = (root.index + root.actions.length - 1) % root.actions.length
        Keys.onRightPressed: root.index = (root.index + 1) % root.actions.length
        Keys.onReturnPressed: root.run(root.actions[root.index])
    }

    GlobalShortcut {
        appid: "kiwami"
        name: "power"
        onPressed: root.visible ? root.visible = false : root.open()
    }
}
