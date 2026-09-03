import Quickshell
import Quickshell.Io
import QtQuick
import ".."   // Theme, resolved from the parent directory

// When /persist was last backed up.
//
// Reads a file rather than asking restic. The repository credentials are
// root-only, and opening object storage every thirty seconds to learn a fact
// that changes once a day would be wrong even with permission - it would cost
// latency and requests, and show an error whenever the wifi was down, which
// says nothing about whether the backups are healthy.
//
// So the backup unit writes down what happened and this reads it: instant,
// offline, and able to show that the last run *failed* - which querying the
// repository could not, since it would just report yesterday's snapshot as
// though all were well.
Text {
    id: root

    property var status: null
    property bool configured: false

    // Bindings re-evaluate when a property they read changes, and Date.now()
    // is not a property - so without something reactive in here the age is
    // computed once and never again. It said "just now" ten minutes after a
    // backup, correctly, and would have said "just now" a week later too:
    // the one thing this widget exists to report is the one thing it could
    // never have shown.
    property int tick: 0

    readonly property real ageHours: {
        tick;   // read, so the timer below re-runs this
        if (!status || !status.time) return -1;
        const then = new Date(status.time);
        if (isNaN(then.getTime())) return -1;
        return (Date.now() - then.getTime()) / 3600000;
    }

    // Amber after two days. Daily is the schedule, so one missed run is a
    // closed lid and not worth shouting about; two is a machine that has
    // quietly stopped backing up.
    readonly property bool stale: ageHours > 48

    FileView {
        path: "/var/lib/kiwami/backup/status.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root.status = JSON.parse(text());
                root.configured = true;
            } catch (e) {
                root.configured = false;
            }
        }
        // No file means backups were never set up on this machine, which is
        // not an error - the widget simply says nothing.
        onLoadFailed: root.configured = false
    }

    visible: configured
    text: {
        if (!status) return "";
        if (!status.ok) return "󰀦 backup failed";
        const h = root.ageHours;
        if (h < 0) return "󰁯";
        if (h < 1) return "󰁯 just now";
        if (h < 24) return "󰁯 " + Math.round(h) + "h";
        return "󰁯 " + Math.round(h / 24) + "d";
    }
    // urgent, not accent: a machine that has silently stopped backing up
    // should not look like a decoration.
    color: (status && !status.ok) || stale ? Theme.urgent : Theme.fgDim
    font.family: Theme.font
    font.pixelSize: Theme.fontSize

    // A minute is plenty: the underlying fact changes daily, and this only
    // exists so "2h" becomes "3h" without waiting for the next backup.
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.tick++
    }
}
