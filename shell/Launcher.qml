import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

PanelWindow {
    id: root
    visible: false

    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"

    // Overlay layer so it sits above windows, and take keyboard focus while
    // open - a layer surface gets no input otherwise.
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive
                                         : WlrKeyboardFocus.None
    WlrLayershell.namespace: "kiwami-launcher"

    property string query: ""

    // The compositor owns the app list; Quickshell indexes .desktop files and
    // hands them over already parsed.
    readonly property var results: {
        const q = query.toLowerCase();
        return DesktopEntries.applications.values
            .filter(a => !a.noDisplay
                && (q === "" || a.name.toLowerCase().includes(q)))
            .sort((a, b) => {
                // Prefix matches first, then alphabetical.
                const ap = a.name.toLowerCase().startsWith(q) ? 0 : 1;
                const bp = b.name.toLowerCase().startsWith(q) ? 0 : 1;
                return ap !== bp ? ap - bp : a.name.localeCompare(b.name);
            })
            .slice(0, 12);
    }

    function open() {
        query = "";
        list.currentIndex = 0;
        visible = true;
        input.forceActiveFocus();
    }

    function launch(entry) {
        if (entry) entry.execute();
        visible = false;
    }

    // Click outside to dismiss.
    MouseArea {
        anchors.fill: parent
        onClicked: root.visible = false
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.18
        width: 520
        // Height follows the content. Do NOT anchor the Column to fill this
        // Rectangle as well - that makes each depend on the other.
        height: header.implicitHeight + Theme.gap * 2
        radius: Theme.radius * 2
        color: Theme.bg
        border.color: Theme.accent
        border.width: 1

        // Swallow clicks so the dismiss handler above does not fire.
        MouseArea { anchors.fill: parent }

        Column {
            id: header
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.gap
            spacing: Theme.gap

            TextInput {
                id: input
                width: parent.width
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: Theme.fontSize + 3
                focus: true
                onTextChanged: {
                    root.query = text;
                    list.currentIndex = 0;
                }

                Text {
                    anchors.fill: parent
                    text: "Search…"
                    color: Theme.fgDim
                    font: input.font
                    visible: input.text === ""
                }

                Keys.onEscapePressed: root.visible = false
                Keys.onReturnPressed: root.launch(root.results[list.currentIndex])
                Keys.onDownPressed: list.incrementCurrentIndex()
                Keys.onUpPressed: list.decrementCurrentIndex()
            }

            Rectangle { width: parent.width; height: 1; color: Theme.fgDim }

            ListView {
                id: list
                width: parent.width
                height: Math.min(contentHeight, 400)
                model: root.results
                clip: true
                interactive: false

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: list.width
                    height: 30
                    color: index === list.currentIndex ? Theme.bgAlt : "transparent"
                    radius: Theme.radius

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.gap
                        text: modelData.name
                        color: index === list.currentIndex ? Theme.fg : Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.launch(modelData)
                    }
                }
            }
        }
    }

    // Bound to a Hyprland keybind via the `global` dispatcher.
    GlobalShortcut {
        appid: "kiwami"
        name: "launcher"
        onPressed: root.visible ? root.visible = false : root.open()
    }
}
