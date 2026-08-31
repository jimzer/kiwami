import Quickshell
import "widgets"

ShellRoot {
    Variants {
        model: Quickshell.screens
        Bar {}
    }

    Launcher {}
    PowerMenu {}
    Osd {}
    Notifications {}
}
