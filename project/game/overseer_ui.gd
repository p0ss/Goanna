# SPDX-License-Identifier: LGPL-2.1-or-later
## The overseer camera's planning controls: tool families, the draft and its
## submit and discard, the plans list and the map navigation buttons. Made by
## game/overseer.gd when the view opens, with view set to that overseer; the
## buttons call back into it. Independent of the isolated terrain renderer.
extends RefCounted

var view: Node
var header: Label
var title: Label
var material_label: Label
var actions: VBoxContainer
var context: VBoxContainer
var rail: VBoxContainer
var panel: PanelContainer
var draft_label: Label
var submit: Button
var discard: Button
var return_draft: Button
var plans: ItemList
var plan_detail: Label
var locate: Button
var cancel: Button
var act: Button
var page_banner: Button
var plans_button: Button
## The footer's View menu: one button whose list holds a check item per
## map overlay and, once the server answers that it draws world marks, the
## Marks setting (interface-layout.md: no row of equal toggles).
var view_menu: MenuButton
## Overlays the menu offers now; a task view offers only its own.
var overlay_offered := {}
## null until the server says whether this player's world marks show.
var marks_shown: Variant = null
const MARKS_ITEM := 100
const OVERLAYS := [["rooms", "Rooms", "Show room quality by tier"],
	["miasma", "Miasma", "Show smell from seen carrion"],
	["traffic", "Traffic", "Show where workers go, where they are and their recent trails"],
	["heat", "Heat", "Show how hot or cold the fortress has found each place"],
	["wet", "Wetness", "Show how wet or dry the fortress has found each place"],
	["ownership", "Houses", "Show which house holds each place"],
	["access", "Access", "Show what each house has shared or locked"]]
var family := "Select"
var records: Array = []
var selected_id := ""
var capabilities: Dictionary = {}
var map_button: Button
var top: PanelContainer
var left: PanelContainer
var nav: PanelContainer
var footer: PanelContainer
var navigation: GridContainer
var overview: Dictionary = {}
var overview_text: Label
var overview_refresh: Button
var zone_property: Label
var zone_options: OptionButton
var zone_tools: Array = []
var requirements: Label
var player_location: Label
var verb_strip: PanelContainer
var verb_heading: Label
var verb_row: HFlowContainer
var verbs_expanded := false
var verb_key: Variant = null
const STRIP_VERBS := 6
## Verb icons, named by the server so each means one thing everywhere.
const ICONS := "res://ui/overseer_icons/"
static var icon_cache := {}
var nudges: VBoxContainer
var houses: RefCounted
## The main-area table (ui/data_table.gd) for People, Supplies and the
## workshop picker; it covers the map while shown.
const DataTable := preload("res://ui/data_table.gd")
const QUIET := Color(0.62, 0.64, 0.68)
const SELECT_HINT := "Select a cell to inspect it. The world remains live."
var table_panel: PanelContainer
var table: DataTable
var table_refresh: Button
## The server's Plans table (DorfCraft tables.lua, plans_table), or empty
## for an older server, whose list stays in the side panel.
var plans_table: Dictionary = {}
## The chosen Plans row's actions (Act, Drop, Cancel) in the context panel.
var detail_actions: VBoxContainer
var detail_actions_key: Variant = null
var accent_style: StyleBoxFlat
## Houses: "" for the table, "manage" for the owner's controls, offices
## and the head's workers, "mark" for the access marks on the map.
var houses_mode := ""
var houses_manage: Button
var houses_mark: Button
var houses_back: Button
## "people", "supplies", "workshops", "plans", "houses" or "" when the map shows.
var table_kind := ""
var detail: VBoxContainer
var detail_body: Label
var detail_reason: Label
var detail_primary: Button
var change_workshop: Button
var other_tools: Button
## The picker reopened over a chosen workshop by Change workshop.
var picking_workshop := false
## Footer toggles put away while a table covers the map.
var footer_hidden: Array = []
var table_scale := 0.0
## Every section button: Select in the header, the rest on the rail.
var family_buttons: Array = []
var rail_scroll: ScrollContainer
var rail_headings := {}
## The rail's groups and their sections, as DorfCraft's sections.lua
## groups them (maintainer, 31 October 2026).
const RAIL_GROUPS := [["plan", "Plan", ["Zones", "Build", "Terrain", "Gather", "Devices", "Defence"]],
	["fortress", "Fortress", ["People", "Supplies", "Houses", "Plans"]]]

func label(parent: Node, text: String) -> Label:
	var result := Label.new()
	result.text = text
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(result)
	return result

func button(parent: Node, text: String, action: Callable) -> Button:
	var result := Button.new()
	result.text = text
	result.custom_minimum_size = Vector2(48, 48)
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result.pressed.connect(action)
	parent.add_child(result)
	return result

## One section's button. Labels never wrap: the rail widens to its longest
## label, and scrolls at large text instead.
func section_button(parent: Node, name: String) -> Button:
	var b := button(parent, name, choose_family.bind(name))
	b.set_meta("family", name)
	b.autowrap_mode = TextServer.AUTOWRAP_OFF
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = "Inspect places and objects" if name == "Select" else name
	if parent != rail: b.size_flags_horizontal = Control.SIZE_SHRINK_END
	family_buttons.append(b)
	return b

## The icon the server named, or null for a name this client does not draw.
static func icon_for(name: Variant) -> Texture2D:
	if not name is String or not (name as String).is_valid_identifier(): return null
	if not icon_cache.has(name):
		var path: String = ICONS + name + ".svg"
		icon_cache[name] = load(path) if ResourceLoader.exists(path) else null
	return icon_cache[name]

## Server picture glyphs are the same media used in ledgers and the guide.
## Older servers keep their existing verb icons and readable section names.
func rune_for(name: Variant) -> Texture2D:
	if not name is String or not (name as String).is_valid_identifier(): return null
	if not view.client.has_method("texture"): return null
	return view.client.texture("dorfcraft_runes_%s_ink.png" % name)

func set_icon(b: Button, name: Variant, dim := false, rune: Variant = null) -> void:
	var texture := rune_for(rune)
	if texture != null:
		b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	else:
		texture = icon_for(name)
	if texture == null: return
	b.icon = texture
	b.expand_icon = true
	b.add_theme_constant_override("icon_max_width", 24)
	if dim:
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			b.add_theme_color_override("icon_%s_color" % state, Color(1, 1, 1, 0.4))

func box(parent: Node) -> PanelContainer:
	var result := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("17212b")
	style.border_color = Color("52677d")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	result.add_theme_stylebox_override("panel", style)
	parent.add_child(result)
	return result

## Builds every panel under host, the overseer's root Control.
func build(host: Node) -> void:
	view = host
	view.root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font_size = 18
	view.root_control.theme = theme
	top = box(view.root_control)
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12; top.offset_right = -12; top.offset_top = 12
	var row := HBoxContainer.new()
	top.add_child(row)
	header = label(row, "Overseer | Connecting")
	# The view's tools sit in the header (interface-layout.md, Regions):
	# Select, the map's own section, and Map focus for keyboard targeting.
	section_button(row, "Select")
	map_button = button(row, "Map focus", focus_map)
	map_button.tooltip_text = "Arrows: target cell. Enter: select. Tab: controls."
	map_button.autowrap_mode = TextServer.AUTOWRAP_OFF
	map_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	# The newest unseen danger page; pressing it shows where and marks it seen.
	page_banner = button(row, "", open_banner)
	page_banner.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
	page_banner.hide()
	for pair in [["Back", view.go_back], ["Leave", view.leave]]:
		var compact := button(row, pair[0], pair[1])
		compact.autowrap_mode = TextServer.AUTOWRAP_OFF
		compact.size_flags_horizontal = Control.SIZE_SHRINK_END
	left = box(view.root_control)
	left.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	left.offset_left = 12; left.offset_right = 148
	rail_scroll = ScrollContainer.new()
	rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(rail_scroll)
	rail = VBoxContainer.new()
	rail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rail.add_theme_constant_override("separation", 8)
	rail_scroll.add_child(rail)
	# Two groups under small headings (maintainer, 31 October 2026), 24 px
	# apart: the rail's separation plus a spacer.
	for group in RAIL_GROUPS:
		if rail.get_child_count() > 0:
			var gap := Control.new()
			gap.custom_minimum_size.y = 16
			gap.set_meta("rail_group", group[0])
			rail.add_child(gap)
		var heading := Label.new()
		heading.text = group[1]
		heading.add_theme_color_override("font_color", QUIET)
		heading.set_meta("rail_group", group[0])
		rail.add_child(heading)
		rail_headings[group[0]] = heading
		for name in group[2]:
			var b := section_button(rail, name)
			if name == "Plans": plans_button = b
	nudges = VBoxContainer.new()
	rail.add_child(nudges)
	nudges.hide()
	for pair in [["North", 0, 1], ["South", 0, -1], ["West", -1, 0], ["East", 1, 0]]:
		button(nudges, pair[0], nudge.bind(pair[1], pair[2]))
	button(nudges, "Select cell", func() -> void: view.select_cell(view.cursor))
	table_panel = box(view.root_control)
	table_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	table_panel.hide()
	# At large text the table region scrolls; the rows keep a useful height.
	var table_scroll := ScrollContainer.new()
	table_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	table_panel.add_child(table_scroll)
	table = DataTable.new()
	table.glyph_texture = rune_for
	table.row_chosen.connect(show_detail)
	table.row_activated.connect(activate_row)
	table_scroll.add_child(table)
	table_refresh = button(table.host_tools, "Refresh", func() -> void:
		if table_kind == "houses": houses.request()
		else: view._send({"t": "plans"} if table_kind == "plans" else {"t": "overview"}))
	table_refresh.size_flags_horizontal = Control.SIZE_SHRINK_END
	table_refresh.autowrap_mode = TextServer.AUTOWRAP_OFF
	panel = box(view.root_control)
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -316; panel.offset_right = -12
	panel.offset_top = 86; panel.offset_bottom = -156
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	context = VBoxContainer.new()
	context.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	context.add_theme_constant_override("separation", 10)
	scroll.add_child(context)
	title = label(context, "Selection")
	title.add_theme_font_size_override("font_size", 23)
	actions = VBoxContainer.new()
	context.add_child(actions)
	# The chosen table row's detail and its one action.
	detail = VBoxContainer.new()
	detail.add_theme_constant_override("separation", 8)
	context.add_child(detail)
	detail_body = label(detail, "")
	detail_reason = label(detail, "")
	detail_reason.add_theme_color_override("font_color", QUIET)
	detail_actions = VBoxContainer.new()
	detail_actions.add_theme_constant_override("separation", 8)
	detail.add_child(detail_actions)
	detail_primary = button(detail, "Show on map", detail_action)
	accent_style = StyleBoxFlat.new()
	accent_style.bg_color = Color("285b85")
	accent_style.set_corner_radius_all(5)
	detail_primary.add_theme_stylebox_override("normal", accent_style)
	detail.hide()
	zone_property = label(context, "Type")
	zone_options = OptionButton.new()
	zone_options.fit_to_longest_item = false
	zone_options.custom_minimum_size.y = 44
	zone_options.item_selected.connect(func(i: int) -> void:
		if i >= 0 and i < zone_tools.size(): view.choose_tool(str(zone_tools[i].id)))
	context.add_child(zone_options)
	overview_refresh = button(context, "Refresh", func() -> void: view._send({"t": "overview"}))
	overview_text = label(context, "")
	view.palette = OptionButton.new() # Retained for older test harnesses.
	view.palette.hide()
	context.add_child(view.palette)
	material_label = label(context, "Material")
	view.build_material = OptionButton.new()
	view.build_material.custom_minimum_size.y = 44
	view.build_material.fit_to_longest_item = false
	view.build_material.item_selected.connect(func(_i: int) -> void: view.refresh_draft())
	context.add_child(view.build_material)
	requirements = label(context, "")
	change_workshop = button(context, "Change workshop", func() -> void:
		picking_workshop = true
		refresh())
	change_workshop.hide()
	# With a workshop chosen the panel is that workshop's; the other Build
	# tools are one press away, not listed beneath it.
	other_tools = button(context, "Other Build tools", func() -> void: view.choose_tool("inspect"))
	other_tools.hide()
	context.move_child(material_label, 1)
	context.move_child(view.build_material, 2)
	view.facing_picker = OptionButton.new()
	view.facing_picker.custom_minimum_size.y = 44
	for name in ["Facing +Z", "Facing +X", "Facing -Z", "Facing -X"]:
		view.facing_picker.add_item(name)
	view.facing_picker.item_selected.connect(func(_i: int) -> void: view.refresh_draft())
	context.add_child(view.facing_picker)
	view.room_name = LineEdit.new()
	view.room_name.placeholder_text = "Room name (optional)"
	view.room_name.max_length = 80
	view.room_name.custom_minimum_size.y = 44
	context.add_child(view.room_name)
	view.inspector = label(context, SELECT_HINT)
	draft_label = label(context, "")
	return_draft = button(context, "Return to draft level", view.return_to_draft)
	submit = button(context, "Submit plan", view.submit_draft)
	var primary := StyleBoxFlat.new()
	primary.bg_color = Color("285b85")
	primary.set_corner_radius_all(5)
	submit.add_theme_stylebox_override("normal", primary)
	discard = button(context, "Discard draft", view.discard_draft)
	plans = ItemList.new()
	plans.custom_minimum_size.y = 180
	plans.item_selected.connect(select_plan)
	context.add_child(plans)
	plan_detail = label(context, "")
	locate = button(context, "Locate plan", locate_plan)
	cancel = button(context, "Cancel pending work", cancel_plan)
	act = button(context, "Act", act_plan)
	act.tooltip_text = "Do what the office would do, where it can be done from afar."
	houses = preload("res://game/overseer_houses.gd").new(self, context)
	houses_back = button(context, "Back to houses", func() -> void:
		houses_mode = ""
		refresh())
	context.move_child(houses_back, 1)
	houses_back.hide()
	houses_manage = button(table.host_tools, "Offices and workers", func() -> void:
		houses_mode = "manage"
		refresh())
	houses_mark = button(table.host_tools, "Mark access", func() -> void:
		houses_mode = "mark"
		refresh())
	for b in [houses_manage, houses_mark]:
		b.size_flags_horizontal = Control.SIZE_SHRINK_END
		b.autowrap_mode = TextServer.AUTOWRAP_OFF
	nav = box(view.root_control)
	nav.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	nav.offset_left = -316; nav.offset_right = -12
	nav.offset_top = -148; nav.offset_bottom = -66
	navigation = GridContainer.new()
	navigation.columns = 5
	var nav_stack := VBoxContainer.new()
	nav.add_child(nav_stack)
	player_location = label(nav_stack, "You")
	nav_stack.add_child(navigation)
	button(navigation, "Down", view.change_level.bind(-1)).custom_minimum_size.x = 64
	button(navigation, "Up", view.change_level.bind(1))
	button(navigation, "Find you", view.recentre).tooltip_text = "Centre the map on your position and level"
	button(navigation, "-", view.zoom.bind(-1)).tooltip_text = "Zoom out"
	button(navigation, "+", view.zoom.bind(1)).tooltip_text = "Zoom in"
	# The verb strip floats beside the selection. Its buttons are ordinary
	# focusable controls, so Tab and a controller reach them as well.
	verb_strip = box(view.root_control)
	verb_strip.hide()
	var verb_stack := VBoxContainer.new()
	verb_strip.add_child(verb_stack)
	verb_heading = label(verb_stack, "")
	verb_heading.custom_minimum_size.x = 220
	verb_row = HFlowContainer.new()
	verb_stack.add_child(verb_row)
	footer = box(view.root_control)
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 12; footer.offset_right = -12
	footer.offset_top = -58; footer.offset_bottom = -12
	var footer_row := HBoxContainer.new()
	footer.add_child(footer_row)
	view.status = label(footer_row, "Opening overseer view...")
	# One line that shortens rather than wrapping a letter at a time when
	# large text leaves it little room.
	view.status.autowrap_mode = TextServer.AUTOWRAP_OFF
	view.status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	view.status.custom_minimum_size.x = 120
	view_menu = MenuButton.new()
	view_menu.text = "View"
	view_menu.flat = false
	view_menu.custom_minimum_size = Vector2(48, 48)
	view_menu.size_flags_horizontal = Control.SIZE_SHRINK_END
	view_menu.tooltip_text = "Choose what the map shows over the terrain"
	view_menu.focus_mode = Control.FOCUS_ALL
	footer_row.add_child(view_menu)
	var popup := view_menu.get_popup()
	popup.hide_on_checkable_item_selection = false
	popup.id_pressed.connect(choose_view_item)
	popup.about_to_popup.connect(refresh_view_menu)
	for entry in OVERLAYS: overlay_offered[entry[0]] = true
	refresh_view_menu()
	# Legend stays its own quiet button: it is help to read, not a setting
	# to switch, and a menu would hide it behind a second click.
	var legend := button(footer_row, "Legend", func() -> void:
		view.inspector.text = "Black: unexplored. Grey: unavailable. Muted: remembered. Blue-white haze: known space below. Rooms: grey unsurveyed, then bare, furnished, decorated, adorned. Miasma: green, darker where stronger. Traffic: orange, redder where busier; workers cyan. Heat: blue where cold, faint where comfortable, orange to red where hot. Wetness: tan where dry, faint where comfortable, green to deep blue where wet. Red: forbidden area, dark red: locked door, blue: militia station and patrol posts, with a faint ring of its reach; small pale blue squares: the night watch round and the doors it watches (task views other than defence leave these out); pale blue: protected area designation, without guaranteed guard coverage. Amber diagonal lines: partial patrol access. Red crosshatch: sampled patrol posts unreachable. Purple outline: a plan proposed for you. Faint patterned fill: a house's plan, room or designation, in the house colour and the fortress's field pattern. Houses: each house's places tinted in its colour, in place of the patterned fills; the owner's house paler and striped. Access: a ring in the house colour where it is shared, a ring with a solid corner where it is locked. Each plan carries its tool's rune once. Marks: show your planned work in the world too. The world remains live."
	)
	legend.autowrap_mode = TextServer.AUTOWRAP_OFF
	legend.size_flags_horizontal = Control.SIZE_SHRINK_END
	# The chosen row's or workshop's detail sits at the top of the context
	# panel, above the Build tools, with the chosen workshop under it.
	context.move_child(detail, 1)
	context.move_child(material_label, 2)
	context.move_child(view.build_material, 3)
	context.move_child(requirements, 4)
	context.move_child(change_workshop, 5)
	context.move_child(other_tools, 6)
	context.move_child(houses_back, 1)
	view.root_control.resized.connect(reflow)
	view.root_control.theme.changed.connect(func() -> void: reflow.call_deferred())
	top.resized.connect(func() -> void: reflow.call_deferred())
	footer.resized.connect(func() -> void: reflow.call_deferred())
	reflow.call_deferred()
	refresh()

func reflow() -> void:
	if not is_instance_valid(view) or not view.active or view.ui != self or not is_instance_valid(panel): return
	var size: Vector2 = view.get_viewport().get_visible_rect().size
	var scale := maxf(1.0, view.root_control.theme.default_font_size / 18.0)
	var width := minf(336.0 * scale, size.x * (0.34 if table_kind != "" else 0.48))
	var footer_height := maxf(68.0, footer.get_combined_minimum_size().y)
	footer.offset_top = -footer_height - 12
	var top_edge := top.position.y + top.size.y + 8
	var bottom_edge := -footer_height - 20
	left.offset_top = top_edge
	# The rail runs to the window's foot and the footer starts beside it,
	# so both groups fit at 1280 by 720 without scrolling.
	left.offset_bottom = -12
	# As wide as the longest shown label, so none wraps mid-word; at large
	# text, past a quarter of the window, the rail scrolls sideways.
	var widest := 0.0
	for b in family_buttons:
		b.custom_minimum_size = Vector2(0, maxf(40, 18 * scale * 1.6 + 8))
		if b.get_parent() == rail and b.visible: widest = maxf(widest, b.get_combined_minimum_size().x)
	var wanted := widest + 24.0 + 4.0
	var room := maxf(136.0, size.x * 0.25)
	left.offset_right = minf(maxf(136.0, wanted), room) + 12
	rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if wanted > room \
		else ScrollContainer.SCROLL_MODE_DISABLED
	footer.offset_left = left.offset_right + 8
	navigation.columns = 3 if scale > 1.3 else 5
	var nav_height := ((maxf(48, 18 * scale * 1.6 + 8) * 2.0 + 28) if scale > 1.3 else 80.0) + player_location.get_combined_minimum_size().y + 4
	nav.offset_left = -width - 12
	nav.offset_right = -12
	nav.offset_top = bottom_edge - nav_height
	nav.offset_bottom = bottom_edge
	panel.offset_left = -width - 12
	panel.offset_right = -12
	panel.offset_top = top_edge
	# A table covers the map, so the map's navigation steps aside and the
	# context panel runs to the footer.
	var tabled := table_kind != ""
	nav.visible = not tabled
	# Map overlays mean nothing over a table: the toggles shown are put
	# away while it covers the map and come back as they were.
	if tabled and footer_hidden.is_empty():
		for child in footer.get_child(0).get_children():
			if child is Button and child.visible:
				footer_hidden.append(child)
				child.hide()
	elif not tabled and not footer_hidden.is_empty():
		for child in footer_hidden:
			if is_instance_valid(child): child.show()
		footer_hidden.clear()
	panel.offset_bottom = bottom_edge if tabled else bottom_edge - nav_height - 8
	table_panel.offset_left = left.offset_right + 8
	table_panel.offset_top = top_edge
	table_panel.offset_bottom = bottom_edge
	table_panel.offset_right = (panel.offset_left - 8) if panel.visible else -12.0
	table.title_label.add_theme_font_size_override("font_size", roundi(23 * scale))
	table.empty_why.add_theme_font_size_override("font_size", roundi(23 * scale))
	table.tree.custom_minimum_size.y = 6 * (18 * scale * 1.6 + 8)
	if tabled and table_scale != scale:
		table_scale = scale
		table.refit()
	title.add_theme_font_size_override("font_size", roundi(23 * scale))

## The header's Select button.
func select_button() -> Button:
	return family_buttons[0] if not family_buttons.is_empty() else null

## The first section on the rail the player may open, for the controller.
func first_section() -> Button:
	for b in family_buttons:
		if b.visible and b.get_parent() == rail: return b
	return family_buttons[0]

func focus_map() -> void:
	map_button.grab_focus()
	nudges.show()
	view.cursor = {"x": roundi(view.centre.x), "y": view.level, "z": roundi(view.centre.y)}
	view.show_cursor()

func nudge(dx: int, dz: int) -> void:
	if view.cursor.is_empty(): view.cursor = {"x": roundi(view.centre.x), "y": view.level, "z": roundi(view.centre.y)}
	view.cursor.x += dx; view.cursor.z += dz; view.cursor.y = view.level
	view.centre = Vector2(view.cursor.x, view.cursor.z)
	view._move_camera(); view.need_view = true; view.show_cursor()

func map_focused() -> bool:
	return view.get_viewport().gui_get_focus_owner() == map_button

## The server says which sections this player sees (DorfCraft's
## overseer/sections.lua): hidden ones leave the rail, locked ones stay
## greyed with how to unlock them. A server that sends no list shows all.
var section_states := {}

func apply_sections(list) -> void:
	section_states.clear()
	if list is Array:
		for sec in list:
			if sec is Dictionary:
				section_states[str(sec.get("label", ""))] = sec
	var group_shown := {}
	for b in family_buttons:
		var sec: Dictionary = section_states.get(str(b.get_meta("family")), {})
		var state := str(sec.get("state", "shown"))
		b.visible = state != "hidden"
		b.modulate = Color(1, 1, 1, 0.45) if state == "locked" else Color.WHITE
		b.tooltip_text = str(sec.get("how", "")) if state == "locked" else str(b.get_meta("family"))
		if b.visible:
			for group in RAIL_GROUPS:
				if str(b.get_meta("family")) in group[2]: group_shown[group[0]] = true
	# A heading with nothing under it goes too.
	for child in rail.get_children():
		if child.has_meta("rail_group"): child.visible = group_shown.has(child.get_meta("rail_group"))
	reflow.call_deferred()
	if str(section_states.get(family, {}).get("state", "shown")) != "shown":
		family = "Select"

func choose_family(value: String) -> void:
	var sec: Dictionary = section_states.get(value, {})
	if str(sec.get("state", "shown")) != "shown":
		view.inspector.text = str(sec.get("how", "Not unlocked yet."))
		return
	if view.pending.size() > 0:
		view.inspector.text = "Waiting for the server. Retry uses the same request."
		return
	if view.first_corner != null and value != family:
		view.inspector.text = "Submit or discard this draft before choosing another tool family."
		return
	family = value
	houses_mode = ""
	view.tool = "inspect"
	refresh_tools()
	if family == "Plans": view._send({"t": "plans"})
	if family in ["People", "Supplies"]: view._send({"t": "overview"})
	if family == "Houses": houses.request()
	refresh()

func tool_family(t: Dictionary) -> String:
	# The server's access tools come as family "House"; they sit on the
	# Houses page above its controls.
	if t.has("family"): return "Houses" if str(t.family) == "House" else str(t.family)
	var id := str(t.id)
	if id in ["dig", "detail"]: return "Terrain"
	if id in ["chop", "harvest"]: return "Gather"
	if id.begins_with("room:"): return "Zones"
	if id in ["wall", "floor", "stairs", "door", "furniture"]: return "Build"
	return "Select"

func refresh_tools() -> void:
	view._clear_children(actions)
	var groups := {}
	for t in view.tools:
		if str(t.id) == "cancel" or tool_family(t) != family: continue
		var group := str(t.get("group", ""))
		if not group.is_empty():
			if groups.has(group): continue
			groups[group] = true
			var grouped := button(actions, group, choose_group.bind(group))
			grouped.set_meta("group", group)
			set_icon(grouped, t.get("group_icon"), false, t.get("group_rune"))
			grouped.toggle_mode = true
			continue
		var b := button(actions, str(t.get("title", t.id)), view.choose_tool.bind(str(t.id)))
		b.tooltip_text = str(t.get("reason", t.get("help", "")))
		b.set_meta("tool", str(t.id))
		b.toggle_mode = true
		set_icon(b, t.get("icon"), t.get("disabled", false), t.get("rune"))
		# Keep unavailable controls focusable so their reason can be read,
		# greyed rather than labelled.
		if t.get("disabled", false): grey(b)
	view._update_materials(view.material_catalog)

func choose_group(group: String) -> void:
	for t in view.tools:
		if tool_family(t) == family and str(t.get("group", "")) == group and not t.get("disabled", false):
			view.choose_tool(str(t.id))
			return
	view.inspector.text = "This zone type is unavailable."

## Takes a "houses" message: the page, and the table drawn from it.
func update_houses(msg: Dictionary) -> void:
	houses.update(msg)
	refresh()

func update_overview(value: Dictionary) -> void:
	overview = value
	refresh_overview()
	refresh()

## Quiet text, no hover lift: how an unavailable control looks.
func grey(b: Button) -> void:
	for state in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
		b.add_theme_color_override(state, QUIET)

## Which table covers the map now: People or Supplies when the server sent
## its table (an older server's lists stay in the side panel), or the
## workshop picker while no workshop is chosen or Change workshop is open.
func current_table() -> String:
	if family == "Plans": return "plans" if not plans_table.is_empty() else ""
	if family == "Houses":
		return "houses" if houses_mode == "" and houses.page.get("table") is Dictionary else ""
	if family in ["People", "Supplies"]:
		var tables: Variant = overview.get("tables")
		if tables is Dictionary and tables.get(family.to_lower()) is Dictionary: return family.to_lower()
		return ""
	if family == "Build" and view.tool == "workshop" and view.pending.is_empty() \
			and (picking_workshop or view.build_material.selected < 0):
		return "workshops"
	return ""

## The workshop picker as a table, from the server's station entries: their
## titles, whether the equipment is in stock, and what each still needs.
func workshop_table() -> Dictionary:
	var rows: Array = []
	for i in view.build_materials.size():
		var e: Dictionary = view.build_materials[i]
		var missing := bool(e.get("missing", false))
		var lines: Array = []
		if e.get("needs") is Array:
			for n in e.needs:
				if n is Dictionary:
					lines.append("%d %s: %s" % [int(n.get("count", 1)), str(n.get("title", "Unnamed")), "in stock" if n.get("ready", false) else "needed"])
		elif e.get("requirements") is String:
			lines.append(str(e.requirements))
		var whole := str(e.get("title", "Unnamed")).split("\n")[0]
		rows.append({"id": "w%d" % i, "index": i,
			"cells": {"workshop": str(e.get("trade", whole)), "station": str(e.get("station", "")),
				"equipment": "Needed" if missing else "In stock"},
			"keys": {"equipment": 1 if missing else 0},
			"state": "locked" if missing else "shown",
			"reason": str(e.get("reason", "Needs equipment in fortress stock.")), "detail": lines})
	return {"title": "Choose a workshop",
		"columns": [{"id": "workshop", "label": "Workshop", "kind": "text"},
			{"id": "station", "label": "Station", "kind": "text"},
			{"id": "equipment", "label": "Equipment", "kind": "text"}],
		"sort": {"column": "equipment", "order": "asc"}, "rows": rows,
		"empty": {"why": "No workshops are offered here.", "what": "Choose another Build tool."},
		"note": "Workers set a workshop up from fortress stock. Greyed workshops need equipment first."}

func refresh_table() -> void:
	var kind := current_table()
	if kind != table_kind:
		table_kind = kind
		table.clear_choice()
	table_panel.visible = kind != ""
	if kind == "workshops": table.set_table(workshop_table())
	elif kind == "plans":
		table.set_table(plans_table)
		# A plan chosen elsewhere (the Progress verb) opens chosen.
		if not selected_id.is_empty() and table.selected_id != selected_id: table.choose_id(selected_id)
	elif kind == "houses": table.set_table(houses.page.table)
	elif kind != "": table.set_table(overview.tables[kind])
	table_refresh.visible = kind in ["people", "supplies", "plans", "houses"]
	houses_manage.visible = kind == "houses"
	houses_mark.visible = kind == "houses" and view.tools.any(func(t: Variant) -> bool:
		return t is Dictionary and str(t.get("family", "")) == "House")
	var row: Dictionary = table.selected_row() if kind != "" else {}
	detail.visible = not row.is_empty()
	if not row.is_empty(): fill_detail(row)
	# People and Supplies show the context panel only for a chosen row.
	panel.visible = kind == "" or not row.is_empty()
	# One task per panel: while a table covers the map, the map's tools
	# (Build wall, Place door and the rest) are not beneath its detail.
	if kind != "": actions.visible = false
	if kind == "workshops":
		for control in [material_label, view.build_material, requirements, change_workshop, draft_label, submit, discard, return_draft]:
			control.visible = false
	# The map's "select a cell" hint means nothing over a table or the
	# Houses pages; a server's answer (Act, Drop) still shows.
	if kind in ["workshops", "houses"] or family == "Houses" \
			or (kind == "plans" and view.inspector.text == SELECT_HINT):
		view.inspector.visible = false
		other_tools.visible = false
	reflow()

func fill_detail(row: Dictionary) -> void:
	var cols: Array = table.columns()
	var lines: Array[String] = []
	for i in range(1, cols.size()):
		var v: Variant = row.cells.get(str(cols[i].id))
		if v != null and not str(v).is_empty(): lines.append("%s: %s" % [str(cols[i].label), table._cell_text(v)])
	if row.get("detail") is Array:
		for d in row.detail: lines.append(str(d))
	if not cols.is_empty(): title.text = str(row.cells.get(str(cols[0].id), ""))
	detail_body.text = "\n".join(lines)
	var locked: bool = table.row_locked(row)
	detail_reason.text = str(row.get("reason", "")) if locked else ""
	detail_reason.visible = locked
	var primary_action := fill_actions(row)
	if table_kind == "workshops":
		detail_primary.text = "Use this workshop"
		detail_primary.visible = not locked
	else:
		detail_primary.text = "Show on map"
		detail_primary.visible = row.get("pos") is Dictionary and view._pos(row.pos)
	# One accent button: the server's primary action, else this one.
	if primary_action: detail_primary.remove_theme_stylebox_override("normal")
	else: detail_primary.add_theme_stylebox_override("normal", accent_style)

## The chosen row's own actions, as the server lists them (Plans: Act or
## Confirm, Drop or Cancel). Rebuilt only when they change, so a refresh
## keeps focus. Returns whether one is the primary action.
func fill_actions(row: Dictionary) -> bool:
	var list: Array = row.get("actions") if table_kind == "plans" and row.get("actions") is Array else []
	var key := [row.get("id"), list, view.pending.is_empty()]
	var primary := false
	for a in list:
		if a is Dictionary and a.get("primary", false): primary = true
	if key == detail_actions_key: return primary
	detail_actions_key = key
	view._clear_children(detail_actions)
	for a in list:
		if not a is Dictionary: continue
		var b := button(detail_actions, str(a.get("label", "")), plan_action.bind(str(a.get("id", "")), str(row.get("id", ""))))
		b.tooltip_text = str(a.get("help", ""))
		b.set_meta("action", str(a.get("id", "")))
		b.disabled = not view.pending.is_empty() and view.pending.get("id") != str(row.get("id", ""))
		if a.get("primary", false): b.add_theme_stylebox_override("normal", accent_style)
	detail_actions.visible = not list.is_empty()
	return primary

## A Plans row's action, through the same requests as the older list.
func plan_action(action: String, id: String) -> void:
	selected_id = id
	if action == "act": act_plan()
	elif action == "cancel": cancel_plan()

func show_detail(row: Dictionary) -> void:
	if table_kind == "plans":
		selected_id = str(row.get("id", ""))
		if row.get("page", false) and row.get("new", false):
			view.mark_page_seen(selected_id.trim_prefix("page:"))
	refresh()

## Enter on a row: the detail's action, if the row has one.
func activate_row(row: Dictionary) -> void:
	if row.is_empty() or table.row_locked(row): return
	if table_kind == "workshops": use_workshop(row)
	elif row.get("pos") is Dictionary: show_on_map(row.pos)

func detail_action() -> void:
	activate_row(table.selected_row())

func use_workshop(row: Dictionary) -> void:
	var i := int(row.get("index", -1))
	if table.row_locked(row) or i < 0 or i >= view.build_material.item_count: return
	view.build_material.select(i)
	picking_workshop = false
	view.refresh_draft()

## Back to the map, centred on a row's place, with the cursor on it.
func show_on_map(pos: Dictionary) -> void:
	if not view._pos(pos): return
	choose_family("Select")
	if family != "Select": return
	view.level = int(pos.y)
	view.centre = Vector2(pos.x, pos.z)
	view.cursor = {"x": int(pos.x), "y": int(pos.y), "z": int(pos.z)}
	view._move_camera(); view._request_view(); view.show_cursor()
	map_button.grab_focus()

## Back with a row chosen clears the choice first.
func close_choice() -> bool:
	if family == "Houses" and houses_mode != "":
		houses_mode = ""
		refresh()
		return true
	if table_kind == "" or table.selected_id.is_empty(): return false
	table.clear_choice()
	if table_kind == "plans": selected_id = ""
	refresh()
	return true

func refresh_overview() -> void:
	var lines: Array[String] = []
	var key := "people" if family == "People" else "supplies"
	lines.append(str(overview.get(key + "_note", "Refresh to request the fortress report.")))
	var entries: Variant = overview.get(key)
	if entries is Array:
		for entry in entries.slice(0, 256):
			if not entry is Dictionary: continue
			if key == "people":
				lines.append("%s\n%s | %s%s" % [str(entry.get("name", "Worker")), str(entry.get("assignment", "")),
					str(entry.get("activity", "Unknown")) + "\nObserved: " + str(entry.get("observed", "Not observed")), "\n" + str(entry.reason) if entry.get("reason") is String and not entry.reason.is_empty() else ""])
			else:
				lines.append("%s: %s" % [str(entry.get("title", entry.get("name", "Item"))), str(entry.get("count", "?"))])
	overview_text.text = "\n\n".join(lines)

func refresh_zone_property() -> void:
	var definition: Dictionary = view.tool_definition()
	var group := str(definition.get("group", ""))
	zone_tools.clear()
	zone_options.clear()
	# Any grouped tool picks its member here: Zones' crop, room and storage
	# types, and Build's Shape (DorfCraft's building part).
	zone_property.visible = not group.is_empty() and family not in ["Plans", "People", "Supplies", "Houses"]
	zone_options.visible = zone_property.visible
	zone_options.disabled = view.first_corner != null or not view.pending.is_empty()
	if not zone_options.visible: return
	zone_property.text = str(definition.get("group_property", "Type"))
	for t in view.tools:
		if tool_family(t) != family or str(t.get("group", "")) != group: continue
		zone_tools.append(t)
		zone_options.add_item(str(t.get("option", t.get("title", t.id))))
		var index := zone_tools.size() - 1
		zone_options.set_item_tooltip(index, str(t.get("reason", t.get("help", ""))))
		if str(t.id) == view.tool: zone_options.select(index)

## A view opened from a task tool (DorfCraft's overseer/task_tools.lua):
## the server has already left out other sections and tools; this opens
## on the task's section once, and offers only the task's overlays, the
## first switched on (two fields drawn at once wash the map out).
var applied_scope = null

func apply_scope(scope: Dictionary) -> void:
	if scope.is_empty() or scope == applied_scope: return
	applied_scope = scope
	var wanted: Array = scope.get("overlays") if scope.get("overlays") is Array else []
	var first: String = str(wanted[0]) if wanted.size() > 0 else ""
	for kind in view.shown_overlays: view.shown_overlays[kind] = kind == first
	for entry in OVERLAYS: overlay_offered[entry[0]] = entry[0] in wanted
	refresh_view_menu()
	var section := str(scope.get("section", ""))
	if not section.is_empty() and str(section_states.get(section, {}).get("state", "shown")) == "shown":
		family = section
		view.tool = "inspect"
	view._draw_overlays()

## Takes the tools and limits the server granted, from its hello or a pong.
func set_marks_shown(shown: bool) -> void:
	marks_shown = shown
	refresh_view_menu()

## Rebuilds the View menu's items from what is offered and what is on, and
## names what is on in the button ("View: Heat", "View (2)").
func refresh_view_menu() -> void:
	if view_menu == null: return
	var popup := view_menu.get_popup()
	popup.clear()
	var on: Array[String] = []
	for i in OVERLAYS.size():
		var entry: Array = OVERLAYS[i]
		if not overlay_offered.get(entry[0], false): continue
		popup.add_check_item(entry[1], i)
		var index := popup.get_item_index(i)
		popup.set_item_checked(index, bool(view.shown_overlays.get(entry[0], false)))
		popup.set_item_tooltip(index, entry[2])
		if popup.is_item_checked(index): on.append(entry[1])
	if marks_shown != null:
		popup.add_separator()
		popup.add_check_item("Plan marks in the world", MARKS_ITEM)
		var index := popup.get_item_index(MARKS_ITEM)
		popup.set_item_checked(index, marks_shown == true)
		popup.set_item_tooltip(index, "Show planned work in the world: shaded outlines with the tool's rune")
	view_menu.text = "View" if on.is_empty() else ("View: " + on[0] if on.size() == 1 else "View (%d)" % on.size())
	# While a table covers the map the footer's controls are put away
	# (reflow); they come back as they were.
	if table_kind == "": view_menu.visible = popup.item_count > 0

## One View menu item chosen: an overlay switches, or the world marks do.
func choose_view_item(id: int) -> void:
	if id == MARKS_ITEM:
		marks_shown = not (marks_shown == true)
		view.set_world_marks(marks_shown)
	elif id >= 0 and id < OVERLAYS.size():
		view.toggle_overlay(OVERLAYS[id][0])
	refresh_view_menu()

## The overlays the View menu offers, in its order, for tests and captures.
func offered_overlays() -> Array:
	var out: Array = []
	for entry in OVERLAYS:
		if overlay_offered.get(entry[0], false): out.append(entry[0])
	return out

func update_capabilities(value: Dictionary) -> void:
	if value == capabilities: return
	capabilities = value
	var section_runes: Dictionary = value.get("section_runes", {})
	for b in family_buttons:
		b.icon = null
		var section := str(b.get_meta("family"))
		set_icon(b, null, false, section_runes.get(section, section_runes.get("House") if section == "Houses" else null))
	apply_sections(value.get("sections"))
	var scope: Dictionary = value.get("scope") if value.get("scope") is Dictionary else {}
	apply_scope(scope)
	header.text = "%s | %s | Live\n%s" % [str(value.get("fortress", "Fortress")), str(scope.get("title", "Overseer")), str(value.get("summary", "Server planning permissions"))]
	if value.get("tools") is Array: view.tools = value.tools
	refresh_tools()
	refresh()

## Labels the strip's buttons 1 to 6, matching the number keys. More shows
## the rest in place; whether it should open a list or the tool family is
## still open in the DorfCraft brief.
func refresh_verbs() -> void:
	var sel: Dictionary = view.selection
	var shown: bool = not sel.is_empty() and int(sel.a.y) == view.level and view.tool == "inspect" \
		and view.first_corner == null and view.pending.is_empty() and family not in ["Plans", "People", "Supplies", "Houses"]
	verb_strip.visible = shown
	if not shown:
		verbs_expanded = false
		verb_key = null
		return
	var entries: Array = view.strip_entries(view.verbs)
	# Layers refresh the panel each second; rebuilding would drop focus.
	var key := [sel, view.verbs_answered, view.nouns, entries, verbs_expanded]
	if key == verb_key:
		place_verbs.call_deferred()
		return
	verb_key = key.duplicate(true)
	view._clear_children(verb_row)
	var names: Array[String] = []
	for noun in view.nouns:
		var count := int(noun.get("count", 1))
		names.append({"tree": "Tree", "floor": "Floor", "plan": "Plan"}.get(noun.kind, str(noun.kind)) + (" (%d cells)" % count if count > 1 else ""))
	if not view.verbs_answered: verb_heading.text = "Asking the server what this is"
	elif names.is_empty(): verb_heading.text = "Nothing known here to act on"
	elif entries.is_empty(): verb_heading.text = "%s: no shared actions" % ", ".join(names)
	else: verb_heading.text = ", ".join(names)
	var limit := entries.size() if verbs_expanded else mini(entries.size(), STRIP_VERBS)
	for n in limit:
		var entry: Dictionary = entries[n]
		var text := ("%d  " % (n + 1) if n < STRIP_VERBS else "") + str(entry.label)
		var b := button(verb_row, text, view.choose_verb.bind(int(entry.verb)))
		if entry.disabled: grey(b)
		b.autowrap_mode = TextServer.AUTOWRAP_OFF
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.tooltip_text = str(entry.reason)
		b.set_meta("verb", int(entry.verb))
		set_icon(b, entry.icon, entry.disabled)
	if entries.size() > limit:
		var more := button(verb_row, "More", func() -> void:
			verbs_expanded = true
			refresh())
		more.autowrap_mode = TextServer.AUTOWRAP_OFF
		more.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	place_verbs.call_deferred()

func place_verbs() -> void:
	if not is_instance_valid(verb_strip) or not verb_strip.visible: return
	verb_strip.reset_size()
	var size: Vector2 = view.get_viewport().get_visible_rect().size
	var low := Vector2(left.offset_right + 8, top.position.y + top.size.y + 8)
	var high := Vector2(size.x + panel.offset_left - 8, size.y + footer.offset_top - 8) - verb_strip.size
	var at: Vector2 = view.selection_point() + Vector2(16, -verb_strip.size.y * 0.5)
	verb_strip.position = Vector2(clampf(at.x, low.x, maxf(low.x, high.x)), clampf(at.y, low.y, maxf(low.y, high.y)))

func first_verb() -> Button:
	for child in verb_row.get_children():
		if child is Button and not child.is_queued_for_deletion(): return child
	return null

## Presses the nth numbered verb button, as the number keys do.
func press_verb(n: int) -> void:
	var buttons: Array = []
	for child in verb_row.get_children():
		if child is Button and child.has_meta("verb") and not child.is_queued_for_deletion(): buttons.append(child)
	if n >= 0 and n < mini(buttons.size(), STRIP_VERBS): view.choose_verb(int(buttons[n].get_meta("verb")))

func refresh() -> void:
	player_location.text = view.player_location_text()
	refresh_verbs()
	var is_plans := family == "Plans"
	var is_overview := family in ["People", "Supplies"]
	var legacy := is_overview and current_table() == ""
	overview_text.visible = legacy
	overview_refresh.visible = legacy
	view.inspector.visible = not is_overview
	refresh_overview()
	refresh_zone_property()
	for b in family_buttons:
		b.toggle_mode = true
		b.set_pressed_no_signal(b.get_meta("family") == family)
	for child in actions.get_children():
		if child is Button:
			child.set_pressed_no_signal(child.get_meta("tool", "") == view.tool or (child.has_meta("group") and child.get_meta("group") == view.tool_definition().get("group")))
	title.text = "Plans" if is_plans else family
	houses.root.visible = family == "Houses" and (houses_mode == "manage" or not houses.page.get("table") is Dictionary)
	houses_back.visible = family == "Houses" and houses_mode != ""
	actions.visible = not is_plans
	# With the server's table, Plans covers the map; the older list stays
	# for an older server.
	var plan_list: bool = is_plans and plans_table.is_empty()
	for control in [plans, plan_detail, locate, cancel]: control.visible = plan_list
	act.visible = plan_list and _selected().get("can_act", false)
	view.room_name.visible = view.tool.begins_with("room:") and not is_plans
	var has_draft: bool = view.first_corner != null
	actions.visible = not is_plans and not is_overview and not has_draft \
		and not (family == "Houses" and houses_mode == "manage")
	draft_label.visible = has_draft
	draft_label.text = view.draft_summary() if has_draft else ""
	submit.visible = has_draft and view.last_corner != null
	submit.disabled = not view.can_submit()
	submit.text = "Retry submission" if not view.pending.is_empty() else "Submit plan"
	discard.visible = has_draft and view.pending.is_empty()
	return_draft.visible = has_draft and int(view.first_corner.y) != view.level
	view.build_material.disabled = not view.pending.is_empty()
	view.facing_picker.disabled = not view.pending.is_empty()
	view.room_name.editable = view.pending.is_empty()
	view._update_materials(view.material_catalog)
	requirements.text = ""
	if view.build_material.selected >= 0 and view.build_material.selected < view.build_materials.size():
		var entry: Dictionary = view.build_materials[view.build_material.selected]
		# The chosen workshop: what it is, and what is still missing if any.
		if view.tool == "workshop":
			requirements.text = str(entry.get("title", "")).split("\n")[0]
			if entry.get("missing", false): requirements.text += "\n" + str(entry.get("reason", ""))
		else:
			requirements.text = str(entry.get("reason", ""))
		if not str(entry.get("requirements", "")).is_empty():
			requirements.text += "\n" + str(entry.requirements)
	# A workshop is chosen in the picker table, never from a dropdown.
	var workshop: bool = view.tool == "workshop"
	if workshop: view.build_material.visible = false
	change_workshop.visible = workshop and family == "Build" and view.pending.is_empty() and view.build_material.selected >= 0
	other_tools.visible = workshop and family == "Build" and view.pending.is_empty() and not has_draft
	if workshop and family == "Build": actions.visible = false
	requirements.visible = not requirements.text.is_empty() and not is_plans and not is_overview
	material_label.text = "Workshop type" if view.tool == "workshop" else "Material"
	material_label.visible = (view.build_material.visible or change_workshop.visible) and not is_plans
	if is_plans: view.build_material.hide()
	refresh_table()
	if is_plans and not plans.get_selected_items().is_empty(): select_plan(plans.get_selected_items()[0])

## An entry's author, with its house when the server names one the layer
## knows ("alice (House Brightvein)").
func by_house(entry: Dictionary, fallback: String) -> String:
	return str(entry.get("by", fallback)) + view._house_suffix(view.house_table(view.snapshot), entry)

## Takes the server's answer to a "plans" request.
func update_plans(value: Array, shape: Variant = null) -> void:
	var t: Dictionary = shape if shape is Dictionary and shape.get("columns") is Array else {}
	if t != plans_table:
		plans_table = t
		if family == "Plans": refresh()
	if records == value: return
	records = value
	plans.clear()
	for entry in records:
		if entry.get("state") == "Proposed":
			plans.add_item("Proposed  %s  for %s" % [entry.get("title", entry.kind), by_house(entry, "")])
			continue
		if entry.get("kind") == "page":
			var times := " x%d" % int(entry.total) if int(entry.get("total", 1)) > 1 else ""
			plans.add_item("%s  %s  %s%s" % [entry.get("title", "Note"), by_house(entry, ""), entry.state, times])
			continue
		plans.add_item("%s  %s  %s (%s/%s)" % [entry.id, entry.get("title", entry.kind), entry.state, entry.done, entry.total])
		if entry.id == selected_id: plans.select(plans.item_count - 1)
	if plans.get_selected_items().is_empty():
		selected_id = ""
		plan_detail.text = "Choose a plan." if not records.is_empty() else "No issued spatial plans."
		locate.disabled = true; cancel.disabled = true
	else: select_plan(plans.get_selected_items()[0])

func select_plan(index: int) -> void:
	if index < 0 or index >= records.size(): return
	var entry: Dictionary = records[index]
	selected_id = str(entry.id)
	var is_page: bool = entry.get("kind") == "page"
	if is_page:
		plan_detail.text = "%s from %s\n%s" % [entry.get("title", "Note"), by_house(entry, ""), str(entry.get("reason", ""))]
		if entry.get("state") == "New":
			view.mark_page_seen(str(entry.id).trim_prefix("page:"))
	else:
		plan_detail.text = "%s | %s\nIssued by %s\n%s" % [entry.get("title", entry.kind), entry.state, by_house(entry, "Fortress"), str(entry.get("reason", ""))]
	locate.disabled = not entry.get("pos") is Dictionary
	cancel.disabled = not entry.get("can_cancel", false)
	act.visible = family == "Plans" and plans_table.is_empty() and entry.get("can_act", false)
	act.text = "Confirm" if entry.get("confirm", false) else "Act"
	act.tooltip_text = "Let workers take up this proposed plan." if entry.get("confirm", false) \
		else "Do what the office would do, where it can be done from afar."
	act.disabled = not view.pending.is_empty() and view.pending.get("t") != "act"
	if not view.pending.is_empty(): cancel.disabled = view.pending.get("t") != "cancel" or view.pending.get("id") != selected_id
	cancel.text = "Retry cancellation" if not view.pending.is_empty() else "Drop" if is_page else "Cancel pending work"
	cancel.tooltip_text = "Claimed work cannot currently be cancelled." if not entry.get("can_cancel", false) else "Completed changes remain in the world."

func _selected() -> Dictionary:
	for entry in records:
		if entry.id == selected_id: return entry
	return {}

func act_plan() -> void:
	if selected_id.is_empty(): return
	if not view.pending.is_empty():
		if view.pending.get("t") == "act": view._send(view.pending.duplicate())
		return
	view.request_id += 1
	view.pending = {"t": "act", "req": "camera:%d" % view.request_id, "id": selected_id}
	view._send(view.pending.duplicate())
	view.inspector.text = "Asking the office to act."

## Shows the newest unseen danger page, and the unseen count on Plans.
func refresh_pages() -> void:
	var newest: Dictionary = {}
	var unseen := 0
	for id in view.pages:
		var page: Dictionary = view.pages[id]
		if page.get("state") != "new": continue
		unseen += 1
		if page.get("level") == "danger" and (newest.is_empty() or str(id) > str(newest.id)): newest = page
	page_banner.visible = not newest.is_empty()
	if not newest.is_empty():
		page_banner.text = "%s: %s" % [str(newest.get("from", "")), str(newest.get("text", ""))]
		page_banner.set_meta("page", newest)
	plans_button.text = "Plans (%d)" % unseen if unseen > 0 else "Plans"

func open_banner() -> void:
	var page: Dictionary = page_banner.get_meta("page", {})
	if page.is_empty(): return
	if page.get("pos") is Dictionary and view._pos(page.pos):
		view.centre = Vector2(page.pos.x, page.pos.z)
		view.level = int(page.pos.y)
		view._move_camera(); view._request_view()
	view.inspector.text = "%s: %s" % [str(page.get("from", "")), str(page.get("text", ""))]
	view.mark_page_seen(str(page.id))

func locate_plan() -> void:
	for entry in records:
		if entry.id == selected_id:
			if not entry.get("pos") is Dictionary: return
			view.centre = Vector2(entry.pos.x, entry.pos.z)
			view.level = int(entry.pos.y)
			view._move_camera(); view._request_view()

func cancel_plan() -> void:
	if selected_id.is_empty(): return
	if not view.pending.is_empty():
		if view.pending.get("t") == "cancel": view._send(view.pending.duplicate())
		return
	view.request_id += 1
	view.pending = {"t": "cancel", "req": "camera:%d" % view.request_id, "id": selected_id}
	view._send(view.pending.duplicate())
	cancel.text = "Retry cancellation"
	view.inspector.text = "Requesting cancellation. Completed changes remain."
