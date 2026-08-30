import Quickshell
import QtQuick

ShellRoot {
    PanelWindow {
        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: 32
        color: "#181825"

        Text {
            anchors.centerIn: parent
            text: "kiwami  •  " + Qt.formatDateTime(new Date(), "ddd d MMM  HH:mm")
            color: "#cdd6f4"
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 13
        }
    }
}
