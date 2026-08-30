import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import QtQuick

// Notification daemon and popups.
//
// Owning the org.freedesktop.Notifications name means mako or dunst must not
// also be running - two daemons fight over the bus name and one loses
// silently.
PanelWindow {
    id: root

    anchors { top: true; right: true }
    margins { top: Theme.barHeight + Theme.gap; right: Theme.gap }
    implicitWidth: 380
    implicitHeight: Math.max(1, column.implicitHeight)
    color: "transparent"
    visible: column.children.length > 0

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "kiwami-notifications"

    NotificationServer {
        id: server
        // Without this a shell restart drops every notification on screen.
        keepOnReload: false
        bodySupported: true
        actionsSupported: true
        imageSupported: true

        onNotification: (n) => {
            // Tracking keeps the object alive after the sender goes away;
            // otherwise it is freed the moment the call returns.
            n.tracked = true;
            model.insert(0, { notif: n });
        }
    }

    ListModel { id: model }

    function dismiss(index) {
        const entry = model.get(index);
        if (entry && entry.notif) entry.notif.dismiss();
        model.remove(index);
    }

    Column {
        id: column
        anchors.right: parent.right
        width: parent.width
        spacing: Theme.gap

        Repeater {
            model: model

            Rectangle {
                required property var notif
                required property int index

                width: column.width
                implicitHeight: content.implicitHeight + Theme.gap * 2
                height: implicitHeight
                radius: Theme.radius
                color: Theme.surface
                border.width: 1
                border.color: notif.urgency === NotificationUrgency.Critical
                    ? Theme.urgent : Theme.accent

                Column {
                    id: content
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.gap
                    spacing: 2

                    Text {
                        width: parent.width
                        text: notif.appName
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 3
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: notif.summary
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: notif.body
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 1
                        wrapMode: Text.WordWrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                        visible: text !== ""
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.dismiss(index)
                }

                // Critical notifications stay until dismissed; that is the
                // whole point of the urgency being critical.
                Timer {
                    running: notif.urgency !== NotificationUrgency.Critical
                    interval: notif.expireTimeout > 0 ? notif.expireTimeout : 5000
                    onTriggered: root.dismiss(index)
                }
            }
        }
    }
}
