import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Layout.js" as GridLayout

// Mission Control style overview: a flat grid of live thumbnails of every open
// window, across all workspaces. Clicking one focuses it, which takes Hyprland
// to that window's workspace.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property int selectedIndex: 0
  // Frozen while open so a title change doesn't rebuild the grid mid-click.
  property var windows: []
  // address -> width / height, as measured from each window's captured frame.
  // Hyprland's last reported size can be stale; the capture never is.
  property var measuredAspects: ({})

  // Darker than the menu's scrim: the desktop behind should recede so the
  // thumbnails are what reads.
  readonly property color scrim: Qt.rgba(Commons.Color.menu.background.r, Commons.Color.menu.background.g,
    Commons.Color.menu.background.b, 0.93)
  readonly property color foreground: Commons.Color.menu.text
  readonly property color accent: Commons.Color.menu.border
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int gap: Style.space(28)
  readonly property int labelHeight: Style.font.body + Style.space(18)
  readonly property int margin: Style.space(56)

  readonly property var cells: GridLayout.compute(
    windows.map(function(w) { return measuredAspects[w.address] || w.aspect }),
    panel.width - margin * 2, panel.height - margin * 2,
    gap, labelHeight, Math.round(panel.height * 0.55))

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function collectWindows() {
    var out = []
    var toplevels = Hyprland.toplevels.values
    var focused = Hyprland.activeToplevel
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      var wayland = toplevel.wayland
      var workspace = toplevel.workspace
      // Special workspaces hold minimized and scratchpad windows.
      if (!wayland || !workspace || workspace.id < 1) continue
      var ipc = toplevel.lastIpcObject || {}
      var size = Array.isArray(ipc.size) ? ipc.size : [16, 9]
      var at = Array.isArray(ipc.at) ? ipc.at : [0, 0]
      out.push({
        address: String(toplevel.address || ""),
        wayland: wayland,
        title: String(toplevel.title || wayland.title || ""),
        appId: String(wayland.appId || ""),
        aspect: size[1] > 0 ? size[0] / size[1] : 16 / 9,
        workspaceId: workspace.id,
        x: at[0],
        y: at[1],
        focused: toplevel === focused
      })
    }
    out.sort(function(a, b) {
      return a.workspaceId - b.workspaceId || a.x - b.x || a.y - b.y
    })
    return out
  }

  // True when the two lists would render the same grid. Assigning a new array
  // to the Repeater destroys every delegate and its live capture session, so
  // refresh() only assigns when something the grid shows has changed.
  function sameWindows(a, b) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      var p = a[i], q = b[i]
      if (p.wayland !== q.wayland || p.address !== q.address || p.title !== q.title
          || p.appId !== q.appId || p.workspaceId !== q.workspaceId || p.aspect !== q.aspect)
        return false
    }
    return true
  }

  function refresh() {
    var selected = root.windows[root.selectedIndex]
    var next = root.collectWindows()
    var index = -1
    for (var i = 0; i < next.length; i++) {
      if (selected ? next[i].wayland === selected.wayland : next[i].focused) index = i
    }
    if (!root.sameWindows(root.windows, next)) root.windows = next
    root.selectedIndex = Math.max(0, index)
  }

  function measured(address, size) {
    if (!address || !(size.width > 0) || !(size.height > 0)) return
    var aspect = size.width / size.height
    if (Math.abs((root.measuredAspects[address] || 0) - aspect) < 0.01) return
    var next = ({})
    for (var key in root.measuredAspects) next[key] = root.measuredAspects[key]
    next[address] = aspect
    root.measuredAspects = next
  }

  // Hyprland 0.56.2 crashes if a window capture starts while no monitor is
  // connected, or while one is coming back. So the overview never opens
  // without a monitor, closes the moment the set of monitors changes, and
  // only captures while its own surface is really on screen.
  // With every monitor gone Hyprland stands in a fake one named FALLBACK.
  function realMonitor(name) {
    return !!name && String(name).toUpperCase().indexOf("FALLBACK") !== 0
  }

  function hasMonitor() {
    var focused = Hyprland.focusedMonitor
    if (!focused || !root.realMonitor(focused.name)) return false
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (Quickshell.screens[i].name === focused.name) return true
    }
    return false
  }

  function open(payloadJson) {
    // A second summon while open (the swipe-up gesture) must not rebuild the grid.
    if (root.opened) {
      keyCatcher.forceActiveFocus()
      return
    }
    if (!root.hasMonitor()) {
      // Ask for fresh monitor state so the next press works once one is back.
      Hyprland.refreshMonitors()
      root.dismiss()
      return
    }
    root.windows = []
    root.measuredAspects = ({})
    root.selectedIndex = 0
    root.opened = true
    root.refresh()
    // Sizes come from Hyprland's last report; ask for a fresh one.
    Hyprland.refreshToplevels()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.windows = []
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "erasmus.birdseye")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function activate(index) {
    var target = root.windows[index]
    if (!target) return
    var address = target.address
    var wayland = target.wayland
    root.dismiss()
    if (!address) {
      if (wayland) wayland.activate()
      return
    }
    if (address.indexOf("0x") !== 0) address = "0x" + address
    // The dispatcher string is evaluated as Lua inside Hyprland, with the full
    // standard library. Only ever interpolate a validated hex address into it.
    if (!/^0x[0-9a-f]+$/i.test(address)) return
    var win = "window = \"address:" + address + "\""
    Hyprland.dispatch("hl.dsp.focus({ " + win + " })")
    Hyprland.dispatch("hl.dsp.window.alter_zorder({ mode = \"top\", " + win + " })")
  }

  function move(delta) {
    var count = root.windows.length
    if (count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + count) % count
  }

  function iconSource(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    var icon = entry ? entry.icon : appId
    var library = root.shell ? root.shell.appLibrary : null
    if (library && typeof library.iconSource === "function") return library.iconSource(icon)
    return Quickshell.iconPath(icon, "application-x-executable")
  }

  Connections {
    target: Quickshell
    function onScreensChanged() { if (root.opened) root.dismiss() }
  }
  Connections {
    target: Hyprland.monitors
    function onValuesChanged() { if (root.opened) root.dismiss() }
  }

  // Windows opening, closing or resizing while the overview is up.
  Connections {
    target: Hyprland.toplevels
    enabled: root.opened
    function onValuesChanged() { root.refresh() }
  }
  Connections {
    target: Hyprland
    enabled: root.opened
    function onRawEvent(event) {
      if (event.name === "closewindow" || event.name === "openwindow" || event.name === "movewindowv2")
        refreshTimer.restart()
    }
  }
  Timer {
    id: refreshTimer
    interval: 120
    onTriggered: if (root.opened) root.refresh()
  }
  // The fresh sizes requested on open arrive a moment later.
  Timer {
    interval: 150
    running: root.opened
    onTriggered: root.refresh()
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-birdseye"

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var key = Util.readingKey(event)
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
        } else if (key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
          root.move(-1)
        } else if (key === Qt.Key_Right || event.key === Qt.Key_Tab) {
          root.move(1)
        } else if (event.key === Qt.Key_Up) {
          root.selectedIndex = GridLayout.verticalNeighbour(root.cells, root.selectedIndex, -1)
        } else if (event.key === Qt.Key_Down) {
          root.selectedIndex = GridLayout.verticalNeighbour(root.cells, root.selectedIndex, 1)
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          root.activate(root.selectedIndex)
        } else {
          return
        }
        event.accepted = true
      }
    }

    Item {
      id: grid
      anchors.fill: parent
      anchors.margins: root.margin

      Repeater {
        model: root.windows

        delegate: Item {
          id: cell

          required property int index
          required property var modelData

          readonly property var box: root.cells[index] || { x: 0, y: 0, width: 0, height: 0 }
          readonly property bool selected: index === root.selectedIndex

          x: box.x
          y: box.y
          width: box.width
          height: box.height + root.labelHeight
          scale: selected ? 1.03 : 1
          z: selected ? 1 : 0

          Behavior on scale {
            NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
          }

          // Lifts the selected thumbnail off the backdrop.
          RectangularShadow {
            anchors.fill: frame
            radius: Style.cornerRadius
            offset.y: Style.space(8)
            blur: Style.space(36)
            spread: Style.space(4)
            color: Qt.rgba(0, 0, 0, 0.6)
            opacity: cell.selected ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
              NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
            }
          }

          Rectangle {
            id: frame
            width: cell.box.width
            height: cell.box.height
            radius: Style.cornerRadius
            color: Qt.rgba(0, 0, 0, 0.35)
            clip: true

            ScreencopyView {
              id: thumbnail
              anchors.centerIn: parent
              captureSource: root.opened && panel.contentRevealed && root.hasMonitor() ? cell.modelData.wayland : null
              live: true
              constraintSize: Qt.size(frame.width, frame.height)
              onSourceSizeChanged: root.measured(cell.modelData.address, sourceSize)
            }
          }

          // Thin outline so a dark window still reads against the backdrop.
          Rectangle {
            anchors.fill: frame
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.65)
            visible: !cell.selected
          }

          // Sits wholly outside the thumbnail, like Hyprland's border on the
          // active window: square corners unless Hyprland rounds its windows.
          Rectangle {
            anchors.fill: frame
            anchors.margins: -border.width
            radius: Style.cornerRadius > 0 ? Style.cornerRadius + border.width : 0
            color: "transparent"
            border.width: 2
            border.color: root.accent
            visible: cell.selected
          }

          Row {
            anchors.top: frame.bottom
            anchors.topMargin: Style.space(8)
            anchors.horizontalCenter: frame.horizontalCenter
            spacing: Style.space(6)

            Image {
              width: Style.font.body + Style.space(4)
              height: width
              sourceSize: Qt.size(width * 2, height * 2)
              source: root.iconSource(cell.modelData.appId)
              asynchronous: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: cell.modelData.title || cell.modelData.appId
              color: root.foreground
              opacity: cell.selected ? 1 : 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Math.max(0, cell.box.width - Style.font.body - Style.space(10)))
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) root.selectedIndex = cell.index
            onClicked: root.activate(cell.index)
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: root.windows.length === 0
      text: strings.t("birdseye.empty")
      color: root.foreground
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }
  }
}
