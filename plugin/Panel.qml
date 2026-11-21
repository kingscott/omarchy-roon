import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "."

BarWidget {
  id: root
  moduleName: "kingscott.roon"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property var zone: RoonService.currentZone
  readonly property bool connected: RoonService.status === "connected"
  readonly property bool hasTrack: !!zone && zone.title !== ""
  readonly property bool isPlaying: !!zone && zone.state === "playing"
  readonly property string artUrl: zone && zone.image && RoonService.artPaths[zone.image]
    ? "file://" + RoonService.artPaths[zone.image] : ""
  readonly property string statusText: {
    switch (RoonService.status) {
      case "no_host": return strings.t("status.noHost")
      case "connecting": return strings.t("status.connecting")
      case "waiting_auth": return strings.t("status.waitingAuth")
      case "error": return strings.t("status.error")
      case "connected": return ""
      default: return strings.t("status.starting")
    }
  }

  property bool popupOpen: false
  // Touchpads send many small wheel events; skip once per notch (120 units).
  property real wheelDelta: 0
  property real maxLabelWidth: 200

  // open(), close() and opened let the shell open the card from a hotkey:
  // omarchy-shell shell toggle kingscott.roon '{}'
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  function stateLabel(state) {
    var key = "state." + state
    var label = strings.t(key)
    return label === key ? state : label
  }

  // Focuses the Roon window if it is open, otherwise launches Roon. The
  // script is fixed text; nothing from Roon is passed to the shell.
  function openRoon() {
    root.popupOpen = false
    Quickshell.execDetached(["bash", "-c",
      "addr=$(hyprctl clients -j | jq -r '[.[] | select(.class == \"steam_app_0\" and (.title | test(\"^Roon\")))][0].address // empty'); " +
      "if [ -n \"$addr\" ]; then " +
      "hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$addr\\\" })\" >/dev/null 2>&1 || hyprctl dispatch focuswindow \"address:$addr\"; " +
      "else exec setsid uwsm-app -- roon-proton run; fi"])
  }

  readonly property string coreHost: String(root.setting("coreHost", "")).trim()
  readonly property int corePort: Number(root.setting("corePort", 9330))

  onCoreHostChanged: RoonService.configure(coreHost, corePort)
  onCorePortChanged: RoonService.configure(coreHost, corePort)
  Component.onCompleted: RoonService.attach(coreHost, corePort)
  Component.onDestruction: RoonService.detach()

  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.connected ? "󰝚" : "󰝛"
      color: root.isPlaying ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
      height: glyph.height
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.vertical && root.hasTrack

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: root.hasTrack ? root.zone.title + (root.zone.artist ? "  ·  " + root.zone.artist : "") : ""
        color: root.bar.barForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter

        property bool needsScroll: implicitWidth > scrollClip.width

        NumberAnimation on x {
          running: labelText.needsScroll && root.isPlaying && root.visible && !root.popupOpen && !root.vertical && !Style.reduceMotion
          onRunningChanged: if (!running) labelText.x = 0
          loops: Animation.Infinite
          duration: Style.duration(Math.max(6000, labelText.implicitWidth * 25))
          from: scrollClip.width
          to: -labelText.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton

    onClicked: function (mouse) {
      if (mouse.button === Qt.MiddleButton) RoonService.control("playpause")
      else root.popupOpen = !root.popupOpen
    }
    onWheel: function (wheel) {
      root.wheelDelta += wheel.angleDelta.y
      if (Math.abs(root.wheelDelta) < 120) return
      RoonService.control(root.wheelDelta > 0 ? "previous" : "next")
      root.wheelDelta = 0
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasTrack
      ? root.zone.title + (root.zone.artist ? " · " + root.zone.artist : "") + "\n" + root.zone.name
      : (root.statusText || strings.t("nothingPlaying")))
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: root.statusText
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
      }

      Row {
        spacing: Style.space(12)
        width: parent.width
        visible: root.connected

        BorderSurface {
          id: art
          width: Style.space(96)
          height: Style.space(96)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Commons.Color.accent)
          borderSpec: Border.controlSpec(artMouse.containsMouse ? "hover" : "normal", root.bar.foreground, Commons.Color.accent)

          SizedImage {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            crop: true
            url: root.artUrl
            visible: url != ""
          }

          Text {
            anchors.centerIn: parent
            visible: root.artUrl === ""
            textFormat: Text.PlainText
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          MouseArea {
            id: artMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openRoon()
          }

          PanelToolTip {
            visible: artMouse.containsMouse
            text: strings.t("openRoon")
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - art.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: root.hasTrack ? root.zone.title : strings.t("nothingPlaying")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.hasTrack ? root.zone.artist : ""
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            textFormat: Text.PlainText
            text: root.hasTrack ? root.zone.album : ""
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Row {
            spacing: Style.space(4)
            LayoutMirroring.enabled: false
            LayoutMirroring.childrenInherit: true

            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒮"
              foreground: root.bar.foreground
              enabled: !!root.zone && root.zone.canPrevious
              opacity: enabled ? 1.0 : 0.4
              onClicked: RoonService.control("previous")
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.isPlaying ? "󰏤" : "󰐊"
              foreground: root.bar.foreground
              iconSize: Style.font.iconLarge
              enabled: !!root.zone && root.zone.canPlayPause
              opacity: enabled ? 1.0 : 0.4
              onClicked: RoonService.control("playpause")
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒭"
              foreground: root.bar.foreground
              enabled: !!root.zone && root.zone.canNext
              opacity: enabled ? 1.0 : 0.4
              onClicked: RoonService.control("next")
            }
          }
        }
      }

      PanelSeparator {
        visible: root.connected && RoonService.zones.length > 0
        foreground: root.bar.foreground
      }

      PanelSectionHeader {
        visible: root.connected && RoonService.zones.length > 0
        text: strings.t("zones")
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Column {
        id: zoneList
        visible: root.connected
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: RoonService.zones

          BorderSurface {
            id: zoneRow
            required property var modelData

            readonly property bool selected: !!root.zone && root.zone.id === modelData.id
            readonly property bool playing: modelData.state === "playing"

            width: zoneList.width
            height: zoneInner.implicitHeight + Style.space(10)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
              : (zoneMouse.containsMouse ? Style.normalFillFor(root.bar.foreground, Commons.Color.accent) : "transparent")
            borderSpec: selected ? Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent) : Border.none()

            Row {
              id: zoneInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: zoneRow.borderLeft + Style.space(8)
              anchors.rightMargin: zoneRow.borderRight + Style.space(8)
              spacing: Style.space(8)
              opacity: zoneRow.playing ? 1.0 : 0.55

              // Marks the playing zone; the column stays for alignment.
              Text {
                textFormat: Text.PlainText
                text: zoneRow.playing ? "󰝚" : ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(26)
                spacing: Style.space(1)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  text: zoneRow.modelData.name
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: zoneRow.selected
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: zoneRow.modelData.title
                    ? zoneRow.modelData.title + (zoneRow.modelData.artist ? " · " + zoneRow.modelData.artist : "")
                    : root.stateLabel(zoneRow.modelData.state)
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }

            MouseArea {
              id: zoneMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: RoonService.selectZone(zoneRow.modelData.id)
            }
          }
        }
      }
    }
  }
}
