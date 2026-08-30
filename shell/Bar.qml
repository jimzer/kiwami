import Quickshell
import Quickshell.Hyprland
import QtQuick

PanelWindow {
    id: bar
    required property var modelData
    screen: modelData

    anchors { top: true; left: true; right: true }
    implicitHeight: Theme.barHeight
    color: Theme.bg

    // Workspaces, read from Hyprland's IPC. Nothing else needed: the
    // compositor already owns them, the bar only displays them.
    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Repeater {
            model: Hyprland.workspaces

            Rectangle {
                required property var modelData
                width: 26
                height: 22
                radius: Theme.radius
                color: modelData.focused ? Theme.accent
                     : modelData.urgent  ? Theme.urgent
                     : Theme.bgAlt

                Text {
                    anchors.centerIn: parent
                    text: modelData.name
                    color: modelData.focused ? Theme.bg : Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 1
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: Hyprland.dispatch("workspace " + modelData.id)
                }
            }
        }
    }

    // Focused window title.
    Text {
        anchors.centerIn: parent
        width: bar.width * 0.4
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        text: Hyprland.activeToplevel ? (Hyprland.activeToplevel.title ?? "") : ""
        color: Theme.fgDim
        font.family: Theme.font
        font.pixelSize: Theme.fontSize
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gap * 2

        Tray { anchors.verticalCenter: parent.verticalCenter }

        Battery { anchors.verticalCenter: parent.verticalCenter }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDateTime(clock.date, "ddd d MMM  HH:mm:ss")
            color: Theme.fg
            font.family: Theme.font
            font.pixelSize: Theme.fontSize
        }
    }
}
