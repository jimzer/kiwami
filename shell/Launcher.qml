import Quickshell
import Quickshell.Io
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

    // Actions come from `kiwami commands --json`, so the CLI stays the single
    // source of truth for what it can do. Refreshed each time the launcher
    // opens, which is how a newly added theme shows up without a restart.
    property var actions: []

    Process {
        id: commandsProc
        command: ["kiwami", "commands", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.actions = JSON.parse(text).map(e => ({
                        name: e.name,
                        subtitle: e.description,
                        exec: e.exec,
                        isAction: true
                    }));
                } catch (e) {
                    console.warn("launcher: could not read kiwami commands:", e);
                    root.actions = [];
                }
            }
        }
    }

    // The compositor owns the app list; Quickshell indexes .desktop files and
    // hands them over already parsed.
    readonly property var results: {
        const q = query.toLowerCase();

        const apps = DesktopEntries.applications.values
            .filter(a => !a.noDisplay)
            .map(a => ({ name: a.name, subtitle: "", entry: a, isAction: false }));

        return apps.concat(actions)
            .filter(e => q === ""
                || e.name.toLowerCase().includes(q)
                || e.subtitle.toLowerCase().includes(q))
            .sort((a, b) => {
                // Prefix matches first, then actions above apps so typing
                // "theme" surfaces the commands, then alphabetical.
                const ap = a.name.toLowerCase().startsWith(q) ? 0 : 1;
                const bp = b.name.toLowerCase().startsWith(q) ? 0 : 1;
                if (ap !== bp) return ap - bp;
                if (a.isAction !== b.isAction) return a.isAction ? -1 : 1;
                return a.name.localeCompare(b.name);
            })
            .slice(0, 12);
    }

    function open() {
        query = "";
        list.currentIndex = 0;
        commandsProc.running = true;   // pick up themes added since last time
        visible = true;
        input.forceActiveFocus();
    }

    function launch(result) {
        if (!result) return;
        if (result.isAction) {
            Quickshell.execDetached(result.exec);
        } else {
            result.entry.execute();
        }
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

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.gap
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.gap
                        spacing: Theme.gap

                        Text {
                            text: modelData.name
                            color: modelData.isAction
                                ? Theme.accent
                                : (index === list.currentIndex ? Theme.fg : Theme.fgDim)
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize
                        }

                        Text {
                            text: modelData.subtitle
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                            anchors.verticalCenter: parent.verticalCenter
                        }
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
