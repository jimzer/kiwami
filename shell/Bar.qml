import Quickshell
import Quickshell.Wayland
import QtQuick
import "widgets"

// The bar composes itself from Config.bar, which Nix generates. Adding a
// widget means adding its name to kiwami.bar.right, not editing this file.
PanelWindow {
    id: bar
    required property var modelData
    screen: modelData

    readonly property var conf: Config.bar

    anchors {
        top: conf.position === "top"
        bottom: conf.position === "bottom"
        left: true
        right: true
    }
    implicitHeight: conf.height
    color: Theme.bg
    visible: conf.enable

    // Name -> component. A user shadowing widgets/Clock.qml replaces the
    // clock everywhere without touching this mapping.
    function widgetFor(name) {
        switch (name) {
            case "workspaces": return workspacesC;
            case "window":     return windowC;
            case "tray":       return trayC;
            case "battery":    return batteryC;
            case "clock":      return clockC;
            default:           return null;
        }
    }

    Component { id: workspacesC; Workspaces {} }
    Component { id: windowC;     Window {} }
    Component { id: trayC;       Tray {} }
    Component { id: batteryC;    Battery {} }
    Component { id: clockC;      Clock {} }

    component Section: Row {
        required property var names
        spacing: Theme.gap * 2

        Repeater {
            model: parent.names
            Loader {
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                sourceComponent: bar.widgetFor(modelData)
            }
        }
    }

    Section {
        names: bar.conf.left
        anchors.left: parent.left
        anchors.leftMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
    }

    Section {
        names: bar.conf.center
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
    }

    Section {
        names: bar.conf.right
        anchors.right: parent.right
        anchors.rightMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
    }
}
