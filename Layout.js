.pragma library

// Lays windows out as a flat grid of justified rows: every thumbnail in the
// grid has the same height and keeps its window's shape. Tries every row
// count and keeps the one that lets the thumbnails be largest.

function clampAspect(aspect) {
  var value = Number(aspect)
  if (!isFinite(value) || value <= 0) return 16 / 9
  return Math.max(0.5, Math.min(3, value))
}

// Splits the aspects, in order, into `rowCount` rows of roughly equal width.
function splitRows(aspects, rowCount) {
  var total = 0
  for (var i = 0; i < aspects.length; i++) total += aspects[i]

  var rows = []
  var row = []
  var sum = 0
  var used = 0
  for (var j = 0; j < aspects.length; j++) {
    row.push(j)
    sum += aspects[j]
    used += aspects[j]
    var rowsLeft = rowCount - rows.length - 1
    var itemsLeft = aspects.length - j - 1
    var boundary = total * (rows.length + 1) / rowCount
    var mustBreak = itemsLeft === rowsLeft
    if (rowsLeft > 0 && itemsLeft > 0 && (mustBreak || used >= boundary - aspects[j] / 2)) {
      rows.push({ items: row, sum: sum })
      row = []
      sum = 0
    }
  }
  if (row.length > 0) rows.push({ items: row, sum: sum })
  return rows
}

function rowHeight(rows, width, height, gap, labelHeight) {
  var best = (height - (rows.length - 1) * gap) / rows.length - labelHeight
  for (var i = 0; i < rows.length; i++) {
    var fit = (width - (rows[i].items.length - 1) * gap) / rows[i].sum
    if (fit < best) best = fit
  }
  return best
}

// aspects: width / height of each window. Returns one { x, y, width, height }
// per window, in the same order; height excludes the label below it.
function compute(aspects, width, height, gap, labelHeight, maxHeight) {
  var count = aspects.length
  if (count === 0 || width <= 0 || height <= 0) return []

  var clamped = []
  for (var i = 0; i < count; i++) clamped.push(clampAspect(aspects[i]))

  var bestRows = null
  var bestHeight = -Infinity
  for (var rowCount = 1; rowCount <= count; rowCount++) {
    var rows = splitRows(clamped, rowCount)
    var candidate = rowHeight(rows, width, height, gap, labelHeight)
    if (bestRows === null || candidate > bestHeight) {
      bestHeight = candidate
      bestRows = rows
    }
  }

  var cellHeight = Math.max(1, Math.floor(Math.min(bestHeight, maxHeight)))
  var blockHeight = bestRows.length * (cellHeight + labelHeight) + (bestRows.length - 1) * gap
  var y = Math.round((height - blockHeight) / 2)

  var cells = new Array(count)
  for (var r = 0; r < bestRows.length; r++) {
    var items = bestRows[r].items
    var rowWidth = (items.length - 1) * gap
    for (var k = 0; k < items.length; k++) rowWidth += Math.round(clamped[items[k]] * cellHeight)
    var x = Math.round((width - rowWidth) / 2)
    for (var m = 0; m < items.length; m++) {
      var cellWidth = Math.round(clamped[items[m]] * cellHeight)
      cells[items[m]] = { x: x, y: y, width: cellWidth, height: cellHeight, row: r }
      x += cellWidth + gap
    }
    y += cellHeight + labelHeight + gap
  }
  return cells
}

// The index reached by moving one row up (-1) or down (1) from `index`,
// landing on the cell nearest horizontally.
function verticalNeighbour(cells, index, delta) {
  var from = cells[index]
  if (!from) return index
  var centre = from.x + from.width / 2
  var best = index
  var bestDistance = Infinity
  for (var i = 0; i < cells.length; i++) {
    if (cells[i].row !== from.row + delta) continue
    var distance = Math.abs(cells[i].x + cells[i].width / 2 - centre)
    if (distance < bestDistance) {
      bestDistance = distance
      best = i
    }
  }
  return best
}
