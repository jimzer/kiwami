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

    // Widgets resolve by filename, not a hardcoded list: "clock" loads
    // widgets/Clock.qml from the merged tree, so a user can add
    // widgets/Weather.qml and name it in kiwami.bar.right without us
    // knowing it exists.
    function widgetPath(name) {
        if (!name || name.length === 0) return "";
        return "widgets/" + name.charAt(0).toUpperCase() + name.slice(1) + ".qml";
    }

    component Section: Row {
        required property var names
        spacing: Theme.gap * 2

        Repeater {
            model: parent.names

            // A third-party widget with a QML error must not take the bar
            // down with it. Loader isolates the failure: the slot stays
            // empty and everything else still renders.
            Loader {
                id: slot
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                source: bar.widgetPath(modelData)
                asynchronous: false

                onStatusChanged: {
                    if (status === Loader.Error) {
                        console.warn("bar: widget '" + modelData
                            + "' failed to load from " + source
                            + " - skipping it");
                    }
                }
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
