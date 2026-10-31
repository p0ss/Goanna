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
##
## Choosing a row (click, arrows) emits row_chosen; Enter or a double click
## emits row_activated. Locked rows are greyed with their reason as the
## tooltip and come with locked = true; the host shows the reason and offers
## nothing else. Typing while the rows have focus goes to the search box.
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

var shape: Dictionary = {}
var sort_column := ""
var sort_order := "asc"
var filter_values := {}
var selected_id := ""
## Rows in display order after search, filters and sort.
var shown_rows: Array = []
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
	for i in cols.size():
		var c: Dictionary = cols[i]
		var number := str(c.get("kind", "text")) == "number"
		var arrow := (ASC if sort_order == "asc" else DESC) if str(c.id) == sort_column else ""
		tree.set_column_title(i, str(c.get("label", "")) + arrow)
		tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_RIGHT if number else HORIZONTAL_ALIGNMENT_LEFT)
		tree.set_column_expand(i, true)
		# The first column names the row; it gets the most room.
		tree.set_column_expand_ratio(i, 1 if number else (3 if i == 0 else 2))
		tree.set_column_clip_content(i, true)
		# Enough for a short value at the current text size; past that the
		# rows scroll sideways rather than clipping every cell to nothing.
		var size := tree.get_theme_font_size("font_size")
		var chars := maxi(5 if number else 8, str(c.get("label", "")).length() + 3)
		tree.set_column_custom_minimum_width(i, int(size * 0.6 * chars))

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
	for id in filter_values:
		var wanted := str(filter_values[id])
		if not wanted.is_empty() and str(row.get(id, "")) != wanted: return false
	if needle.is_empty(): return true
	for c in columns():
		var v: Variant = row.cells.get(str(c.id))
		if v != null and str(v).to_lower().contains(needle): return true
	return false

func _refresh_rows() -> void:
	var needle := search.text.strip_edges().to_lower()
	shown_rows.clear()
	for r in rows():
		if _matches(r, needle): shown_rows.append(r)
	if not sort_column.is_empty(): shown_rows.sort_custom(_less)
	tree.clear()
	var root := tree.create_item()
	var cols := columns()
	var chosen: TreeItem = null
	for r in shown_rows:
		var item := tree.create_item(root)
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
		item.set_metadata(0, r)
		if str(r.get("id", "")) == selected_id and not selected_id.is_empty(): chosen = item
	if chosen != null:
		chosen.select(0)
		tree.scroll_to_item(chosen)
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
	for r in shown_rows:
		if str(r.get("id", "")) == selected_id and not selected_id.is_empty(): return r
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

func _on_activated() -> void:
	var item := tree.get_selected()
	if item == null: return
	var r: Dictionary = item.get_metadata(0)
	selected_id = str(r.get("id", ""))
	row_activated.emit(r)

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

## Chooses the row with this id, if it is shown.
func choose_id(id: String) -> void:
	for i in shown_rows.size():
		if str(shown_rows[i].get("id", "")) == id:
			choose_index(i)
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
	if not event is InputEventKey or not event.pressed: return
	var key := event as InputEventKey
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed: return
	if key.unicode >= 32 and key.unicode != 127:
		search.grab_focus()
		search.insert_text_at_caret(char(key.unicode))
		tree.accept_event()

func _search_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_DOWN:
		focus_rows()
		search.accept_event()
