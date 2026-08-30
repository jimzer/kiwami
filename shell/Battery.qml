import Quickshell
import Quickshell.Services.UPower
import QtQuick

// Hidden entirely when there is no battery, which is the case in the dev VM
// and on a desktop. Only laptops should see this.
Row {
    id: root
    readonly property var dev: UPower.displayDevice
    readonly property bool present: dev !== null && dev.isPresent

    visible: present
    spacing: 4

    Text {
        anchors.verticalCenter: parent.verticalCenter
        // Nerd Font battery ramp, plus a charging bolt.
        text: {
            if (!root.present) return "";
            const pct = root.dev.percentage;
            const charging = root.dev.state === UPowerDeviceState.Charging
                          || root.dev.state === UPowerDeviceState.FullyCharged;
            if (charging) return "󰂄";
            if (pct > 0.9) return "󰁹";
            if (pct > 0.7) return "󰂀";
            if (pct > 0.5) return "󰁾";
            if (pct > 0.3) return "󰁼";
            if (pct > 0.1) return "󰁻";
            return "󰂎";
        }
        color: root.present && root.dev.percentage <= 0.15 && UPower.onBattery
            ? Theme.urgent : Theme.fgDim
        font.family: Theme.font
        font.pixelSize: Theme.fontSize + 1
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.present ? Math.round(root.dev.percentage * 100) + "%" : ""
        color: Theme.fgDim
        font.family: Theme.font
        font.pixelSize: Theme.fontSize
    }
}
