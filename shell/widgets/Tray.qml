import Quickshell
import Quickshell.Services.SystemTray
import QtQuick
import ".."   // Theme, resolved from the parent directory

// StatusNotifierItem tray. Empty until something registers, which on a fresh
// VM is normal - nothing here runs a tray icon by default.
Row {
    spacing: 6

    Repeater {
        model: SystemTray.items

        Item {
            required property var modelData
            width: 18
            height: 18

            Image {
                anchors.fill: parent
                source: modelData.icon
                fillMode: Image.PreserveAspectFit
                smooth: true
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (mouse) => {
                    // Some items only offer a menu and ignore activation.
                    if (mouse.button === Qt.RightButton || modelData.onlyMenu) {
                        if (modelData.hasMenu) modelData.display(this, 0, height);
                    } else {
                        modelData.activate();
                    }
                }
            }
        }
    }
}
