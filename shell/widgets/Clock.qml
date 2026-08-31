import Quickshell
import QtQuick
import ".."   // Theme, resolved from the parent directory

Text {
    SystemClock { id: clock; precision: SystemClock.Seconds }
    text: Qt.formatDateTime(clock.date, "ddd d MMM  HH:mm:ss")
    color: Theme.fg
    font.family: Theme.font
    font.pixelSize: Theme.fontSize
}
