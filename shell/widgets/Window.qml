import Quickshell
import Quickshell.Hyprland
import QtQuick
import ".."   // Theme, resolved from the parent directory

Text {
    width: 400
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignHCenter
    text: Hyprland.activeToplevel ? (Hyprland.activeToplevel.title ?? "") : ""
    color: Theme.fgDim
    font.family: Theme.font
    font.pixelSize: Theme.fontSize
}
