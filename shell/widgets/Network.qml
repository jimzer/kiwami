import Quickshell.Io
import QtQuick
import ".."

// What you are connected to.
//
// nmcli rather than DBus: the shell only needs to read a line of state every
// few seconds, and a subscription to NetworkManager's DBus interface is a lot
// of surface for that. If this ever needs to *change* the connection it should
// move to DBus - but changing networks is `kiwami net`'s job, and duplicating
// it here would mean two ways to do one thing.
Row {
    id: root
    spacing: Theme.gap

    property string kind: ""      // wifi | ethernet | none
    property string name: ""
    property int strength: 0

    readonly property string icon: {
        if (kind === "ethernet") return "󰈀";
        if (kind !== "wifi") return "󰤭";              // nothing connected
        if (strength >= 75) return "󰤨";
        if (strength >= 50) return "󰤥";
        if (strength >= 25) return "󰤢";
        return "󰤟";
    }

    Process {
        id: poll
        running: true
        // Active connections, most specific first. -t escapes colons inside
        // values, so the SSID is read by unescaping rather than by splitting
        // naively - an SSID with a colon in it is unusual and legal.
        command: ["sh", "-c",
            "nmcli -t -f TYPE,DEVICE,STATE,CONNECTION device | grep ':connected:' | head -1; " +
            "nmcli -t -f IN-USE,SIGNAL device wifi list 2>/dev/null | grep '^\\*' | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n").filter(l => l.length > 0);
                if (lines.length === 0) {
                    root.kind = "none"; root.name = ""; root.strength = 0;
                    return;
                }
                const f = lines[0].split(/(?<!\\):/).map(s => s.replace(/\\:/g, ":"));
                root.kind = f[0] || "none";
                root.name = f[3] || "";
                if (lines.length > 1) {
                    const s = lines[1].split(":");
                    root.strength = parseInt(s[1]) || 0;
                }
            }
        }
    }

    Timer {
        // Slow on purpose. Signal strength is not worth a redraw every second,
        // and the interesting transitions - joining, dropping - are visible
        // within a few seconds either way.
        interval: 5000
        running: true
        repeat: true
        onTriggered: poll.running = true
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        color: root.kind === "none" ? Theme.fgDim : Theme.accent
        font.family: Theme.font
        font.pixelSize: Theme.fontSize
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        // The name only earns its place on wifi: "ethernet" tells you nothing
        // the icon has not already said.
        visible: root.kind === "wifi" && root.name.length > 0
        text: root.name
        color: Theme.fg
        font.family: Theme.font
        font.pixelSize: Theme.fontSize
    }
}
