# SPDX-License-Identifier: LGPL-2.1-or-later
## The one table widget for every list a game sends (docs/systems/
## interface-layout.md, "Tables"). It draws the server's table shape (title,
## columns, rows, opening sort, filters, empty state, note; DorfCraft's
## docs/interface-rules.md): a title, a search box and the server's filters
## above a Tree whose headings sort, the note below, and a centred empty
## state in place of the rows when there are none.
##
## Rows carry two optional fields beyond that shape: keys (column id to the
## value to sort by, where the displayed text would sort wrongly) and
## detail (lines shown when the row is chosen). Ids never reach the screen.
## A column marked wide takes the width the others leave; they are then
## fitted to their longest cell.
##
## Choosing a row (click, arrows) emits row_chosen; Enter or a double click
## emits row_activated. Locked rows are greyed with their reason as the
## tooltip and come with locked = true; the host shows the reason and offers
## nothing else. Typing while the rows have focus goes to the search box.
##
## A grouped table (grouped = true, with the server's groups: id, label,
## kinds, cells, keys, state, reason, detail, pos and the ids of its rows)
## draws one row per group with its rows indented beneath, closed until
## opened by a click, Enter or the right arrow (the left arrow closes it).
## Groups sort by their own cells and keys among the plain rows, and their
## rows sort the same way within. A search matches the rows' text and the
## group's label, and opens every group it leaves. A group with one row
## left is drawn as that row. A chosen group is emitted as the group, with
## group_row = true and its rows shown as variants; it is never activated.
extends VBoxContainer

signal row_chosen(row: Dictionary)
signal row_activated(row: Dictionary)
## The rows shown changed, by search, filter or a new table.
signal view_changed

const QUIET := Color(1, 1, 1, 0.5)
## Shown rows in body text, locked rows clearly quieter.
const TEXT := Color(0.92, 0.94, 0.96)
const GREY := Color(0.5, 0.52, 0.56)
const ASC := " ▲"
const DESC := " ▼"
## A fitted column's most characters, beside a wide one, and the least a
## wide one keeps.
const FIT := 20
const WIDE_MIN := 24

var shape: Dictionary = {}
var sort_column := ""
var sort_order := "asc"
var filter_values := {}
var selected_id := ""
## Rows in display order after search, filters and sort: plain rows and
## group entries (group_row, with variants), top level only.
var shown_rows: Array = []
## Groups the player opened, by group id, kept across refreshes.
var open_groups := {}
var _building := false
## Takes a glyph name and returns a Texture2D or null; set by the host.
var glyph_texture: Callable

var title_label: Label
var tools: HFlowContainer
var search: LineEdit
var filters: HBoxContainer
## The host's quiet buttons (Refresh) sit here, at the end of the tools.
var host_tools: HBoxContainer
var tree: Tree
var empty_box: VBoxContainer
var empty_why: Label
var empty_what: Label
var empty_clear: Button
var note: Label

func _init() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	title_label = Label.new()
	title_label.add_theme_font_size_override("font_size", 23)
	add_child(title_label)
	# Wraps rather than widening the table when large text leaves no room.
	tools = HFlowContainer.new()
	tools.add_theme_constant_override("h_separation", 8)
	tools.add_theme_constant_override("v_separation", 8)
	add_child(tools)
	search = LineEdit.new()
	search.placeholder_text = "Search"
	search.clear_button_enabled = true
	search.custom_minimum_size = Vector2(220, 40)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(func(_t: String) -> void: _refresh_rows())
	search.gui_input.connect(_search_input)
	tools.add_child(search)
	filters = HBoxContainer.new()
	filters.add_theme_constant_override("separation", 8)
	tools.add_child(filters)
	host_tools = HBoxContainer.new()
	host_tools.add_theme_constant_override("separation", 8)
	tools.add_child(host_tools)
	tree = Tree.new()
	tree.hide_root = true
	tree.column_titles_visible = true
	tree.select_mode = Tree.SELECT_ROW
	tree.allow_search = false
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.focus_mode = Control.FOCUS_ALL
	tree.column_title_clicked.connect(func(column: int, _button: int) -> void: sort_by_index(column))
	tree.item_selected.connect(_on_selected)
	tree.item_activated.connect(_on_activated)
	tree.item_collapsed.connect(_on_collapsed)
	tree.gui_input.connect(_tree_input)
	add_child(tree)
	empty_box = VBoxContainer.new()
	empty_box.alignment = BoxContainer.ALIGNMENT_CENTER
	empty_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	empty_box.add_theme_constant_override("separation", 12)
	add_child(empty_box)
	empty_why = Label.new()
	empty_why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_why.add_theme_font_size_override("font_size", 23)
	empty_box.add_child(empty_why)
	empty_what = Label.new()
	empty_what.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_box.add_child(empty_what)
	empty_clear = Button.new()
	empty_clear.text = "Clear search and filters"
	empty_clear.custom_minimum_size.y = 40
	empty_clear.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	empty_clear.pressed.connect(clear_view)
	empty_box.add_child(empty_clear)
	note = Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", QUIET)
	add_child(note)

## Takes a table. A table with the same title keeps the player's sort,
## search, filters and chosen row; another table starts from its own
## opening sort with no search or filter.
func set_table(value: Dictionary) -> void:
	# Hosts refresh often; an unchanged table keeps its rows and focus.
	if not shape.is_empty() and value == shape: return
	var same := not shape.is_empty() and str(shape.get("title", "")) == str(value.get("title", ""))
	shape = value
	if not same:
		var opening: Dictionary = value.get("sort", {}) if value.get("sort") is Dictionary else {}
		sort_column = str(opening.get("column", ""))
		sort_order = "desc" if str(opening.get("order", "asc")) == "desc" else "asc"
		filter_values.clear()
		search.text = ""
		selected_id = ""
		open_groups.clear()
	if _column_index(sort_column) < 0:
		var cols := columns()
		sort_column = str(cols[0].get("id", "")) if not cols.is_empty() else ""
	title_label.text = str(value.get("title", ""))
	title_label.visible = not title_label.text.is_empty()
	note.text = str(value.get("note", "")) if value.get("note") is String else ""
	note.visible = not note.text.is_empty()
	_build_filters()
	_build_columns()
	_refresh_rows()

## Lays the columns out again after the text size changed.
func refit() -> void:
	_build_columns()

func columns() -> Array:
	var out: Array = []
	if shape.get("columns") is Array:
		for c in shape.columns:
			if c is Dictionary and c.has("id"): out.append(c)
	return out

func rows() -> Array:
	var out: Array = []
	if shape.get("rows") is Array:
		for r in shape.rows:
			if r is Dictionary and r.get("cells") is Dictionary: out.append(r)
	return out

func _column_index(id: String) -> int:
	var cols := columns()
	for i in cols.size():
		if str(cols[i].id) == id: return i
	return -1

func _build_filters() -> void:
	for child in filters.get_children():
		filters.remove_child(child)
		child.queue_free()
	if not shape.get("filters") is Array: return
	for f in shape.filters:
		if not f is Dictionary or not f.get("options") is Array: continue
		var id := str(f.get("id", ""))
		var label := Label.new()
		label.text = str(f.get("label", ""))
		filters.add_child(label)
		var pick := OptionButton.new()
		pick.custom_minimum_size.y = 40
		pick.add_item("All")
		var chosen := 0
		for option in f.options:
			pick.add_item(str(option))
			if str(option) == str(filter_values.get(id, "")): chosen = pick.item_count - 1
		pick.select(chosen)
		pick.set_meta("filter", id)
		pick.item_selected.connect(func(i: int) -> void:
			filter_values[id] = "" if i == 0 else pick.get_item_text(i)
			_refresh_rows())
		filters.add_child(pick)

func _build_columns() -> void:
	var cols := columns()
	tree.columns = maxi(1, cols.size())
	var wide := -1
	for i in cols.size():
		if cols[i].get("wide", false) == true:
			wide = i
			break
	for i in cols.size():
		var c: Dictionary = cols[i]
		var number := str(c.get("kind", "text")) == "number"
		var arrow := (ASC if sort_order == "asc" else DESC) if str(c.id) == sort_column else ""
		tree.set_column_title(i, str(c.get("label", "")) + arrow)
		tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT if number else HORIZONTAL_ALIGNMENT_LEFT)
		tree.set_column_clip_content(i, true)
		var size := tree.get_theme_font_size("font_size")
		var chars := maxi(5 if number else (14 if i == 0 else 8), str(c.get("label", "")).length() + 3)
		if wide >= 0 and i != wide:
			# A table with a wide column (Plans' title) fits the others to
			# their longest cell, up to FIT characters, and gives the wide
			# one everything they leave.
			var longest := str(c.get("label", "")).length() + 3
			for r in rows():
				longest = maxi(longest, _cell_text(r.cells.get(str(c.id))).length() + 2)
			chars = mini(longest, FIT)
			tree.set_column_expand(i, false)
			var icon := 24 if str(c.get("kind", "")) == "swatch" or (i == 0 and _has_glyphs()) else 0
			# About half an em a character for mixed text.
			tree.set_column_custom_minimum_width(i, int(size * 0.52 * chars) + icon)
			continue
		if i == wide:
			# The wide column keeps a readable title before the rest
			# scroll sideways.
			chars = maxi(chars, WIDE_MIN)
		tree.set_column_expand(i, true)
		# The first column names the row; it gets the most room.
		tree.set_column_expand_ratio(i, 1 if number else (3 if i == 0 else 2))
		# Enough for a short value at the current text size; past that the
		# rows scroll sideways rather than clipping every cell to nothing.
		tree.set_column_custom_minimum_width(i, int(size * 0.6 * chars))

func _has_glyphs() -> bool:
	for r in rows():
		if r.get("glyph") is String: return true
	return false

## Clicking a heading sorts by it; clicking it again reverses.
func sort_by_index(index: int) -> void:
	var cols := columns()
	if index < 0 or index >= cols.size(): return
	var id := str(cols[index].id)
	if id == sort_column: sort_order = "desc" if sort_order == "asc" else "asc"
	else:
		sort_column = id
		sort_order = "asc"
	_build_columns()
	_refresh_rows()

func sort_by(id: String, order := "") -> void:
	var index := _column_index(id)
	if index < 0: return
	sort_column = id
	sort_order = order if order in ["asc", "desc"] else "asc"
	_build_columns()
	_refresh_rows()

func clear_view() -> void:
	filter_values.clear()
	search.text = ""
	_build_filters()
	_refresh_rows()

static func _sort_value(row: Dictionary, column: String) -> Variant:
	if row.get("keys") is Dictionary and row.keys.has(column): return row.keys[column]
	return row.cells.get(column)

## The server's order: missing last either way, numbers before text, ties by
## the first column and then the row id (DorfCraft overseer/tables.lua).
func _less(a: Dictionary, b: Dictionary) -> bool:
	var va: Variant = _sort_value(a, sort_column)
	var vb: Variant = _sort_value(b, sort_column)
	if va != null and vb != null and typeof(va) != typeof(vb) and not (_is_number(va) and _is_number(vb)):
		return _is_number(va)
	if va == null and vb != null: return false
	if vb == null and va != null: return true
	if va != null and vb != null:
		if va is String:
			va = (va as String).to_lower()
			vb = str(vb).to_lower()
		if va != vb: return va > vb if sort_order == "desc" else va < vb
	var cols := columns()
	var first := str(cols[0].id) if not cols.is_empty() else ""
	var fa := str(a.cells.get(first, "")).to_lower()
	var fb := str(b.cells.get(first, "")).to_lower()
	if fa != fb: return fa < fb
	return str(a.get("id", "")) < str(b.get("id", ""))

static func _is_number(v: Variant) -> bool:
	return v is int or v is float

func _matches(row: Dictionary, needle: String) -> bool:
	return _passes_filters(row) and _has_text(row, needle)

func _passes_filters(row: Dictionary) -> bool:
	for id in filter_values:
		var wanted := str(filter_values[id])
		if not wanted.is_empty() and str(row.get(id, "")) != wanted: return false
	return true

func _has_text(row: Dictionary, needle: String) -> bool:
	if needle.is_empty(): return true
	if not row.get("cells") is Dictionary: return false
	for c in columns():
		var v: Variant = row.cells.get(str(c.id))
		if v != null and str(v).to_lower().contains(needle): return true
	return false

## The server's groups, by row id, for a grouped table.
func _groups_by_row() -> Dictionary:
	var out := {}
	if shape.get("grouped", false) != true or not shape.get("groups") is Array: return out
	for g in shape.groups:
		if not g is Dictionary or not g.get("cells") is Dictionary or not g.get("rows") is Array: continue
		for id in g.rows: out[str(id)] = g
	return out

func _refresh_rows() -> void:
	var needle := search.text.strip_edges().to_lower()
	shown_rows.clear()
	var member := _groups_by_row()
	var kids := {}
	var order: Array = []
	for r in rows():
		var g: Variant = member.get(str(r.get("id", "")))
		if not _passes_filters(r): continue
		if not (_has_text(r, needle) or (g != null and _has_text(g, needle))): continue
		if g == null:
			shown_rows.append(r)
			continue
		var gid := str(g.get("id", ""))
		if not kids.has(gid):
			kids[gid] = []
			order.append(g)
		kids[gid].append(r)
	for g in order:
		var list: Array = kids[str(g.get("id", ""))]
		if list.size() == 1:
			shown_rows.append(list[0])
			continue
		var entry: Dictionary = g.duplicate()
		entry["group_row"] = true
		entry["variants"] = list
		shown_rows.append(entry)
	if not sort_column.is_empty():
		shown_rows.sort_custom(_less)
		for r in shown_rows:
			if r.get("group_row", false): r.variants.sort_custom(_less)
	_building = true
	tree.clear()
	var root := tree.create_item()
	var chosen: TreeItem = null
	for r in shown_rows:
		var item := _add_row(root, r)
		if str(r.get("id", "")) == selected_id and not selected_id.is_empty(): chosen = item
		if r.get("group_row", false):
			for v in r.variants:
				var child := _add_row(item, v)
				if str(v.get("id", "")) == selected_id and not selected_id.is_empty(): chosen = child
			# Closed until opened; a search opens every group it leaves.
			item.collapsed = needle.is_empty() and not open_groups.has(str(r.get("id", "")))
	if chosen != null:
		var up := chosen.get_parent()
		if up != null and up != root: up.collapsed = false
		chosen.select(0)
		tree.scroll_to_item(chosen)
	_building = false
	var none := shown_rows.is_empty()
	tree.visible = not none
	empty_box.visible = none
	if none:
		var all_empty := rows().is_empty()
		var empty: Dictionary = shape.get("empty", {}) if shape.get("empty") is Dictionary else {}
		empty_why.text = str(empty.get("why", "Nothing to show.")) if all_empty else "No rows match."
		empty_what.text = str(empty.get("what", "")) if all_empty else "Clear the search or set the filters to All."
		empty_what.visible = not empty_what.text.is_empty()
		empty_clear.visible = not all_empty
	view_changed.emit()

## One row's item under parent: its cells, greyed when locked, its glyph
## and swatch. A group's first cell names it, with how many kinds it holds.
func _add_row(parent: TreeItem, r: Dictionary) -> TreeItem:
	var cols := columns()
	var item := tree.create_item(parent)
	var locked := str(r.get("state", "shown")) == "locked"
	for i in cols.size():
		var c: Dictionary = cols[i]
		var v: Variant = r.cells.get(str(c.id))
		item.set_text(i, _cell_text(v))
		if str(c.get("kind", "text")) == "number": item.set_text_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT)
		if locked:
			item.set_custom_color(i, GREY)
			item.set_tooltip_text(i, str(r.get("reason", "Not available yet.")))
		else:
			item.set_custom_color(i, TEXT)
			item.set_tooltip_text(i, "")
	if r.get("glyph") is String and glyph_texture.is_valid():
		var tex: Variant = glyph_texture.call(r.glyph)
		if tex is Texture2D:
			item.set_icon(0, tex)
			item.set_icon_max_width(0, 22)
			if locked: item.set_icon_modulate(0, Color(1, 1, 1, 0.45))
	# A swatch column (a house's colour) leads its label with the colour.
	for i in cols.size():
		if str(cols[i].get("kind", "")) == "swatch" and r.get("swatch") is String and Color.html_is_valid(r.swatch):
			item.set_icon(i, swatch(Color.html(r.swatch)))
	if r.get("group_row", false):
		var count := str(r.count_text) if r.has("count_text") else "(%d kinds)" % int(r.get("kinds", r.variants.size()))
		if not count.is_empty(): item.set_suffix(0, count)
	item.set_metadata(0, r)
	return item

static var swatches := {}
## A small square of one colour, cached.
static func swatch(colour: Color) -> Texture2D:
	var key := colour.to_html(false)
	if not swatches.has(key):
		var image := Image.create(18, 18, false, Image.FORMAT_RGBA8)
		image.fill(colour)
		swatches[key] = ImageTexture.create_from_image(image)
	return swatches[key]

func _cell_text(v: Variant) -> String:
	if v == null: return ""
	if v is float and is_equal_approx(v, roundf(v)): return str(int(v))
	return str(v)

func selected_row() -> Dictionary:
	if selected_id.is_empty(): return {}
	for r in shown_rows:
		if str(r.get("id", "")) == selected_id: return r
		if r.get("group_row", false):
			for v in r.variants:
				if str(v.get("id", "")) == selected_id: return v
	return {}

func row_locked(r: Dictionary) -> bool:
	return str(r.get("state", "shown")) == "locked"

func _on_selected() -> void:
	var item := tree.get_selected()
	if item != null: _choose(item.get_metadata(0))

## Emits a choice once per change of row, whether it came from the Tree or
## from choose_index (TreeItem.select does not always signal).
func _choose(r: Dictionary) -> void:
	var id := str(r.get("id", ""))
	if id == selected_id: return
	selected_id = id
	row_chosen.emit(r)

## Enter or a double click: a group opens or closes; a row is activated.
func _on_activated() -> void:
	var item := tree.get_selected()
	if item == null: return
	var r: Dictionary = item.get_metadata(0)
	selected_id = str(r.get("id", ""))
	if r.get("group_row", false):
		set_open(item, item.collapsed)
		return
	row_activated.emit(r)

## Opens or closes a group's item, remembered across refreshes.
func set_open(item: TreeItem, open: bool) -> void:
	if item == null or item.get_child_count() == 0: return
	item.collapsed = not open
	_on_collapsed(item)

func _on_collapsed(item: TreeItem) -> void:
	if _building: return
	var r: Variant = item.get_metadata(0)
	if not r is Dictionary or not r.get("group_row", false): return
	var id := str(r.get("id", ""))
	if item.collapsed: open_groups.erase(id)
	else: open_groups[id] = true

## Opens or closes the group with this id, if it is shown.
func open_group(id: String, open := true) -> void:
	var root := tree.get_root()
	if root == null: return
	for item in root.get_children():
		var r: Variant = item.get_metadata(0)
		if r is Dictionary and str(r.get("id", "")) == id: set_open(item, open)

## Chooses a row by position in the current order, as the arrows do.
func choose_index(index: int) -> void:
	if index < 0 or index >= shown_rows.size(): return
	var root := tree.get_root()
	if root == null: return
	var item := root.get_child(index)
	if item == null: return
	item.select(0)
	tree.scroll_to_item(item)
	_choose(item.get_metadata(0))

## Chooses the row with this id, if it is shown; a row in a group opens it.
func choose_id(id: String) -> void:
	for i in shown_rows.size():
		if str(shown_rows[i].get("id", "")) == id:
			choose_index(i)
			return
	var root := tree.get_root()
	if root == null: return
	for parent in root.get_children():
		for item in parent.get_children():
			var r: Dictionary = item.get_metadata(0)
			if str(r.get("id", "")) == id:
				set_open(parent, true)
				item.select(0)
				tree.scroll_to_item(item)
				_choose(r)
				return

func clear_choice() -> void:
	selected_id = ""
	tree.deselect_all()

## Gives the rows focus, choosing the first when none is chosen.
func focus_rows() -> void:
	if tree.visible:
		tree.grab_focus()
		if tree.get_selected() == null: choose_index(0)
	else:
		search.grab_focus()

func _tree_input(event: InputEvent) -> void:
	# A click on a group's row opens it (its arrow toggles it as usual).
	if event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var at := tree.get_item_at_position((event as InputEventMouseButton).position)
		if at != null and at.get_child_count() > 0 and at.collapsed:
			var r: Variant = at.get_metadata(0)
			if r is Dictionary and r.get("group_row", false):
				set_open.call_deferred(at, true)
		return
	if not event is InputEventKey or not event.pressed: return
	var key := event as InputEventKey
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed: return
	# Right opens the chosen group; left closes it, or goes up from a row
	# in a group to the group and closes it.
	var selected := tree.get_selected()
	if selected != null and key.keycode in [KEY_RIGHT, KEY_LEFT]:
		var parent := selected.get_parent()
		var in_group := parent != null and parent != tree.get_root()
		if key.keycode == KEY_RIGHT and selected.get_child_count() > 0:
			set_open(selected, true)
			tree.accept_event()
			return
		if key.keycode == KEY_LEFT and (selected.get_child_count() > 0 or in_group):
			var group := selected if selected.get_child_count() > 0 else parent
			set_open(group, false)
			if group != selected:
				group.select(0)
				tree.scroll_to_item(group)
				_choose(group.get_metadata(0))
			tree.accept_event()
			return
	if key.unicode >= 32 and key.unicode != 127:
		search.grab_focus()
		search.insert_text_at_caret(char(key.unicode))
		tree.accept_event()

func _search_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_DOWN:
		focus_rows()
		search.accept_event()
