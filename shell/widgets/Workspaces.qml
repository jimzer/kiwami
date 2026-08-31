import Quickshell
import Quickshell.Hyprland
import QtQuick
import ".."   // Theme, resolved from the parent directory

Row {
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
