import QtQuick

Rectangle {
    id: root

    property bool inverted: true
    readonly property bool darkFace: inverted ? Theme.mode === "light" : Theme.mode === "dark"
    readonly property color contentColor: darkFace ? "#FAFAFA" : "#1B1B1B"

    radius: Theme.radiusCard
    border.width: 1
    border.color: inverted
        ? (darkFace ? "#555555" : "#C5C5C5")
        : (darkFace ? "#303030" : "#DADADA")
    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop {
            position: 0
            color: root.inverted
                ? (root.darkFace ? "#303030" : "#F4F4F4")
                : (root.darkFace ? "#202020" : "#F3F3F3")
        }
        GradientStop {
            position: 1
            color: root.inverted
                ? (root.darkFace ? "#181818" : "#E4E4E4")
                : (root.darkFace ? "#1B1B1B" : "#F0F0F0")
        }
    }
}
