# SPDX-License-Identifier: LGPL-2.1-or-later
# Planning controls, independent of the isolated terrain renderer.
extends RefCounted

var view: Node
var header: Label
var title: Label
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
var nudges: VBoxContainer

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
	for pair in [["Back", view.go_back], ["Leave", view.leave]]:
		var compact := button(row, pair[0], pair[1])
		compact.autowrap_mode = TextServer.AUTOWRAP_OFF
		compact.size_flags_horizontal = Control.SIZE_SHRINK_END
	left = box(view.root_control)
	left.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	left.offset_left = 12; left.offset_right = 148
	var rail_scroll := ScrollContainer.new()
	rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(rail_scroll)
	rail = VBoxContainer.new()
	rail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rail_scroll.add_child(rail)
	for name in ["Select", "Terrain", "Gather", "Build", "Zones", "Plans"]:
		var b := button(rail, name, choose_family.bind(name))
		b.custom_minimum_size.x = 112
		b.tooltip_text = "Inspect places and objects" if name == "Select" else name
	map_button = button(rail, "Map focus", focus_map)
	map_button.tooltip_text = "Arrows: target cell. Enter: select. Tab: controls."
	nudges = VBoxContainer.new()
	rail.add_child(nudges)
	nudges.hide()
	for pair in [["North", 0, 1], ["South", 0, -1], ["West", -1, 0], ["East", 1, 0]]:
		button(nudges, pair[0], nudge.bind(pair[1], pair[2]))
	button(nudges, "Select cell", func() -> void: view.select_cell(view.cursor))
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
	view.palette = OptionButton.new() # Retained for older test harnesses.
	view.palette.hide()
	context.add_child(view.palette)
	view.build_material = OptionButton.new()
	view.build_material.custom_minimum_size.y = 44
	view.build_material.fit_to_longest_item = false
	view.build_material.item_selected.connect(func(_i: int) -> void: view.refresh_draft())
	context.add_child(view.build_material)
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
	view.inspector = label(context, "Select a cell to inspect it. The world remains live.")
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
	nav = box(view.root_control)
	nav.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	nav.offset_left = -316; nav.offset_right = -12
	nav.offset_top = -148; nav.offset_bottom = -66
	navigation = GridContainer.new()
	navigation.columns = 5
	nav.add_child(navigation)
	button(navigation, "Down", view.change_level.bind(-1)).custom_minimum_size.x = 64
	button(navigation, "Up", view.change_level.bind(1))
	button(navigation, "Body", view.recentre).custom_minimum_size.x = 64
	button(navigation, "-", view.zoom.bind(-1)).tooltip_text = "Zoom out"
	button(navigation, "+", view.zoom.bind(1)).tooltip_text = "Zoom in"
	footer = box(view.root_control)
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 12; footer.offset_right = -12
	footer.offset_top = -58; footer.offset_bottom = -12
	var footer_row := HBoxContainer.new()
	footer.add_child(footer_row)
	view.status = label(footer_row, "Opening overseer view...")
	var legend := button(footer_row, "Legend", func() -> void:
		view.inspector.text = "Black: unexplored. Grey: unavailable. Muted: remembered. Blue-white haze: known space below. The world remains live."
	)
	legend.autowrap_mode = TextServer.AUTOWRAP_OFF
	legend.size_flags_horizontal = Control.SIZE_SHRINK_END
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
	var width := minf(336.0 * scale, size.x * 0.48)
	var footer_height := maxf(68.0, footer.get_combined_minimum_size().y)
	footer.offset_top = -footer_height - 12
	var top_edge := top.position.y + top.size.y + 8
	var bottom_edge := -footer_height - 20
	left.offset_top = top_edge
	left.offset_bottom = bottom_edge
	left.offset_right = minf(136.0 * scale, size.x * 0.25) + 12
	for child in rail.get_children():
		if child is Button: child.custom_minimum_size = Vector2(0, maxf(48, 18 * scale * 1.6 + 8))
	navigation.columns = 3 if scale > 1.3 else 5
	var nav_height := (maxf(48, 18 * scale * 1.6 + 8) * 2.0 + 28) if scale > 1.3 else 80.0
	nav.offset_left = -width - 12
	nav.offset_right = -12
	nav.offset_top = bottom_edge - nav_height
	nav.offset_bottom = bottom_edge
	panel.offset_left = -width - 12
	panel.offset_right = -12
	panel.offset_top = top_edge
	panel.offset_bottom = bottom_edge - nav_height - 8
	title.add_theme_font_size_override("font_size", roundi(23 * scale))

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

func choose_family(value: String) -> void:
	if view.pending.size() > 0:
		view.inspector.text = "Waiting for the server. Retry uses the same request."
		return
	if view.first_corner != null and value != family:
		view.inspector.text = "Submit or discard this draft before choosing another tool family."
		return
	family = value
	view.tool = "inspect"
	refresh_tools()
	if family == "Plans": view._send({"t": "plans"})
	refresh()

func tool_family(t: Dictionary) -> String:
	if t.has("family"): return str(t.family)
	var id := str(t.id)
	if id in ["dig", "detail"]: return "Terrain"
	if id in ["chop", "harvest"]: return "Gather"
	if id.begins_with("room:"): return "Zones"
	if id in ["wall", "floor", "stairs", "door", "furniture"]: return "Build"
	return "Select"

func refresh_tools() -> void:
	view._clear_children(actions)
	for t in view.tools:
		if str(t.id) == "cancel" or tool_family(t) != family: continue
		var b := button(actions, str(t.get("title", t.id)), view.choose_tool.bind(str(t.id)))
		b.tooltip_text = str(t.get("reason", ""))
		b.set_meta("tool", str(t.id))
		b.toggle_mode = true
		# Keep unavailable controls focusable so their reason can be read.
		if t.get("disabled", false): b.text += " (unavailable)"
	view._update_materials(view.material_catalog)

func update_capabilities(value: Dictionary) -> void:
	if value == capabilities: return
	capabilities = value
	header.text = "%s | Overseer | Live\n%s" % [str(value.get("fortress", "Fortress")), str(value.get("summary", "Server planning permissions"))]
	if value.get("tools") is Array: view.tools = value.tools
	refresh_tools()
	refresh()

func refresh() -> void:
	var is_plans := family == "Plans"
	for child in rail.get_children():
		if child is Button and child != map_button:
			child.toggle_mode = true
			child.set_pressed_no_signal(child.text == family)
	for child in actions.get_children():
		if child is Button: child.set_pressed_no_signal(child.get_meta("tool", "") == view.tool)
	title.text = "Plans" if is_plans else family
	actions.visible = not is_plans
	for control in [plans, plan_detail, locate, cancel]: control.visible = is_plans
	view.room_name.visible = view.tool.begins_with("room:") and not is_plans
	var has_draft: bool = view.first_corner != null
	actions.visible = not is_plans and not has_draft
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
	if is_plans and not plans.get_selected_items().is_empty(): select_plan(plans.get_selected_items()[0])

func update_plans(value: Array) -> void:
	if records == value: return
	records = value
	plans.clear()
	for entry in records:
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
	plan_detail.text = "%s | %s\nIssued by %s\n%s" % [entry.get("title", entry.kind), entry.state, entry.by, str(entry.get("reason", ""))]
	locate.disabled = false
	cancel.disabled = not entry.get("can_cancel", false)
	if not view.pending.is_empty(): cancel.disabled = view.pending.get("t") != "cancel" or view.pending.get("id") != selected_id
	cancel.text = "Retry cancellation" if not view.pending.is_empty() else "Cancel pending work"
	cancel.tooltip_text = "Claimed work cannot currently be cancelled." if not entry.get("can_cancel", false) else "Completed changes remain in the world."

func locate_plan() -> void:
	for entry in records:
		if entry.id == selected_id:
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
