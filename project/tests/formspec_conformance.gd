# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless structural and behavioural checks for Goanna's formspec renderer.
extends SceneTree

const Formspec := preload("res://ui/formspec.gd")
const GameUi := preload("res://ui/game_ui.gd")
const GlassStyle := preload("res://ui/glass_style.gd")

var checks := 0
var failures := 0
var fixture_source: FakeItemSource


class FakeItemSource extends Node:
	var texture: Texture2D
	var inventories := {
		"current_player|main": [
			{"name": "default:stone", "description": "Stone", "count": 12, "wear": 0},
			{"name": "default:pick_wood", "description": "Wooden Pickaxe", "count": 1,
				"wear": 16000},
		],
		"detached:test|store": [
			{"name": "default:apple", "description": "Apple", "count": 3, "wear": 0},
		],
	}

	func _init() -> void:
		var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.2, 0.7, 0.35, 1.0))
		texture = ImageTexture.create_from_image(image)

	# One texture per name, all alike, so a check can tell which name a
	# control was given.
	var named_textures := {}

	func ui_texture(texture_name: String) -> Texture2D:
		if not named_textures.has(texture_name):
			var image := texture.get_image()
			# "art_<grey>_<size>.png" stands in for a game's window art: a flat
			# grey face with a one pixel darker edge.
			if texture_name.begins_with("art_"):
				var bits := texture_name.trim_suffix(".png").split("_")
				var grey := int(bits[1]) / 255.0
				var side := int(bits[2]) if bits.size() > 2 else 32
				image = Image.create(side, side, false, Image.FORMAT_RGBA8)
				image.fill(Color(grey * 0.6, grey * 0.6, grey * 0.6))
				image.fill_rect(Rect2i(1, 1, side - 2, side - 2), Color(grey, grey, grey))
			# "line_<size>.png" stands in for dark line art: a clear square
			# with a dark cross through it, a few pixels wide.
			elif texture_name.begins_with("line_"):
				var side := int(texture_name.trim_suffix(".png").split("_")[1])
				image = Image.create(side, side, false, Image.FORMAT_RGBA8)
				image.fill_rect(Rect2i(side / 2 - 1, 2, 2, side - 4), Color8(25, 32, 34))
				image.fill_rect(Rect2i(2, side / 2 - 1, side - 4, 2), Color8(25, 32, 34))
			named_textures[texture_name] = ImageTexture.create_from_image(image)
		return named_textures[texture_name]

	func item_icon(_name: String) -> Texture2D:
		return texture

	func item_description(item_string: String) -> String:
		return "Description of " + item_string.get_slice(" ", 0)

	var holding := false

	func holding_stack() -> bool:
		return holding

	var sounds: Array = []

	func play_form_sound(sound_name: String) -> void:
		sounds.append(sound_name)

	# Stands in for a node's metadata: one key is set.
	func resolve_text(text: String) -> String:
		return "Sign text" if text == "${text}" else text

	# Stands in for the extension's model loader: one mesh is known, anything
	# else is media that has not arrived and falls back to the placeholder.
	func model_preview(mesh_name: String, _textures: PackedStringArray,
			_frame_loop: Vector2, _speed: float) -> Dictionary:
		if mesh_name != "character.b3d":
			return {}
		var box := BoxMesh.new()
		box.size = Vector3(0.6, 1.8, 0.4)
		var instance := MeshInstance3D.new()
		instance.mesh = box
		var holder := Node3D.new()
		holder.add_child(instance)
		return {"node": holder, "aabb": box.get_aabb()}

	func get_list_item(location: String, listname: String, index: int) -> Dictionary:
		var items: Array = inventories.get(location + "|" + listname, [])
		return items[index] if index >= 0 and index < items.size() else {}


# Stands in for GoannaClient: records the raw inventory action strings the
# cursor-stack code sends, which is the whole observable behaviour of a
# click, a drag or a double click.
class FakeClient extends Node:
	var actions: Array = []
	var prepend := ""
	var inventory_spec := ""

	func inventory_action(action: String) -> void:
		actions.append(action)

	func inventory_state_at(_location: String) -> Dictionary:
		return {}

	func formspec_prepend() -> String:
		return prepend

	func inventory_formspec() -> String:
		return inventory_spec


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_source = FakeItemSource.new()
	root.add_child(fixture_source)
	_test_split_and_unescape()
	_test_colours()
	_test_layout_headers()
	_test_controls_and_submission()
	_test_inventory_and_listring()
	_test_slot_input_events()
	_test_drag_to_distribute()
	_test_double_click_to_collect()
	_test_click_and_craft_paths()
	_test_partial_elements()
	_test_scroll_container()
	_test_styles()
	_test_labels()
	_test_fields()
	_test_button_geometry()
	_test_initial_focus()
	_test_sizeless_form()
	_test_button_styles()
	_test_style_sound_font_model()
	_test_table()
	_test_list_look()
	_test_hypertext()
	_test_nothing_skipped()
	_test_tooltips()
	_test_button_key()
	_test_hypertip()
	_test_prepend()
	_test_host_passes_prepend()
	_test_background_order()
	_test_glass_chrome()
	_test_glass_keeps_content()
	_test_glass_slot_frames()
	_test_glass_repeated_theme()
	_test_glass_bespoke()
	_test_glass_sends_the_same()
	_test_glass_window_art()
	_test_legacy_draw_order()
	_test_glass_legibility()
	_test_glass_setting()
	await _write_reference_shots()
	if failures == 0:
		print("formspec conformance: PASS: ", checks, " checks")
		quit(0)
	else:
		push_error("formspec conformance: FAIL: %d of %d checks failed" % [failures, checks])
		quit(1)


func _new_form(spec: String, formname := "conformance", prepend := "", style := "game") -> Control:
	var form := Formspec.new()
	form.item_source = fixture_source
	form.style = style
	root.add_child(form)
	form.show_formspec(spec, formname, Vector2(1200, 800), prepend)
	return form


func _discard(form: Control) -> void:
	root.remove_child(form)
	form.free()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("formspec conformance: " + message)


func _equal(actual: Variant, expected: Variant, message: String) -> void:
	_check(actual == expected, "%s: expected %s, got %s" % [message, expected, actual])


func _test_split_and_unescape() -> void:
	_equal(Array(Formspec.fs_split("one\\;still-one;two", ";")),
		["one\\;still-one", "two"], "escaped separator")
	_equal(Formspec.fs_unescape("one\\;still-one"), "one;still-one", "unescape")
	_equal(Formspec.fs_unescape("left\\]right"), "left]right", "escaped closing bracket")


# parseColorString: CSS names, not Godot's, in any case, with a one or two
# digit alpha after a #, and hex in four lengths. Anything else falls back.
func _test_colours() -> void:
	var none := Color(0.1, 0.2, 0.3, 0.4)
	_equal(Formspec.parse_color("green", none), Color.html("008000"), "green is CSS green")
	_equal(Formspec.parse_color("Grey", none), Color.html("808080"), "names ignore case")
	_equal(Formspec.parse_color("red#80", none), Color.html("ff000080"), "a two digit alpha")
	_equal(Formspec.parse_color("red#8", none), Color.html("ff000088"), "a one digit alpha doubles")
	_equal(Formspec.parse_color("#abc", none), Color.html("aabbcc"), "#RGB")
	_equal(Formspec.parse_color("#abcd", none), Color.html("aabbccdd"), "#RGBA")
	_equal(Formspec.parse_color("#11223344", none), Color.html("11223344"), "#RRGGBBAA")
	_equal(Formspec.parse_color("ff0000", none), none, "bare hex is not a colour")
	_equal(Formspec.parse_color("#12345", none), none, "five digits is not a colour")
	_equal(Formspec.parse_color("notacolour", none), none, "an unknown name falls back")


func _test_layout_headers() -> void:
	var form := _new_form("formspec_version[6]size[8,6]position[0.25,0.75]"
		+ "anchor[0,1]padding[0.1,0.1]real_coordinates[true]label[1,1;Header]"
		+ "image[2,1;fixture.png]")
	_equal(form.formspec_version, 6, "formspec version")
	_check(form.real_coordinates, "version 6 uses real coordinates")
	_equal(form.invsize, Vector2(8, 6), "form size header")
	_equal(form.form_position, Vector2(0.25, 0.75), "form position header")
	_equal(form.form_anchor, Vector2(0, 1), "form anchor header")
	_equal(form.form_padding, Vector2(0.1, 0.1), "form padding header")
	_check(form.root.size.x > 0 and form.root.size.y > 0, "layout produces a positive panel")
	var legacy_image_found := false
	for texture_rect in _nodes_of_type(form, "TextureRect"):
		if texture_rect.size == Vector2(16, 16):
			legacy_image_found = true
	_check(legacy_image_found, "legacy image syntax uses the texture's pixel size")
	_discard(form)


func _test_controls_and_submission() -> void:
	var spec := "formspec_version[6]size[12,10]allow_close[false]set_focus[go;true]"
	spec += "bgcolor[#263342]"
	spec += "container[0.25,0.25]label[0.25,0.25;Ordinary label]container_end[]"
	spec += "vertlabel[11,0.5;Up]"
	spec += "box[0.5,1;1,1;#224466]image[1.5,1;1,1;fixture.png]"
	spec += "background[0,0;12,10;fixture.png;false]"
	spec += "item_image[2.5,1;1,1;default:stone]"
	spec += "field[0.5,3;3,0.8;name;Name;Ada]pwdfield[4,3;3,0.8;secret;Secret]"
	spec += "textarea[0.5,4;3,1.5;notes;Notes;hello]"
	spec += "checkbox[4,4;enabled;Enabled;true]"
	spec += "dropdown[4,5;3,0.8;choice;red,green,blue;2;true]"
	spec += "textlist[7.5,3;3,2;rows;one,two,three;2;false]"
	spec += "tabheader[0.5,7;tabs;First,Second;1;false;true]"
	spec += "button[4,7;2,0.8;go;Submit]button_exit[6.5,7;2,0.8;leave;Leave]"
	spec += "image_button[9,6;1,1;fixture.png;picture;Pic]"
	spec += "image_button_exit[10,6;1,1;fixture.png;picture_exit;Exit]"
	spec += "item_image_button[9,7;1,1;default:stone;item;Item]"
	spec += "tooltip[go;Submit tooltip]tooltip[9,8;2,1;Area tooltip;#222222;#eeeeee]"
	spec += "field_close_on_enter[name;false]"
	var form := _new_form(spec)
	_check(not form.allow_close, "allow_close false is retained")
	_check(form.has_form_bgcolor, "form background colour is applied")
	_equal(form.fields.size(), 7, "named field count")
	_equal(form.collect_fields()["name"], "Ada", "line edit default")
	_equal(form.collect_fields()["secret"], "", "a password field starts empty")
	_equal(form.collect_fields()["choice"], "2", "index-event dropdown default")
	# acceptInput sends a check box, text list or tab header only with the
	# event it caused, never along with another element's.
	for quiet in ["enabled", "rows", "tabs"]:
		_check(not form.collect_fields().has(quiet), "%s is not sent with every event" % quiet)

	var submissions: Array = []
	form.fields_submitted.connect(func(fields: Dictionary, quit: bool) -> void:
		submissions.append({"fields": fields, "quit": quit}))
	var submit_button := _button_named(form, "Submit")
	_check(submit_button != null, "ordinary button is built")
	if submit_button:
		_check(submit_button.has_focus(), "set_focus targets a named button")
		_equal(form.tooltip_at(Vector2(-1, -1), submit_button, 1000).get("text"),
			"Submit tooltip", "named tooltip")
		submit_button.pressed.emit()
		_equal(submissions.back()["fields"]["go"], "Submit", "button field value")
		_check(not submissions.back()["quit"], "ordinary button keeps form open")
		var others: Array = []
		for k in submissions.back()["fields"]:
			if k in ["enabled", "rows", "tabs", "picture", "item"]:
				others.append(k)
		_equal(others, [], "a button press sends no check box, list, tab header or other button")
	var check: CheckBox = form.fields["enabled"]
	check.button_pressed = false
	_equal(submissions.back()["fields"].get("enabled"), "false", "a check box sends itself when changed")
	_check(not submissions.back()["fields"].has("go"), "and not the button pressed before it")
	var drop: OptionButton = form.fields["choice"]
	drop.select(0)
	drop.item_selected.emit(0)
	_equal(submissions.back()["fields"].get("choice"), "1", "a changed dropdown sends itself")
	var tabs: TabBar = form.fields["tabs"]
	tabs.current_tab = 1
	_equal(submissions.back()["fields"].get("tabs"), "2", "a tab header sends itself when chosen")
	_check(not submissions.back()["fields"].has("enabled"), "without the check box")
	# An image button with no label still sends its field, as an empty
	# string: Mineclonia's back arrow in its player settings is one.
	var picture: Button = form.named_controls["picture"]
	form.submit({}, false)
	var before: int = submissions.size()
	var bare := _new_form("formspec_version[6]size[6,4]"
		+ "image_button[0.5,0.5;1.1,1.1;fixture.png;__mcl_inventory;]"
		+ "checkbox[2,1;setting;Setting;true]")
	var bare_sent: Array = []
	bare.fields_submitted.connect(func(f: Dictionary, _q: bool) -> void: bare_sent.append(f))
	(bare.named_controls["__mcl_inventory"] as Button).pressed.emit()
	_equal(bare_sent.size(), 1, "an image button with an empty label submits")
	if bare_sent.size() == 1:
		_check(bare_sent[0].has("__mcl_inventory"), "its field is sent")
		_equal(bare_sent[0].get("__mcl_inventory"), "", "with an empty value")
		_check(not bare_sent[0].has("setting"), "and without the form's check box")
	_discard(bare)
	_check(picture != null and submissions.size() == before, "the harness button lookup works")
	var exit_button := _button_named(form, "Leave")
	_check(exit_button != null, "exit button is built")
	if exit_button:
		exit_button.pressed.emit()
		_check(submissions.back()["quit"], "exit button requests close")
	var name_field: LineEdit = form.fields["name"]
	name_field.text_submitted.emit(name_field.text)
	_equal(submissions.back()["fields"]["key_enter_field"], "name", "enter field name")
	_check(not submissions.back()["quit"], "field_close_on_enter false is honoured")
	_equal(form.tooltip_areas.size(), 1, "area tooltip is built")
	if form.tooltip_areas.size() == 1:
		var area: Control = form.tooltip_areas[0]["area"]
		_equal(area.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"an area tooltip never takes a click from what lies under it")
	_discard(form)


func _test_inventory_and_listring() -> void:
	var spec := "formspec_version[6]size[10,6]"
	spec += "listcolors[#111111;#222222;#333333;#444444;#eeeeee]"
	spec += "list[current_player;main;0.5,0.5;2,2;0]"
	spec += "list[detached:test;store;4,0.5;2,1;0]"
	spec += "listring[current_player;main]listring[detached:test;store]"
	var form := _new_form(spec)
	_equal(form.slots.size(), 6, "inventory slot count")
	_equal(form.slots[0].item.get("name"), "default:stone", "slot item refresh")
	_equal(form.slots[1].item.get("count"), 1, "second slot item refresh")
	_equal(form.next_in_ring("current_player", "main"),
		{"location": "detached:test", "listname": "store"}, "forward list ring")
	_equal(form.next_in_ring("detached:test", "store"),
		{"location": "current_player", "listname": "main"}, "wrapped list ring")
	_discard(form)


# Godot hands motion and release events to whichever Control took the press,
# not to the one under the pointer, so a slot has to look the pointer up by
# position for a drag to reach the slots it crosses. These events go through
# the viewport, so it is Godot's own routing being tested, not a shortcut
# around it.
func _test_slot_input_events() -> void:
	var form := _new_form("formspec_version[6]size[10,4]"
		+ "list[current_player;main;0.5,0.5;4,1;0]")
	var clicked: Array = []
	var dragged: Array = []
	var released: Array = []
	var double_clicked: Array = []
	form.slot_clicked.connect(func(_l: String, lname: String, i: int, b: int, _sh: bool) -> void:
		clicked.append([lname, i, b]))
	form.slot_dragged.connect(func(_l: String, lname: String, i: int, b: int) -> void:
		dragged.append([lname, i, b]))
	form.slot_released.connect(func(_l: String, lname: String, i: int, b: int) -> void:
		released.append([lname, i, b]))
	form.slot_double_clicked.connect(func(_l: String, lname: String, i: int) -> void:
		double_clicked.append([lname, i]))
	_check(form.slots.size() == 4 and form.slots[0].get_global_rect().size.x > 0,
		"the drag fixture lays its slots out")
	var at := func(i: int) -> Vector2: return form.slots[i].get_global_rect().get_center()

	root.push_input(_press_at(at.call(0), MOUSE_BUTTON_LEFT, false))
	_equal(clicked, [["main", 0, MOUSE_BUTTON_LEFT]], "a press reports the slot it landed on")
	root.push_input(_motion_at(at.call(1), MOUSE_BUTTON_MASK_LEFT))
	root.push_input(_motion_at(at.call(1), MOUSE_BUTTON_MASK_LEFT))
	root.push_input(_motion_at(at.call(2), MOUSE_BUTTON_MASK_LEFT))
	_equal(dragged, [["main", 1, MOUSE_BUTTON_LEFT], ["main", 2, MOUSE_BUTTON_LEFT]],
		"a drag reports each slot entered once, however far the pointer moves inside it")
	root.push_input(_release_at(at.call(2), MOUSE_BUTTON_LEFT))
	_equal(released, [["main", 2, MOUSE_BUTTON_LEFT]],
		"the release names the slot under the pointer, not the one that took the press")

	# Let go somewhere that is not a slot: the listname says so.
	released.clear()
	root.push_input(_press_at(at.call(0), MOUSE_BUTTON_LEFT, false))
	root.push_input(_release_at(form.slots[0].get_global_rect().position - Vector2(40, 40),
		MOUSE_BUTTON_LEFT))
	_equal(released, [["", -1, MOUSE_BUTTON_LEFT]], "releasing off the slots reports no slot")

	# Godot flags the second press rather than sending an event of its own.
	root.push_input(_press_at(at.call(0), MOUSE_BUTTON_LEFT, true))
	_equal(double_clicked, [["main", 0]], "a double click is reported after its press")
	root.push_input(_release_at(at.call(0), MOUSE_BUTTON_LEFT))
	_discard(form)


# Left drag shares the held stack out evenly, right drag places one per slot.
func _test_drag_to_distribute() -> void:
	# Seven stone over three empty slots: two each, one left on the cursor.
	var ui := _new_inventory_ui({"main": [
		_stack("default:stone", 7), {}, {}, {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_LEFT, false)
	_equal(ui.client.actions, [], "a left press over a slot that could take the stack moves nothing yet")
	ui._on_slot_dragged("current_player", "main", 2, MOUSE_BUTTON_LEFT)
	ui._on_slot_dragged("current_player", "main", 3, MOUSE_BUTTON_LEFT)
	ui._on_slot_released("current_player", "main", 3, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, [
		"Move 2 current_player main 0 current_player main 1",
		"Move 2 current_player main 0 current_player main 2",
		"Move 2 current_player main 0 current_player main 3"],
		"seven items dragged over three slots go two, two, two")
	_equal(ui.selected.get("amount", 0), 1, "the remainder of the split stays on the cursor")
	_discard_inventory_ui(ui)

	# Crossing a slot a second time does not earn it a second share.
	ui = _new_inventory_ui({"main": [_stack("default:stone", 6), {}, {}, {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_dragged("current_player", "main", 2, MOUSE_BUTTON_LEFT)
	ui._on_slot_dragged("current_player", "main", 1, MOUSE_BUTTON_LEFT)
	ui._on_slot_dragged("current_player", "main", 3, MOUSE_BUTTON_LEFT)
	ui._on_slot_released("current_player", "main", 3, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, [
		"Move 2 current_player main 0 current_player main 1",
		"Move 2 current_player main 0 current_player main 2",
		"Move 2 current_player main 0 current_player main 3"],
		"a slot crossed twice still gets one share")
	_check(ui.selected.is_empty(), "six items over three slots leaves nothing on the cursor")
	_discard_inventory_ui(ui)

	# A slot holding a different item is not part of the split.
	ui = _new_inventory_ui({"main": [
		_stack("default:stone", 6), {}, _stack("default:apple", 3), {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_dragged("current_player", "main", 2, MOUSE_BUTTON_LEFT)
	ui._on_slot_dragged("current_player", "main", 3, MOUSE_BUTTON_LEFT)
	ui._on_slot_released("current_player", "main", 3, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, [
		"Move 3 current_player main 0 current_player main 1",
		"Move 3 current_player main 0 current_player main 3"],
		"a slot holding another item is skipped and the rest split the stack")
	_discard_inventory_ui(ui)

	# A slot that cannot hold a whole share takes what fits, and the rest
	# stays on the cursor. Apples stack to eight in the fixture item defs.
	ui = _new_inventory_ui({"main": [
		_stack("default:apple", 8), _stack("default:apple", 6), {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_dragged("current_player", "main", 2, MOUSE_BUTTON_LEFT)
	ui._on_slot_released("current_player", "main", 2, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, [
		"Move 2 current_player main 0 current_player main 1",
		"Move 4 current_player main 0 current_player main 2"],
		"a nearly full slot takes only what its stack maximum allows")
	_equal(ui.selected.get("amount", 0), 2, "what would not fit stays on the cursor")
	_discard_inventory_ui(ui)

	# Dragging back over the slot the stack came from gives it a share too,
	# which it takes by staying put, so nothing is sent for it.
	ui = _new_inventory_ui({"main": [_stack("default:stone", 4), {}, {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_dragged("current_player", "main", 0, MOUSE_BUTTON_LEFT)
	ui._on_slot_released("current_player", "main", 0, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, ["Move 2 current_player main 0 current_player main 1"],
		"the slot the stack came from needs no action to take its share")
	_check(ui.selected.is_empty(), "its share stops being held")
	_discard_inventory_ui(ui)

	# Right drag places one per slot, and the release adds nothing.
	ui = _new_inventory_ui({"main": [_stack("default:stone", 7), {}, {}, {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_RIGHT, false)
	ui._on_slot_dragged("current_player", "main", 2, MOUSE_BUTTON_RIGHT)
	ui._on_slot_dragged("current_player", "main", 3, MOUSE_BUTTON_RIGHT)
	ui._on_slot_released("current_player", "main", 3, MOUSE_BUTTON_RIGHT)
	_equal(ui.client.actions, [
		"Move 1 current_player main 0 current_player main 1",
		"Move 1 current_player main 0 current_player main 2",
		"Move 1 current_player main 0 current_player main 3"],
		"right dragging places exactly one item in each slot crossed")
	_equal(ui.selected.get("amount", 0), 4, "the rest of the stack stays on the cursor")
	_discard_inventory_ui(ui)


# Double clicking the slot the cursor stack came from gathers every matching
# stack in the list onto the cursor.
func _test_double_click_to_collect() -> void:
	var ui := _new_inventory_ui({"main": [
		_stack("default:stone", 5), _stack("default:stone", 7),
		_stack("default:apple", 3), _stack("default:stone", 2)]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 0, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_double_clicked("current_player", "main", 0)
	_equal(ui.client.actions, [
		"Move 7 current_player main 1 current_player main 0",
		"Move 2 current_player main 3 current_player main 0"],
		"a double click gathers the matching stacks and leaves the others alone")
	_equal(ui.selected.get("amount", 0), 14, "the cursor holds everything it gathered")
	ui._on_slot_released("current_player", "main", 0, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions.size(), 2, "collecting cancels the drag its press started")
	_discard_inventory_ui(ui)

	# Never past the item's stack maximum: apples stop at eight.
	ui = _new_inventory_ui({"main": [
		_stack("default:apple", 3), _stack("default:apple", 7), _stack("default:apple", 4)]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 0, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_double_clicked("current_player", "main", 0)
	_equal(ui.client.actions, ["Move 5 current_player main 1 current_player main 0"],
		"a collect takes only up to the stack maximum and then stops")
	_equal(ui.selected.get("amount", 0), 8, "the cursor ends holding a full stack")
	_discard_inventory_ui(ui)


# The gestures the drag work is built on top of, and the craft paths it must
# not swallow.
func _test_click_and_craft_paths() -> void:
	# Click to pick up, click again to put down.
	var ui := _new_inventory_ui({"main": [_stack("default:stone", 5), {}, {}]})
	_pick_up(ui, 0)
	_equal(ui.selected.get("amount", 0), 5, "a click picks the whole stack up")
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_released("current_player", "main", 1, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, ["Move 5 current_player main 0 current_player main 1"],
		"a click on one other slot puts the whole stack down there")
	_check(ui.selected.is_empty(), "and the cursor is empty afterwards")
	_discard_inventory_ui(ui)

	# Press on the source slot again and let go there: the stack goes back.
	ui = _new_inventory_ui({"main": [_stack("default:stone", 5), {}, {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 0, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_released("current_player", "main", 0, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, [], "putting the stack back where it came from sends nothing")
	_check(ui.selected.is_empty(), "and takes it off the cursor")
	_discard_inventory_ui(ui)

	# One right click places one item, not one on the press and another on
	# the release.
	ui = _new_inventory_ui({"main": [_stack("default:stone", 5), {}, {}]})
	_pick_up(ui, 0)
	ui._on_slot_clicked("current_player", "main", 1, MOUSE_BUTTON_RIGHT, false)
	ui._on_slot_released("current_player", "main", 1, MOUSE_BUTTON_RIGHT)
	_equal(ui.client.actions, ["Move 1 current_player main 0 current_player main 1"],
		"a right click places one item once")
	_discard_inventory_ui(ui)

	# Shift click moves a whole stack to the next list in the ring.
	ui = _new_inventory_ui({"main": [_stack("default:stone", 5)], "craft": [{}]})
	ui._on_slot_clicked("current_player", "main", 0, MOUSE_BUTTON_LEFT, true)
	ui._on_slot_released("current_player", "main", 0, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions,
		["MoveSomewhere 5 current_player main 0 current_player craft"],
		"shift clicking a stack sends it to the next list in the ring")
	_discard_inventory_ui(ui)

	# A shift click on the craft preview must reach the craft path and not be
	# taken by the shift-move handler above it: it asks for a whole stack's
	# worth of repeats and arms the move that follows the craft.
	ui = _new_inventory_ui({"main": [{}], "craft": [_stack("default:stone", 1)],
		"craftpreview": [_stack("default:apple", 1)], "craftresult": [{}]})
	ui._on_slot_clicked("current_player", "craftpreview", 0, MOUSE_BUTTON_LEFT, true)
	ui._on_slot_released("current_player", "craftpreview", 0, MOUSE_BUTTON_LEFT)
	_equal(ui.client.actions, ["Craft 8 current_player"],
		"a shift click on the craft preview crafts a stack's worth")
	_equal(ui.shift_craft_location, "current_player",
		"and arms the move of the crafted stack into the inventory")
	_discard_inventory_ui(ui)

	# Without shift the preview click takes the result onto the cursor,
	# and putting it down clears the cursor rather than splitting the craft.
	ui = _new_inventory_ui({"main": [{}], "craft": [_stack("default:stone", 1)],
		"craftpreview": [_stack("default:apple", 1)],
		"craftresult": [_stack("default:apple", 4)]})
	ui._on_slot_clicked("current_player", "craftpreview", 0, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_released("current_player", "craftpreview", 0, MOUSE_BUTTON_LEFT)
	_equal(ui.selected.get("listname", ""), "craftresult",
		"clicking the preview picks the craft result up")
	ui._on_slot_clicked("current_player", "main", 0, MOUSE_BUTTON_LEFT, false)
	_equal(ui.client.actions,
		["Move 4 current_player craftresult 0 current_player main 0"],
		"a craft result is put down on the press, never held back for a split")
	_check(ui.selected.is_empty(), "and the cursor lets go of the craft result")
	_discard_inventory_ui(ui)


func _stack(item_name: String, count: int) -> Dictionary:
	return {"name": item_name, "description": item_name, "count": count, "wear": 0}


# game_ui.gd owns the cursor stack. It is a CanvasLayer with a heavy _ready,
# so the harness builds one outside the tree and fills in only what the slot
# handlers read.
func _new_inventory_ui(lists: Dictionary) -> Node:
	var ui: Node = GameUi.new()
	ui.client = FakeClient.new()
	ui.hud = Control.new()
	ui.form = _new_form("formspec_version[6]size[10,6]"
		+ "list[current_player;main;0.5,0.5;4,1;0]"
		+ "list[current_player;craft;0.5,3;2,1;0]"
		+ "listring[current_player;main]listring[current_player;craft]")
	ui.inv_cache = {"lists": lists}
	ui.item_defs = {
		"default:stone": {"stack_max": 99},
		"default:apple": {"stack_max": 8},
	}
	return ui


func _discard_inventory_ui(ui: Node) -> void:
	_discard(ui.form)
	ui.client.free()
	ui.hud.free()
	ui.free()


# A whole left click on a slot, which is how a stack gets onto the cursor.
func _pick_up(ui: Node, index: int) -> void:
	ui._on_slot_clicked("current_player", "main", index, MOUSE_BUTTON_LEFT, false)
	ui._on_slot_released("current_player", "main", index, MOUSE_BUTTON_LEFT)


func _press_at(pos: Vector2, button: int, double: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.button_mask = _mask_of(button)
	event.pressed = true
	event.double_click = double
	event.position = pos
	event.global_position = pos
	return event


func _release_at(pos: Vector2, button: int) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = false
	event.position = pos
	event.global_position = pos
	return event


func _motion_at(pos: Vector2, mask: int) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.button_mask = mask
	event.position = pos
	event.global_position = pos
	return event


func _mask_of(button: int) -> int:
	if button == MOUSE_BUTTON_RIGHT:
		return MOUSE_BUTTON_MASK_RIGHT
	if button == MOUSE_BUTTON_MIDDLE:
		return MOUSE_BUTTON_MASK_MIDDLE
	return MOUSE_BUTTON_MASK_LEFT


func _test_partial_elements() -> void:
	var spec := "formspec_version[6]size[10,7]"
	spec += "animated_image[0,0;1,1;anim;fixture.png;4;100;1]"
	spec += "background9[1,0;2,2;fixture.png;false;4]"
	spec += "hypertext[0,2;3,2;rich;<b>Plain fallback</b>]"
	spec += "button_url[3.5,2;2,0.8;url;Open;https://example.invalid]"
	spec += "table[6,0;3,2;rows;alpha,beta;1]"
	spec += "model[6,3;3,3;preview;character.b3d;skin.png;-10,200;false;true;0,0]"
	spec += "model[6,0;1,1;absent;unsent.b3d;skin.png]"
	spec += "scroll_container[0,4;3,2;scroll;vertical;0.1]"
	spec += "label[0,0;Inside scroll]scroll_container_end[]"
	var form := _new_form(spec)
	_check(form.skipped.is_empty(), "partial elements build without being silently skipped")
	var atlas_found := false
	var nine_patch_found := false
	for texture_rect in _nodes_of_type(form, "TextureRect"):
		if texture_rect.texture is AtlasTexture:
			atlas_found = true
	for _nine_patch in _nodes_of_type(form, "NinePatchRect"):
		nine_patch_found = true
	_check(atlas_found, "animated image exposes its first atlas frame")
	_check(nine_patch_found, "background9 uses a nine-patch control")
	_equal(form.collect_fields()["anim"], "1", "animated image initial frame")
	_check(form.fields["anim"].mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"animated image lets mouse input through")
	form.fields["anim"].advance_frame()
	_equal(form.collect_fields()["anim"], "2", "animated image advances and reports its frame")
	# Headless has no 3D rasteriser worth asserting on, so this checks the
	# scene the element builds, not what it draws.
	var models: Array = _nodes_of_type(form, "SubViewport")
	_equal(models.size(), 1, "model builds one SubViewport of its own")
	var sub: SubViewport = models[0]
	_check(sub.own_world_3d, "model viewport draws its own world, not the game's")
	_check(sub.transparent_bg, "model viewport keeps the form's background visible")
	_equal(_nodes_of_type(sub, "Camera3D").size(), 1, "model viewport holds one camera")
	var meshes: Array = _nodes_of_type(sub, "MeshInstance3D")
	_equal(meshes.size(), 1, "model viewport holds one mesh instance")
	_check(meshes[0].mesh != null, "model mesh instance carries a mesh")
	var preview: Control = form.named_controls["preview"]
	_equal(preview.pitch, -10.0, "model applies the initial camera pitch")
	_equal(preview.yaw, 200.0, "model applies the initial camera yaw")
	_check(preview.mouse_control, "model honours mouse control")
	_check(not preview.spinning, "model without continuous rotation does not spin")
	_check(preview.distance > 0.0, "model frames the camera at a positive distance")
	# The mesh whose media never arrived keeps the labelled placeholder.
	_check(_label_named(form, "unsent") != null, "model placeholder is labelled")
	_discard(form)


# The shape Mineclonia's creative inventory uses: a list inside a scroll
# container, driven by a named scrollbar declared after it. The container has
# no scroll of its own, so this is really a test that the two found each other.
func _test_scroll_container() -> void:
	var spec := "formspec_version[6]size[13,10]"
	spec += "scroll_container[0.375,0.875;11.575,6;scroll;vertical;1.25]"
	spec += "list[detached:test;store;0,0;9,20;]"
	spec += "scroll_container_end[]"
	spec += "scrollbaroptions[min=0;max=15;smallstep=1;largestep=1;arrows=hide]"
	spec += "scrollbar[11.75,0.825;0.75,6.1;vertical;scroll;0]"
	var form := _new_form(spec)
	_check(form.skipped.is_empty(), "scroll container form builds with nothing skipped")
	_check(form.scroll_containers.has("scroll"), "scroll container registers under its scrollbar name")
	_check(form.scrollbars.has("scroll"), "scrollbar registers under its own name")
	var bar: ScrollBar = form.scrollbars["scroll"]
	var mover: Control = form.scroll_containers["scroll"]
	_check(bar is VScrollBar, "a vertical scrollbar builds a VScrollBar")
	_equal((bar.get_theme_stylebox("scroll") as StyleBoxFlat).bg_color, Color8(230, 230, 230, 101),
		"its track is EGDC_SCROLLBAR's translucent grey")
	_equal((bar.get_theme_stylebox("grabber") as StyleBoxFlat).bg_color, Color8(62, 62, 62),
		"and its thumb an opaque dark grey")
	var grabber: StyleBox = bar.get_theme_stylebox("grabber")
	_equal(grabber.content_margin_top + grabber.content_margin_bottom, bar.size.x,
		"the thumb is never shorter than the bar is wide")
	_equal(bar.min_value, 0.0, "scrollbar minimum from scrollbaroptions")
	_check(bar.max_value - bar.page == 15.0, "scrollbar reaches the requested maximum")
	_equal(bar.custom_step, 1.0, "smallstep becomes the step the wheel and arrows take")
	_equal(mover.position.y, 0.0, "mover starts unscrolled")
	# One scroll unit moves the contents up by factor * imgsize, and the sign
	# is upstream's: a positive factor scrolls the content out of the top.
	bar.value = 4
	var expected := floorf(4.0 * -1.25 * form.imgsize)
	_equal(mover.position.y, expected, "mover follows the scrollbar by value times factor")
	_check(mover.get_parent().clip_contents, "scroll container clips its contents")
	_equal(form.collect_fields()["scroll"], "VAL:4", "scrollbar reports its value")
	_equal(bar.get_theme_icon("decrement").get_width(), 0, "arrows=hide draws no arrow buttons")
	_discard(form)
	# CGUIScrollBar: arrows=show puts square arrow buttons at both ends, the
	# thumb is thumbsize parts of max - min + 1 of the room between them, and
	# a bar whose max equals its min has no thumb and takes no input (the
	# sliders and the empty page scrollbar of Mineclonia's player settings).
	var bars := _new_form("formspec_version[6]size[10,10]"
		+ "scrollbaroptions[thumbsize=1;arrows=show;smallstep=1;min=1;max=3]"
		+ "scrollbar[1,1;4,0.25;horizontal;slider;2]"
		+ "scrollbaroptions[min=0;max=0;arrows=default]"
		+ "scrollbar[9,1;0.25,8;vertical;page;0]")
	var slider: ScrollBar = bars.scrollbars["slider"]
	var across := slider.size.y
	_equal(slider.get_theme_icon("decrement").get_width(), int(across), "a left arrow as square as the bar")
	_equal(slider.get_theme_icon("increment").get_width(), int(across), "and a right one")
	var room := slider.size.x - across * 2.0
	_check(is_equal_approx(slider.page / (slider.max_value - slider.min_value), (room / 3.0) / room),
		"the thumb is a third of the room between the arrows")
	_check(is_equal_approx(slider.max_value - slider.page, 3.0), "the slider reaches its max")
	var page: ScrollBar = bars.scrollbars["page"]
	_check(page.get_theme_stylebox("grabber") is StyleBoxEmpty, "a bar with max = min has no thumb")
	_equal(page.mouse_filter, Control.MOUSE_FILTER_IGNORE, "and takes no input")
	_equal(page.get_theme_icon("increment").get_width(), int(page.size.x),
		"arrows=default shows arrows on a bar four times as long as it is thick")
	_discard(bars)
	# GUIButton centres its text on the button even when the button is
	# smaller than a line of it: Mineclonia's quarter-slot "X" revert buttons.
	var tiny := _new_form("formspec_version[6]size[10,10]button[0.5,0.5;0.25,0.25;__reset__x;X]")
	var x_button := _button_named(tiny, "X")
	var x_label: Label = x_button.get_meta("content")["label"]
	_check(absf((x_label.position + x_label.size / 2.0).y - x_button.size.y / 2.0) <= 1.0,
		"a button's text stays centred on a button smaller than the text")
	_discard(tiny)


# style[] and style_type[] resolve by type with the inheritance chain, by
# name, and by state, with a later declaration beating an earlier one.
func _test_styles() -> void:
	var spec := "formspec_version[6]size[10,8]"
	spec += "style_type[button;bgcolor=#112233;textcolor=#ff0000]"
	spec += "style[named;bgcolor=#445566]"
	spec += "style[named:hovered;bgcolor=#778899]"
	spec += "button[0,0;2,1;named;Named]"
	spec += "button[0,1.5;2,1;plain;Plain]"
	spec += "style_type[list;size=0.5,0.5;spacing=0.25,0.25]"
	spec += "list[current_player;main;0,3;2,1;]"
	var form := _new_form(spec)
	_check(form.skipped.is_empty(), "styled form builds with nothing skipped")
	var named := _button_named(form, "Named")
	var plain := _button_named(form, "Plain")
	_check(named != null and plain != null, "both styled buttons build")
	# The name style wins over the type style it was declared after.
	_equal(named.get_theme_stylebox("normal").bg_color, Color.html("445566"),
		"style by name overrides style_type")
	_equal(plain.get_theme_stylebox("normal").bg_color, Color.html("112233"),
		"style_type reaches an unnamed-in-style button")
	_equal(named.get_theme_stylebox("hover").bg_color, Color.html("778899"),
		"a hovered state selector reaches the hover stylebox")
	_equal(plain.get_meta("content")["label"].get_theme_color("font_color"), Color.html("ff0000"),
		"textcolor from style_type")
	# size=0.5 halves the slot, and spacing=0.25 is the gap added on top of it.
	var slot: Control = form.slots[0]
	_equal(slot.size, Vector2(form.imgsize * 0.5, form.imgsize * 0.5).floor(),
		"style_type[list;size] resizes inventory slots")
	_equal(form.slots[1].position.x - slot.position.x, floorf(form.imgsize * 0.75),
		"style_type[list;spacing] sets the gap between slots")
	_discard(form)


# parseLabel: colour escapes kept, one element per line at upstream's
# spacing, the old system's 7/30 offset, and the area label of formspec
# version 9 with the halign and valign of version 11, the shape VoxeLibre's
# announcement cards use.
func _test_labels() -> void:
	var esc := char(0x1b)
	var runs: Array = Formspec.parse_enriched_runs(esc + "(c@#80ff20)12" + esc + "(c@#ffffff)", Color.BLACK)
	_equal(runs.size(), 1, "a coloured label is one run")
	_equal(runs[0]["color"], Color.html("80ff20"), "carrying its escape's colour")
	var spec := "formspec_version[9]size[10,8]style_type[label;textcolor=#323232]"
	spec += "label[1,1;Plain]"
	spec += "label[1,2;" + esc + "(c@#80ff20)12" + esc + "(c@#ffffff)]"
	spec += "label[1,3;One\nTwo]"
	spec += "style_type[label;halign=center;valign=center]"
	spec += "label[1,5;4,1;Centred area]"
	var form := _new_form(spec)
	_check(form.skipped.is_empty(), "labels build with nothing skipped")
	var plain := _text_named(form, "Plain")
	_check(plain != null, "a label is drawn as enriched text")
	if plain:
		_equal(plain.get_theme_color("default_color"), Color.html("323232"),
			"style_type[label;textcolor] is the label's colour")
		_equal(plain.position.y + plain.size.y / 2.0, form.imgsize,
			"a real-coordinate label is centred on its y")
	_check(_text_named(form, "12") != null, "a colour escape is not printed")
	var one := _text_named(form, "One")
	var two := _text_named(form, "Two")
	_check(one != null and two != null, "each line of a label is its own element")
	if one and two:
		_equal(two.position.y - one.position.y, floorf(form.imgsize / 2.0),
			"lines are half an imgsize apart in real coordinates")
	var area := _text_named(form, "Centred area")
	_check(area != null, "an area label shows its text, not its geometry")
	if area:
		_equal(area.size, (Vector2(4, 1) * form.imgsize).floor(), "an area label fills its rectangle")
		_equal(area.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER, "halign=center")
		_equal(area.vertical_alignment, VERTICAL_ALIGNMENT_CENTER, "valign=center")
		_check(area.autowrap_mode != TextServer.AUTOWRAP_OFF, "an area label wraps")
	_discard(form)
	# The old coordinate system: the 7/30 offset, and no area label.
	var old := _new_form("size[8,6]label[0,0;Old]label[1,1;2,1;Area]")
	var old_label := _text_named(old, "Old")
	_check(old_label != null, "an old-system label builds")
	if old_label:
		_check(absf(old_label.position.y + old_label.size.y / 2.0
			- (old.padding.y + 7.0 / 30.0 * old.spacing.y)) <= 1.0,
			"an old-system label is centred 7/30 of a spacing below its y")
	_check(_text_named(old, "Area") == null, "the old system has no area label")
	_discard(old)


# createTextField: the edit box colours of Luanti's skin, the field's style
# reaching its label, halign on a field, and the unnamed forms, which are a
# label and a read-only text.
func _test_fields() -> void:
	var spec := "formspec_version[11]size[10,9]"
	spec += "style_type[field;textcolor=#323232;halign=center]"
	spec += "field[1,1;4,0.8;name;Name;Ada]"
	spec += "pwdfield[1,2.5;4,0.8;secret;Secret]"
	spec += "textarea[1,4;4,1.5;notes;;hello]"
	spec += "field[6,1;3,0.8;;Only a label;ignored]"
	spec += "textarea[6,4;3,1.5;;Shown as text;]"
	var form := _new_form(spec)
	_check(form.skipped.is_empty(), "fields build with nothing skipped")
	var name_field: LineEdit = form.fields["name"]
	_equal((name_field.get_theme_stylebox("normal") as StyleBoxFlat).bg_color, Color8(128, 128, 128),
		"a field is EGDC_EDITABLE grey")
	_equal((name_field.get_theme_stylebox("focus") as StyleBoxFlat).bg_color, Color8(96, 134, 49),
		"and EGDC_FOCUSED_EDITABLE green while focused")
	_equal(name_field.get_theme_color("font_color"), Color.html("323232"), "textcolor reaches the field")
	_equal(name_field.alignment, HORIZONTAL_ALIGNMENT_CENTER, "halign=center reaches the field")
	var name_label := _text_named(form, "Name")
	_check(name_label != null, "the field's label is drawn")
	if name_label:
		_equal(name_label.get_theme_color("default_color"), Color.html("323232"),
			"the label takes the field's textcolor")
		_check(name_label.position.y < name_field.position.y, "the label sits above the field")
	var secret: LineEdit = form.fields["secret"]
	_check(secret.secret, "pwdfield[x,y;w,h;name;label] is a password field")
	var notes: TextEdit = form.fields["notes"]
	_equal((notes.get_theme_stylebox("normal") as StyleBoxFlat).bg_color, Color8(255, 255, 255, 101),
		"a textarea is EGDC_WINDOW's translucent white")
	_check(not form.fields.has(""), "an unnamed field is not a field")
	_check(_text_named(form, "Only a label") != null, "an unnamed field is only its label")
	_check(_text_named(form, "ignored") == null, "and its default is not shown")
	_check(_text_named(form, "Shown as text") != null,
		"an unnamed textarea with no default shows its label as its text")
	_discard(form)
	# The old coordinate system places fields without the form padding.
	var old := _new_form("size[8,6]field[1,1;3,1;f;;x]")
	var f: LineEdit = old.fields["f"]
	var btn_h: float = old.imgsize * 15.0 / 13.0 * 0.35
	var expected := Vector2(old.spacing.x, old.spacing.y + old.imgsize / 2.0 - btn_h)
	_check((f.position - expected).abs().x <= 1.0 and (f.position - expected).abs().y <= 1.0,
		"an old-system field is centred on y plus half its height, without padding")
	_discard(old)


# parseButton and parseDropDown geometry: an old-system button is two
# button-heights tall, centred half its height in slots below y; a dropdown
# given only a width is one imgsize tall in real coordinates and measures its
# width in vertical spacings in the old system.
func _test_button_geometry() -> void:
	var old := _new_form("size[8,6]button[1,1;2,1;b;B]dropdown[1,3;3;d;a,b;1]")
	var btn_h: float = old.imgsize * 15.0 / 13.0 * 0.35
	var b: Button = old.named_controls["b"]
	var top: float = old.padding.y + old.spacing.y + old.imgsize / 2.0 - btn_h
	_check(absf(b.position.y - top) <= 1.0, "an old-system button is centred half its height below y")
	_check(absf(b.size.y - btn_h * 2.0) <= 1.0, "and two button-heights tall")
	var d: OptionButton = old.fields["d"]
	_check(absf(d.size.x - 3.0 * old.spacing.y) <= 1.0,
		"an old-system dropdown's width is in vertical spacings")
	_discard(old)
	var real := _new_form("formspec_version[6]size[8,6]dropdown[1,1;3;d;a,b;1]")
	var rd: OptionButton = real.fields["d"]
	_equal(rd.size, (Vector2(3, 1) * real.imgsize).floor(),
		"a dropdown given only a width is one imgsize tall")
	_discard(real)
	# parseTabHeader: the position is the bottom edge, in spacings without
	# the padding in the old system, two button-heights tall and form wide.
	var tabs := _new_form("size[8,6]tabheader[0,0;tabs;A,B;1]")
	var tb: TabBar = tabs.fields["tabs"]
	var tab_h: float = tabs.imgsize * 15.0 / 13.0 * 0.35 * 2.0
	_check(absf(tb.position.x) <= 1.0 and absf(tb.position.y + tab_h) <= 1.0,
		"an old-system tab header stands on its y, without the form padding")
	_equal(tb.size.x, tabs.root.size.x, "and is as wide as the form")
	_discard(tabs)


# A form without size[], which is how Minetest Game's sign asks for its text:
# a 580 pixel window, 270 high plus 60 a field, its fields 300 wide and 60
# apart, and a Proceed button under them. The field shows the node's
# metadata for a whole ${key}.
func _test_sizeless_form() -> void:
	var form := _new_form("field[text;;${text}]")
	_equal(form.root.size, Vector2(580, 330), "a one-field sizeless form is 580 by 330")
	var text: LineEdit = form.fields["text"]
	_equal(text.position, Vector2(140, 120), "its field is centred, two rows down")
	_equal(text.size.x, 300.0, "and three hundred pixels wide")
	_equal(text.text, "Sign text", "a whole ${key} default shows the node's metadata")
	var proceed := _button_named(form, "Proceed")
	_check(proceed != null, "a sizeless form gets a Proceed button")
	if proceed:
		_equal(proceed.position, Vector2(220, 180), "under its fields, centred")
		_equal(proceed.size.x, 140.0, "140 pixels wide")
		var submissions: Array = []
		form.fields_submitted.connect(func(fields: Dictionary, quit: bool) -> void:
			submissions.append([fields, quit]))
		proceed.pressed.emit()
		_check(submissions.size() == 1 and submissions[0][1] and submissions[0][0].has("text"),
			"Proceed sends the fields and closes the form")
	_discard(form)


# setInitialFocus: with no set_focus[], the first empty edit box, else the
# first edit box, else the first table, else the last button.
func _test_initial_focus() -> void:
	var form := _new_form("formspec_version[6]size[8,6]field[1,1;3,0.8;a;;full]"
		+ "field[1,3;3,0.8;b;;]button[1,5;2,1;x;X]")
	_check(form.fields["b"].has_focus(), "the first empty edit box takes the focus")
	_discard(form)
	form = _new_form("formspec_version[6]size[8,6]field[1,1;3,0.8;a;;full]button[1,5;2,1;x;X]")
	_check(form.fields["a"].has_focus(), "failing that, the first edit box")
	_discard(form)
	form = _new_form("formspec_version[6]size[8,6]button[1,1;2,1;x;X]button[1,3;2,1;y;Y]")
	var last: Button = form.named_controls["y"]
	_check(last.has_focus(), "with no edit box or table, the last button")
	_check(last.get_theme_stylebox("focus") is StyleBoxEmpty, "and it draws no focus ring")
	_discard(form)


# The style properties that are not about looks: sound, played locally when
# a button, checkbox, dropdown or tab is used; font on Godot's own controls;
# and a model's bgcolor.
func _test_style_sound_font_model() -> void:
	var spec := "formspec_version[6]size[10,8]"
	spec += "style[go;sound=click;font=mono,bold]button[0,0;2,1;go;Go]"
	spec += "style_type[checkbox;sound=tick]checkbox[0,2;ok;OK;false]"
	spec += "style[pick;sound=pop]dropdown[3,2;3,0.8;pick;a,b;1]"
	spec += "style[tabs;sound=page]tabheader[0,5;tabs;One,Two;1]"
	spec += "style_type[field;font=italic]field[4,0;3,0.8;f;;]"
	spec += "style[preview;bgcolor=#ff0000]model[6,4;3,3;preview;character.b3d;skin.png]"
	var form := _new_form(spec)
	fixture_source.sounds.clear()
	form.named_controls["go"].pressed.emit()
	form.fields["ok"].toggled.emit(true)
	form.fields["pick"].item_selected.emit(1)
	form.fields["tabs"].tab_changed.emit(1)
	_equal(fixture_source.sounds, ["click", "tick", "pop", "page"],
		"each element plays its own style sound when used")
	var label: Label = form.named_controls["go"].get_meta("content")["label"]
	var bold := label.get_theme_font("font") as FontVariation
	_check(bold != null and bold.variation_embolden > 0.0 and bold.base_font is SystemFont,
		"font=mono,bold reaches the button label")
	var italic := form.fields["f"].get_theme_font("font") as FontVariation
	_check(italic != null and italic.variation_transform.y.x != 0.0, "font=italic reaches a field")
	var back: ColorRect = null
	for child in form.named_controls["preview"].get_children():
		if child is ColorRect:
			back = child
	_check(back != null and back.color == Color.RED, "a model's bgcolor fills it")
	_discard(form)


# GUIButton::setFromStyle, through the looks Godot draws. The shapes are the
# ones Mineclonia and VoxeLibre use: a prepend dressing every button and image
# button in a nine-sliced texture with border=false, the skin editor's
# transparent bgcolor over it, the creative inventory's tabs clearing it
# again, and the skin tabs' content_offset.
func _test_button_styles() -> void:
	var spec := "formspec_version[6]size[12,10]"
	spec += "style_type[button;border=false;bgimg=button9.png;bgimg_pressed=button9_pressed.png;bgimg_middle=2,2]"
	spec += "style_type[image_button;border=false;bgimg=button9.png;bgimg_middle=2,2]"
	spec += "button[0,0;3,1;themed;Themed]"
	spec += "style[clear;bgcolor=#00000000]button[0,1.5;3,1;clear;Clear]"
	spec += "style[tinted;bgcolor=#804020]button[0,3;3,1;tinted;Tinted]"
	spec += "style[bare;border=false;bgimg=;bgimg_pressed=;bgcolor=red]button[0,4.5;3,1;bare;Bare]"
	spec += "style[shifted;content_offset=16,0]button[0,6;3,1;shifted;Shifted]"
	spec += "style[legacy;bgimg_hovered=hovered.png]button[0,7.5;3,1;legacy;Legacy]"
	spec += "image_button[4,0;1,1;book.png;book;]"
	spec += "style[padded;padding=4]image_button[4,1.5;2,2;book.png;padded;]"
	spec += "image_button[4,4;1,1;up.png;own;;false;false;down.png]"
	spec += "item_image_button[7,0;1,1;default:stone;themed_item;]"
	spec += "style[tab;border=false;bgimg=;bgimg_pressed=]"
	spec += "item_image_button[7,1.5;1,1;default:apple 3;tab;]"
	var form := _new_form(spec)
	var src := fixture_source
	_check(form.skipped.is_empty(), "styled buttons build with nothing skipped")

	# border=false drops the pane, never the bgimg, and the pressed look
	# takes the deprecated bgimg_pressed.
	var themed: Button = form.named_controls["themed"]
	_check(not themed.flat, "border=false does not make the button flat")
	var normal := themed.get_theme_stylebox("normal") as StyleBoxTexture
	_check(normal != null and normal.texture == src.ui_texture("button9.png"),
		"border=false still draws the bgimg")
	if normal:
		_equal(normal.texture_margin_left, 2.0, "bgimg_middle nine-slices the bgimg")
	var pressed := themed.get_theme_stylebox("pressed") as StyleBoxTexture
	_check(pressed != null and pressed.texture == src.ui_texture("button9_pressed.png"),
		"bgimg_pressed becomes the pressed look")

	# bgcolor tints the image rather than replacing it; alpha zero hides it,
	# which is how the skin editor shows its models through the buttons.
	var clear := form.named_controls["clear"].get_theme_stylebox("normal") as StyleBoxTexture
	_check(clear != null and clear.modulate_color.a == 0.0, "a transparent bgcolor hides the bgimg")
	var tinted: Button = form.named_controls["tinted"]
	var tint := Formspec.parse_color("#804020", Color.WHITE)
	_equal((tinted.get_theme_stylebox("normal") as StyleBoxTexture).modulate_color, tint,
		"bgcolor tints the bgimg")
	_equal((tinted.get_theme_stylebox("hover") as StyleBoxTexture).modulate_color,
		Formspec._scale_rgb(tint, 1.25), "a default-state bgcolor is lightened when hovered")
	_equal((tinted.get_theme_stylebox("pressed") as StyleBoxTexture).modulate_color,
		Formspec._scale_rgb(tint, 0.85), "and darkened when pressed")
	_check(form.named_controls["bare"].get_theme_stylebox("normal") is StyleBoxEmpty,
		"with no bgimg and no border, a bgcolor has nothing to tint")
	var legacy := form.named_controls["legacy"].get_theme_stylebox("hover") as StyleBoxTexture
	_check(legacy != null and legacy.texture == src.ui_texture("hovered.png"),
		"bgimg_hovered becomes the hovered look")

	# content_offset=16,0 on top of bgimg_middle=2,2 moves the label 16
	# pixels right without narrowing it, past the button's right edge.
	var shifted: Button = form.named_controls["shifted"]
	var shifted_label: Label = shifted.get_meta("content")["label"]
	_equal(shifted_label.position, Vector2(18, 2), "content_offset moves the label")
	_equal(shifted_label.size, shifted.size - Vector2(4, 4), "without resizing it")
	_equal(shifted_label.get_theme_color("font_color"), Color.WHITE,
		"a button label is white unless textcolor says otherwise")
	_equal(shifted_label.get_theme_color("font_shadow_color"), Color(0, 0, 0, 127.0 / 255.0),
		"and carries Luanti's half-alpha text shadow")

	# An image button's image fills the content rectangle behind the label,
	# inset by bgimg_middle and padding, and one pixel further when pressed.
	var book: Button = form.named_controls["book"]
	var book_image: NinePatchRect = book.get_meta("content")["image"]
	_check(book_image.texture == src.ui_texture("book.png"), "image_button draws its texture")
	_equal(book_image.position, Vector2(2, 2), "the image is inset by bgimg_middle")
	_equal(book_image.size, book.size - Vector2(4, 4), "and fills the rest of the button")
	_check(book.get_theme_stylebox("normal") is StyleBoxTexture,
		"style_type[image_button] reaches an image button")
	var padded: Button = form.named_controls["padded"]
	var padded_image: NinePatchRect = padded.get_meta("content")["image"]
	_equal(padded_image.position, Vector2(6, 6), "padding adds to bgimg_middle")
	_equal(padded.get_meta("looks")[2]["rect"].position, Vector2(7, 7),
		"the content moves one pixel down and right while pressed")

	# The element's own texture, pressed texture and drawborder override the
	# theme, as parseImageButton sets them on the style.
	var own: Button = form.named_controls["own"]
	_check(own.get_meta("content")["image"].texture == src.ui_texture("up.png"),
		"image_button's texture parameter is the default fgimg")
	_check(own.get_meta("looks")[2]["fg"] == src.ui_texture("down.png"),
		"its pressed texture parameter is the pressed fgimg")
	_check(own.get_theme_stylebox("normal") is StyleBoxTexture,
		"drawborder=false still leaves the theme's bgimg")

	# item_image_button takes image_button's styles and the item's
	# description as its tooltip.
	var themed_item: Button = form.named_controls["themed_item"]
	_check(themed_item.get_theme_stylebox("normal") is StyleBoxTexture,
		"item_image_button inherits style_type[image_button]")
	_equal(form.tooltip_at(Vector2(-1, -1), themed_item, 1000).get("text"),
		"Description of default:stone", "item_image_button shows the item's description")
	var tab: Button = form.named_controls["tab"]
	_check(tab.get_theme_stylebox("normal") is StyleBoxEmpty,
		"clearing bgimg with border=false leaves the tab bare")
	_check(tab.get_meta("content")["image"].texture == src.item_icon("default:apple"),
		"the item fills the button")
	_discard(form)

	# The state rule is upstream's: a selector for focused+hovered also
	# reaches the hovered+pressed look, because the two share a bit.
	var states: Array = []
	for i in 8:
		states.append({})
	states[Formspec.STATE_FOCUSED | Formspec.STATE_HOVERED] = {"bgcolor": "red"}
	_check(Formspec._style_at(states, Formspec.STATE_HOVERED | Formspec.STATE_PRESSED).has("bgcolor"),
		"state propagation shares bits the way getStyleFromStatePropagation does")
	_check(not Formspec._style_at(states, Formspec.STATE_PRESSED).has("bgcolor"),
		"and leaves a state with no shared bit alone")


# hypertext markup drives the rich text label directly. The parse is checked
# through the plain text it produces plus the spans it opened, because Godot
# gives no way to read a pushed format back.
func _test_hypertext() -> void:
	# Attribute values may be quoted with either mark, and a backslash inside
	# a quoted value escapes the next character.
	var attrs := Formspec._markup_attrs("name=go color=\"#ff0000\" title='a \\'quoted\\' word'")
	_equal(attrs["name"], "go", "unquoted attribute value")
	_equal(attrs["color"], "#ff0000", "double quoted attribute value")
	_equal(attrs["title"], "a 'quoted' word", "escaped quote inside a quoted value")

	var spec := "formspec_version[6]size[10,8]"
	spec += "hypertext[0,0;9,4;rich;"
	spec += "<global color=#112233><tag name=warn color=#ff0000>"
	spec += "<b>bold</b> plain <warn>warned</warn> <action name=go>link</action>"
	# A doubled backslash survives the formspec unescape as a single one, and
	# the markup parser then reads it as a literal angle bracket.
	spec += " <img name=fixture.png width=32> \\\\<not a tag\\\\>"
	spec += "]"
	var form := _new_form(spec)
	_check(form.skipped.is_empty(), "hypertext form builds with nothing skipped")
	var rt: RichTextLabel = form.named_controls["rich"]
	_check(rt is RichTextLabel, "hypertext builds a RichTextLabel")
	_check(not rt.bbcode_enabled, "markup is parsed by us, not handed to BBCode")
	var plain: String = rt.get_parsed_text()
	_check(plain.contains("bold plain warned link"),
		"tag content survives while the tags themselves are consumed")
	_check(plain.contains("<not a tag>"), "an escaped angle bracket is literal text")
	_check(not plain.contains("fixture.png"), "an img tag is consumed, not printed")
	_equal(rt.get_theme_color("default_color"), Color.html("112233"),
		"global color sets the element default")
	_discard(form)

	# The page settings of <global>, wherever it stands, the shape
	# VoxeLibre's announcement title uses; white text and a three pixel
	# margin by default; and an action drawn in its hovercolor, red unless
	# the page says otherwise, while the pointer is on it.
	form = _new_form("formspec_version[6]size[10,8]"
		+ "hypertext[0,0;9,2;title;<big>Title</big><global halign=center valign=middle>]"
		+ "hypertext[0,3;9,2;links;<global margin=10 hovercolor=#00ff00>"
		+ "<action name=one>One</action> <action name=two>Two</action>]"
		+ "hypertext[0,6;9,1;plain;Plain]")
	var title: RichTextLabel = form.named_controls["title"]
	_equal(title.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER, "<global halign=center>")
	_equal(title.vertical_alignment, VERTICAL_ALIGNMENT_CENTER, "<global valign=middle>")
	var plain_rt: RichTextLabel = form.named_controls["plain"]
	_equal(plain_rt.get_theme_color("default_color"), Color.WHITE, "hypertext is white by default")
	_equal(plain_rt.get_theme_stylebox("normal").content_margin_left, 3.0,
		"with a three pixel margin")
	var links: RichTextLabel = form.named_controls["links"]
	_equal(links.get_theme_stylebox("normal").content_margin_left, 10.0, "<global margin=10>")
	_equal(links.get_meta("action_colours"), ["#0000FF", "#0000FF"], "actions are blue at rest")
	form._render_markup(links, form.fs_unescape("<global margin=10 hovercolor=#00ff00>"
		+ "<action name=one>One</action> <action name=two>Two</action>"), 1)
	_equal(links.get_meta("action_colours"), ["#0000FF", "#00ff00"],
		"the hovered action takes the page's hovercolor")
	form._render_markup(plain_rt, "<action name=x>X</action>", 0)
	_equal(plain_rt.get_meta("action_colours"), ["#FF0000"], "the default hovercolor is red")
	var submitted: Array = []
	form.fields_submitted.connect(func(fields: Dictionary, _quit: bool) -> void:
		submitted.append(fields))
	links.meta_clicked.emit({"index": 0, "name": "one", "url": ""})
	_check(submitted.size() == 1 and submitted[0].get("links") == "action:one",
		"clicking an action sends action:<name> under the element's name")
	_discard(form)
	# The old coordinate system places hypertext without the padding, a
	# button-height lower.
	var old := _new_form("size[8,6]hypertext[1,1;4,2;old;Old]")
	var old_rt: RichTextLabel = old.named_controls["old"]
	var expected := Vector2(old.spacing.x, old.spacing.y + old.imgsize * 15.0 / 13.0 * 0.35)
	_check((old_rt.position - expected).abs().x <= 1.0 and (old_rt.position - expected).abs().y <= 1.0,
		"an old-system hypertext starts without the form padding, a button-height down")
	_discard(old)


# GUITable's look, which textlist[] and table[] share: near black, white text,
# a green selection, no pane when transparent, a textlist item's #RRGGBB
# colour and its ## escape, and tableoptions[] over the defaults.
func _test_list_look() -> void:
	var form := _new_form("formspec_version[6]size[10,8]"
		+ "textlist[0,0;4,3;rows;#FF0000red,##FF0000plain,plain;1;false]"
		+ "textlist[5,0;4,3;clear;a,b;0;true]"
		+ "tableoptions[highlight=#0000ff]table[0,4;4,3;t;a,b;1]")
	var rows: ItemList = form.fields["rows"]
	_equal(rows.get_item_text(0), "red", "a colour prefix is not printed")
	_equal(rows.get_item_custom_fg_color(0), Color.RED, "it colours its item")
	_equal(rows.get_item_text(1), "FF0000plain", "## drops itself and keeps the rest from being a colour")
	_equal((rows.get_theme_stylebox("panel") as StyleBoxFlat).bg_color, Color8(30, 30, 30),
		"a textlist is EGDC_3D_HIGH_LIGHT's near black")
	_equal((rows.get_theme_stylebox("selected") as StyleBoxFlat).bg_color, Color8(70, 120, 50),
		"its selection is EGDC_HIGH_LIGHT green")
	_equal(rows.get_theme_color("font_color"), Color.WHITE, "its text is white")
	_check(form.fields["clear"].get_theme_stylebox("panel") is StyleBoxEmpty,
		"a transparent textlist draws no pane")
	var table: Tree = form.fields["t"]
	_equal((table.get_theme_stylebox("selected") as StyleBoxFlat).bg_color, Color.BLUE,
		"tableoptions[highlight] sets the table's selection")
	_equal((table.get_theme_stylebox("panel") as StyleBoxFlat).bg_color, Color8(30, 30, 30),
		"and the rest stays GUITable's default")
	_discard(form)
	var old := _new_form("size[8,6]textlist[1,1;3,2;l;a,b;0;false]")
	_equal(old.fields["l"].size, Vector2(3.0 * old.spacing.x, 2.0 * old.spacing.y).floor(),
		"an old-system textlist measures whole spacings")
	_discard(old)


# tablecolumns[] declares the layout; color and indent columns consume a cell
# each without being a column the player sees.
func _test_table() -> void:
	var spec := "formspec_version[6]size[10,8]"
	spec += "tableoptions[color=#00ff00;background=#101010;highlight=#466432]"
	spec += "tablecolumns[color;indent;text,align=right,width=4;text]"
	spec += "table[0,0;9,5;rows;"
	spec += "#ff0000,0,alpha,first,"
	spec += "#0000ff,1,beta,second"
	spec += ";2]"
	var form := _new_form(spec)
	_check(form.skipped.is_empty(), "table form builds with nothing skipped")
	var tree: Tree = form.fields["rows"]
	_check(tree is Tree, "table builds a Tree, not a flat list")
	_equal(tree.columns, 2, "color and indent columns are not visible columns")
	var first := tree.get_root().get_first_child()
	_equal(first.get_text(0), "alpha", "first visible cell of the first row")
	_equal(first.get_text(1), "first", "second visible cell of the first row")
	_equal(first.get_custom_color(0), Color.html("ff0000"), "a color column tints the cells after it")
	_equal(first.get_text_alignment(0), HORIZONTAL_ALIGNMENT_RIGHT, "column align option")
	# The second row asked for indent 1, so it hangs under the first.
	var second := first.get_first_child()
	_check(second != null, "an indent column nests the row it precedes")
	_equal(second.get_text(0), "beta", "second row content")
	_check(tree.hide_folding, "indent without a tree column shows no folding arrows")
	_equal(Formspec._table_row(tree), 2, "the table's selected row is the second")
	_check(not form.collect_fields().has("rows"), "a table is sent only with its own event")
	_discard(form)


# Every element upstream registers now builds something. This is the guard
# that a new Luanti element does not quietly render as nothing.
func _test_nothing_skipped() -> void:
	var spec := "formspec_version[6]size[8,6]allow_close[false]set_focus[name;true]"
	spec += "tableoptions[background=#000000]tablecolumns[text]"
	spec += "button_key[1,1;2,1;jump;Jump]field_enter_after_edit[name;true]"
	spec += "table[0,2;4,2;t;a,b;1]"
	var form := _new_form(spec)
	_equal(form.skipped, {}, "no element of a full form is left unrendered")
	_check(not form.skipped.has("allow_close"), "direct allow_close header is parsed separately")
	_check(not form.skipped.has("set_focus"), "direct set_focus header is parsed separately")
	_check(_button_named(form, "Jump") != null, "button_key draws a button with its label")
	_discard(form)


# The form draws its own tooltip, as GUIFormSpecMenu does, so the rules are
# upstream's: colours captured where each tooltip is parsed, olive and white
# until listcolors[] says otherwise, element tooltips after a rest of
# tooltip_show_delay, area and item tooltips at once, no item tooltip while a
# stack is carried, and colour escapes kept.
func _test_tooltips() -> void:
	var spec := "formspec_version[6]size[10,8]"
	spec += "button[0,0;2,1;early;Early]tooltip[early;Early help]"
	spec += "listcolors[#111;#222;#333;#000000;#ffffff]"
	spec += "button[0,1.5;2,1;late;Late]tooltip[late;Late help]"
	spec += "button[0,3;2,1;own;Own]tooltip[own;Own help;#ff0000;#00ff00]"
	spec += "button[0,4.5;2,1;tinted;Tinted]tooltip[tinted;" + char(0x1b) + "(c@#ffff00)Gold]"
	spec += "tooltip[4,0;2,2;Area help]"
	spec += "list[current_player;main;4,3;2,1;]"
	var form := _new_form(spec)
	var early: Button = form.named_controls["early"]
	var late: Button = form.named_controls["late"]
	var own: Button = form.named_controls["own"]
	var nowhere := Vector2(-100, -100)
	var tip: Dictionary = form.tooltip_at(nowhere, early, 1000)
	_equal(tip.get("bg"), Formspec.DEFAULT_TOOLTIP_BG, "a tooltip before listcolors is olive")
	_equal(tip.get("fg"), Color.WHITE, "with white text")
	tip = form.tooltip_at(nowhere, late, 1000)
	_equal(tip.get("bg"), Color.BLACK, "listcolors sets the colours of the tooltips after it")
	tip = form.tooltip_at(nowhere, own, 1000)
	_equal(tip.get("bg"), Color.RED, "a tooltip's own background colour")
	_equal(tip.get("fg"), Color.GREEN, "and text colour")
	_check(form.tooltip_at(nowhere, early, 100).is_empty(),
		"an element's tooltip waits for tooltip_show_delay")
	tip = form.tooltip_at(nowhere, form.named_controls["tinted"], 1000)
	_check(String(tip.get("text")).contains(char(0x1b)), "colour escapes survive to the tooltip")
	var area: Control = form.tooltip_areas[0]["area"]
	tip = form.tooltip_at(area.get_global_rect().get_center(), null, 0)
	_equal(tip.get("text"), "Area help", "an area tooltip shows at once")
	# An item's own description, straight away, and not while carrying.
	var slot: Control = form.slots[0]
	tip = form.tooltip_at(slot.get_global_rect().get_center(), slot, 0)
	_equal(tip.get("text"), "Stone", "a slot shows its item's description at once")
	_equal(tip.get("bg"), Color.BLACK, "in the listcolors tooltip colours")
	fixture_source.holding = true
	_check(form.tooltip_at(slot.get_global_rect().get_center(), slot, 0).is_empty(),
		"no item tooltip while a stack is carried")
	fixture_source.holding = false
	# The box: text centred, m_btn_height wider and five pixels taller than
	# the text, framed in black, the escape's colour kept.
	form._show_tooltip(form.tooltip_at(nowhere, form.named_controls["tinted"], 1000), Vector2(10, 10))
	var box: Panel = form.tooltip_box
	_check(box != null and box.visible, "the tooltip box is shown")
	if box:
		var frame := box.get_theme_stylebox("panel") as StyleBoxFlat
		_check(frame != null and frame.border_width_left == 1 and frame.border_color == Color.BLACK,
			"the box has a one pixel black frame")
		var rt: RichTextLabel = box.get_child(0)
		_equal(rt.get_parsed_text(), "Gold", "the box shows the text without its escape")
		var btn_h: float = form.imgsize * 15.0 / 13.0 * 0.35
		_check(box.size.x > btn_h and box.size.y > 5.0, "the box is padded around its text")
		_equal(box.global_position, (Vector2(10, 10) + Vector2(btn_h, btn_h)).floor(),
			"the box sits m_btn_height below and right of the pointer")
	_discard(form)


# GUIButtonKey: a key setting shown by the key's name, a click that starts
# capturing, the next key or mouse button sent as the element's field in
# Luanti 5.17's SYSTEM_SCANCODE_ and MOUSE_BUTTON_ form, Escape to cancel.
func _test_button_key() -> void:
	var form := _new_form("formspec_version[6]size[10,6]"
		+ "button_key[1,1;3,0.8;jump;SYSTEM_SCANCODE_44]button_key[1,3;3,0.8;fwd;KEY_KEY_W]")
	var jump: Button = form.named_controls["jump"]
	var fwd: Button = form.named_controls["fwd"]
	var jump_label: Label = jump.get_meta("content")["label"]
	_equal(jump_label.text, "Space", "a scancode setting shows its key's name")
	_equal(fwd.get_meta("content")["label"].text, "W", "an Irrlicht key name does too")
	_equal(fwd.get_meta("key_value"), "SYSTEM_SCANCODE_26", "and is held as its scancode")
	var sent: Array = []
	form.fields_submitted.connect(func(fields: Dictionary, _quit: bool) -> void:
		sent.append(fields))
	jump.pressed.emit()
	_equal(jump_label.text, "Press Button", "pressing it starts capturing")
	var q := InputEventKey.new()
	q.physical_keycode = KEY_Q
	q.keycode = KEY_Q
	q.pressed = true
	form._input(q)
	_check(sent.size() == 1 and sent[0].get("jump") == "SYSTEM_SCANCODE_20",
		"the next key is sent as the element's field")
	_equal(jump_label.text, "Q", "and shown by name")
	jump.pressed.emit()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	form._input(escape)
	_equal(sent.size(), 1, "Escape cancels without sending")
	_equal(jump_label.text, "Q", "and keeps the old key")
	fwd.pressed.emit()
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	form._input(right)
	_check(sent.size() == 2 and sent[1].get("fwd") == "MOUSE_BUTTON_3",
		"a mouse button is captured in SDL's numbering")
	_equal(fwd.get_meta("content")["label"].text, "Right Click", "and named")
	var rshift := InputEventKey.new()
	rshift.physical_keycode = KEY_SHIFT
	rshift.keycode = KEY_SHIFT
	rshift.location = KEY_LOCATION_RIGHT
	rshift.pressed = true
	fwd.pressed.emit()
	form._input(rshift)
	_equal(fwd.get_meta("key_value"), "SYSTEM_SCANCODE_229", "the right shift is told from the left")
	_discard(form)


# hypertip[], formspec version 11 (Luanti 5.17): markup in a tooltip, its
# width in ems, and a static position when one is given.
func _test_hypertip() -> void:
	var spec := "formspec_version[11]size[8,6]button[1,1;2,1;tip;Tip]"
	spec += "hypertip[tip;;10;tipname;<b>Bold</b> help]"
	spec += "style[pinned;bgcolor=#123456;border=false]"
	spec += "hypertip[4,1;2,1;1,4;8;pinned;Area <style color=red>help</style>]"
	spec += "button[1,3;2,1;both;Both]tooltip[both;Plain wins]hypertip[both;;10;x;Rich]"
	var form := _new_form(spec)
	_equal(form.skipped, {}, "hypertip is not skipped")
	var tip_button := _button_named(form, "Tip")
	var nowhere := Vector2(-100, -100)
	var tip: Dictionary = form.tooltip_at(nowhere, tip_button, 1000)
	_equal(tip.get("markup"), "<b>Bold</b> help", "a named hypertip keeps its markup")
	_equal(tip.get("width"), 10.0 * form._font_size(), "its width is in ems")
	_equal(form.tooltip_at(nowhere, form.named_controls["both"], 1000).get("text"), "Plain wins",
		"a tooltip beats a hypertip on the same element")
	var area: Control = form.tooltip_areas[0]["area"]
	tip = form.tooltip_at(area.get_global_rect().get_center(), null, 0)
	_equal(tip.get("static"), Vector2(1, 4) * form.imgsize, "the static position is in form units")
	form._show_tooltip(tip, area.get_global_rect().get_center())
	var box: Panel = form.tooltip_box
	_equal(box.global_position, form.root.global_position + Vector2(1, 4) * form.imgsize,
		"a static hypertip stands where it was told, not at the pointer")
	_equal(box.size.x, ceilf(8.0 * form._font_size()), "the box is as wide as the hypertip asks")
	var frame := box.get_theme_stylebox("panel") as StyleBoxFlat
	_check(frame.bg_color == Color.html("123456") and frame.border_width_left == 0,
		"style[] on the hypertip's name sets its bgcolor and border")
	var rt: RichTextLabel = box.get_child(0)
	_equal(rt.get_parsed_text(), "Area help", "the markup is rendered, not printed")
	_discard(form)


# The game's window theme, from TOCLIENT_FORMSPEC_PREPEND. This is the string
# Mineclonia sends (mods/CORE/mcl_init/init.lua, applied by
# mods/HUD/mcl_formspec_prepend). It has to build behind the form, in the old
# coordinate system whatever version the form itself asked for, and not at all
# when the form says no_prepend[].
const MINECLONIA_PREPEND := (
	"listcolors[#9990;#FFF7;#FFF0;#000;#FFF]"
	+ "style_type[button;border=false;bgimg=mcl_inventory_button9.png;"
	+ "bgimg_pressed=mcl_inventory_button9_pressed.png;bgimg_middle=2,2]"
	+ "style_type[label;textcolor=#323232]"
	+ "bgcolor[#00000000;true]"
	+ "background9[1,1;1,1;mcl_base_textures_background9.png;true;7]")


func _test_prepend() -> void:
	var spec := "formspec_version[6]size[10,8]box[1,1;2,2;#ff0000]"
	spec += "button[1,4;2,1;go;Submit]"
	var form := _new_form(spec, "conformance", MINECLONIA_PREPEND + "box[1,1;2,2;#00ff00]")
	_check(form.skipped.is_empty(), "a prepend builds with nothing skipped")
	_equal(form.prepend_elements.size(), 6, "prepend element count")
	var themed := _colorrect_of(form, Color.html("00ff00"))
	var own := _colorrect_of(form, Color.html("ff0000"))
	_check(themed != null and own != null, "the prepend and the form both build their box")
	if themed and own:
		_check(themed.get_index() < own.get_index(), "the prepend builds behind the form")
		# The form is version 6, so its own box is placed in real
		# coordinates, while the prepend keeps the old system.
		_equal(own.position, (Vector2(1, 1) * form.imgsize).floor(),
			"a version 6 form places its own element in real coordinates")
		_equal(themed.position, (form.padding + Vector2(1, 1) * form.spacing).floor(),
			"the prepend is not dragged into real coordinates")
	# The coordinate system and version are the form's again afterwards.
	_check(form.real_coordinates, "real coordinates survive the prepend")
	_equal(form.formspec_version, 6, "the formspec version survives the prepend")
	# bgcolor[#00000000;true] is how a game hides Godot's own panel so that
	# its background9 is what the player sees.
	_check(form.has_form_bgcolor, "a prepend bgcolor reaches the form panel")
	_equal(form.root.get_theme_stylebox("panel").bg_color, Color(0, 0, 0, 0),
		"the default grey panel is replaced by the prepend's colour")
	var nine_patch: NinePatchRect = null
	for candidate in _nodes_of_type(form, "NinePatchRect"):
		nine_patch = candidate
	_check(nine_patch != null, "the prepend's background9 builds a nine-patch")
	if nine_patch:
		# auto_clip fills the form, offset outward by the position in pixels.
		_equal(nine_patch.position, Vector2(-1, -1), "auto_clip background outset")
		_equal(nine_patch.size, form.root.size + Vector2(2, 2), "auto_clip background fills the form")
		_check(nine_patch.get_index() < own.get_index(), "the background sits behind the form")
	# listcolors and style_type from the prepend reach the form's own elements.
	_equal(form.listcolors["slot_bg"], Formspec.parse_color("#9990", Color.BLACK),
		"prepend listcolors apply to the form")
	var button := _button_named(form, "Submit")
	_check(button != null, "the form's own button builds under a prepend")

	# no_prepend[] is the form saying it wants none of it.
	var bare := _new_form("formspec_version[6]size[10,8]no_prepend[]box[1,1;2,2;#ff0000]",
		"conformance", MINECLONIA_PREPEND + "box[1,1;2,2;#00ff00]")
	_check(not bare.enable_prepends, "no_prepend clears the prepend flag")
	_check(bare.prepend_elements.is_empty(), "no_prepend parses no prepend elements")
	_check(_colorrect_of(bare, Color.html("00ff00")) == null, "no_prepend builds none of the theme")
	_check(_colorrect_of(bare, Color.html("ff0000")) != null, "no_prepend keeps the form itself")
	_check(bare.root.get_theme_stylebox("panel").bg_color != Color(0, 0, 0, 0),
		"no_prepend keeps the default panel")
	_discard(bare)

	# A prepend may carry its own version and coordinate directives, and
	# neither escapes into the form (GUIFormSpecMenu::regenerateGui backs
	# both up). size[] and the other front-of-form headers are not elements
	# at all here, so a prepend cannot resize the form.
	var scoped := _new_form("formspec_version[6]size[10,8]box[1,1;2,2;#ff0000]",
		"conformance", "size[4,4]real_coordinates[true]formspec_version[1]box[1,1;2,2;#00ff00]")
	_equal(scoped.invsize, Vector2(10, 8), "a prepend size header is ignored")
	_equal(scoped.formspec_version, 6, "a prepend formspec_version is undone")
	_check(scoped.real_coordinates, "a prepend real_coordinates is undone")
	_equal(_colorrect_of(scoped, Color.html("00ff00")).position,
		(Vector2(1, 1) * scoped.imgsize).floor(),
		"real_coordinates inside a prepend applies to the prepend")
	_discard(scoped)
	_discard(form)


# Backgrounds share one layer at the back of the form, in the order given,
# so a form's own background is drawn over the game theme's background9 and
# under everything else: Mineclonia's villager trade level bar.
func _test_background_order() -> void:
	var form := _new_form("formspec_version[6]size[10,8]box[1,1;2,2;#ff0000]"
		+ "background[1,1;3,1;bar.png]", "conformance", MINECLONIA_PREPEND)
	var layer: Control = form.bg_layer
	_equal(layer.get_index(), 0, "the background layer is the form's first child")
	_equal(layer.get_child_count(), 2, "it holds the theme's background and the form's")
	if layer.get_child_count() == 2:
		_check(layer.get_child(0) is NinePatchRect, "the theme's background9 is first")
		_equal(layer.get_child(1).texture, fixture_source.ui_texture("bar.png"),
			"and the form's own background over it")
	var box := _colorrect_of(form, Color.RED)
	_check(box != null and box.get_parent() == form.root and box.get_index() > 0,
		"everything else is in front of the layer")
	_discard(form)


# The renderer's prepend handling is no use unless the host hands the theme
# over. That wiring in game_ui.gd was lost once, to a commit recovered from a
# stale copy, and every form in every game went back to a plain grey panel
# while _test_prepend above still passed.
func _test_host_passes_prepend() -> void:
	var ui := _new_inventory_ui({"main": []})
	ui.fullscreen_tint = ColorRect.new()
	ui.client.prepend = MINECLONIA_PREPEND
	ui._show_server_formspec("formspec_version[6]size[10,8]label[1,1;Chest]", "mcl_chests:chest")
	_equal(ui.form.prepend_elements.size(), 5, "a server form is built with the game's prepend")
	ui.client.inventory_spec = "formspec_version[6]size[10,8]list[current_player;main;0.5,0.5;4,1;0]"
	ui._open_inventory()
	_equal(ui.form.prepend_elements.size(), 5, "the player's inventory is built with the game's prepend")
	ui.fullscreen_tint.free()
	_discard_inventory_ui(ui)


# --- the dark glass interface style (ui/glass_style.gd) ----------------------

# Mineclonia's whole window theme, as mcl_formspec_prepend sends it.
const MCL_THEME := (
	"listcolors[#9990;#FFF7;#FFF0;#000;#FFF]"
	+ "style_type[image_button;border=false;bgimg=mcl_inventory_button9.png;"
	+ "bgimg_pressed=mcl_inventory_button9_pressed.png;bgimg_middle=2,2]"
	+ "style_type[button;border=false;bgimg=mcl_inventory_button9.png;"
	+ "bgimg_pressed=mcl_inventory_button9_pressed.png;bgimg_middle=2,2]"
	+ "style_type[field;textcolor=#323232]"
	+ "style_type[label;textcolor=#323232]"
	+ "style_type[checkbox;textcolor=#323232]"
	+ "bgcolor[#00000000;true]"
	+ "background9[1,1;1,1;mcl_base_textures_background9.png;true;7]")

# A cut down Mineclonia survival inventory: slot frames drawn behind the
# lists, an empty armour slot outline drawn over one, the crafting arrow, a
# coloured label, an image button, a themed button and a field.
static func _mcl_inventory_spec() -> String:
	var esc := char(0x1b)
	var s := "formspec_version[6]size[11.75,10.9]"
	s += "image[0.325,0.325;1.1,1.1;mcl_formspec_itemslot.png]"
	s += "image[0.325,1.575;1.1,1.1;mcl_formspec_itemslot.png]"
	s += "list[current_player;armor;0.375,0.375;1,2;1]"
	s += "image[0.375,0.375;1,1;mcl_inventory_empty_armor_slot_helmet.png]"
	s += "image[9.125,1;1,1;crafting_formspec_arrow.png]"
	s += "label[6.61,0.5;" + esc + "(c@#313131)Crafting" + esc + "(c@)]"
	s += "image_button[6.575,4.075;1.1,1.1;craftguide_book.png;__mcl_craftguide;]"
	s += "button[1,9.2;3,0.8;go;Go]"
	s += "field[5,9.2;3,0.8;search;;]"
	s += "image[0.325,5.525;1.1,1.1;mcl_formspec_itemslot.png]"
	s += "image[1.575,5.525;1.1,1.1;mcl_formspec_itemslot.png]"
	s += "list[current_player;main;0.375,5.575;2,1;]"
	# One of a kind, so a hint rather than a frame: Mineclonia's trash can.
	s += "image[3.325,5.525;1.1,1.1;crafting_creative_trash.png]"
	s += "list[detached:test;store;3.375,5.575;1,1;]"
	# Far bigger than the slot it lies behind: a picture, not a frame.
	s += "image[5,5;3,3;mcl_inventory_background9.png]"
	s += "list[current_player;main;5.5,5.5;1,1;4]"
	# The frame texture with no slot on it.
	s += "image[9,6;1,1;mcl_formspec_itemslot.png]"
	return s

func _image_with(form: Node, texture_name: String) -> Array:
	var out: Array = []
	var tex: Texture2D = fixture_source.ui_texture(texture_name)
	for c in _nodes_of_type(form, "TextureRect") + _nodes_of_type(form, "NinePatchRect"):
		if c.texture == tex:
			out.append(c)
	return out

func _glass_panes(form: Node) -> Array:
	var out: Array = []
	for c in _nodes_of_type(form, "Control"):
		if c.has_meta("glass_surface"):
			out.append(c)
	return out

# The prepend's window chrome is replaced: its background9 by a glass pane,
# its bgcolor and listcolors ignored, its button art and text colour dropped.
func _test_glass_chrome() -> void:
	var form := _new_form(_mcl_inventory_spec(), "conformance", MCL_THEME, "glass")
	_check(form.glass and not form.bespoke, "a themed form is drawn in dark glass")
	_check(form.skipped.is_empty(), "a glass form builds with nothing skipped")
	_check(_image_with(form, "mcl_base_textures_background9.png").is_empty(),
		"the theme's background9 is not drawn in dark glass")
	var panes := _glass_panes(form.bg_layer)
	_equal(panes.size(), 1, "one glass pane stands in for the theme's background")
	if panes.size() == 1:
		_equal(panes[0].get_index(), 0, "the pane is at the back of the form")
		_equal(panes[0].size, form.root.size + Vector2(2, 2), "and fills it as auto_clip did")
	_check(form.root.get_theme_stylebox("panel") is StyleBoxEmpty,
		"the form's own panel is not drawn under the glass")
	_equal(form.listcolors["slot_bg"], Formspec.DEFAULT_LIST_SLOT_BG,
		"the theme's listcolors are not applied")
	_equal(form.fullscreen_bg, GlassStyle.BACKDROP, "the theme's full screen colour gives way")
	var go := _button_named(form, "Go")
	_check(go != null and not go.has_theme_stylebox_override("normal"),
		"a themed button without art of its own takes the glass button")
	if go:
		_check(go.get_theme_stylebox("normal") is StyleBoxFlat, "which is the glass Theme's")
		_check(GlassStyle.luminance(go.get_meta("content")["label"].get_theme_color("font_color")) > 0.5,
			"the theme's dark text colour is not applied to it")
	var book: Button = form.named_controls.get("__mcl_craftguide")
	_check(book != null and not (book.get_theme_stylebox("normal") is StyleBoxTexture),
		"an image button loses the theme's button art")
	if book:
		_equal(book.get_meta("content")["image"].texture, fixture_source.ui_texture("craftguide_book.png"),
			"and keeps its own image")
	var search: LineEdit = form.fields.get("search")
	_check(search != null and GlassStyle.luminance(search.get_theme_color("font_color")) > 0.5,
		"a field does not take the theme's dark text colour")
	var crafting := _text_named(form, "Crafting")
	_check(crafting != null, "the coloured label builds")
	if crafting:
		var drawn: Color = crafting.get_meta("colours")[0]
		_check(drawn != Color.html("313131"), "its dark colour escape is lifted on glass")
		_check(GlassStyle.contrast(GlassStyle.luminance(drawn), GlassStyle.PANEL_WORST) >= 4.5,
			"to at least 4.5:1 against the brightest the glass gets")
	var tip_owner: Button = form.named_controls.get("go")
	form._show_tooltip({"text": "Help", "bg": Formspec.DEFAULT_TOOLTIP_BG,
		"fg": Formspec.DEFAULT_TOOLTIP_FG}, Vector2(10, 10))
	var box: Control = form.tooltip_box
	_check(box != null and not _glass_panes(box).is_empty(), "a tooltip is a glass pane")
	_check(box != null and not _nodes_of_type(box, "BackBufferCopy").is_empty(),
		"which copies the screen again, so it frosts the form beneath it")
	_check(tip_owner != null, "the tooltip test found its button")
	# The same form in the game theme keeps all of it.
	var game := _new_form(_mcl_inventory_spec(), "conformance", MCL_THEME)
	_check(not game.glass, "the game theme is not glass")
	_check(not _image_with(game, "mcl_base_textures_background9.png").is_empty(),
		"the game theme draws the theme's background9")
	_check(_glass_panes(game).is_empty(), "and no glass")
	_equal(game.listcolors["slot_bg"], Formspec.parse_color("#9990", Color.BLACK),
		"and applies the theme's listcolors")
	_discard(game)
	_discard(form)

# Content stays: pictures, item art, hints over slots, a model, a box, and a
# form's own background, which sits over the glass pane.
func _test_glass_keeps_content() -> void:
	var spec := _mcl_inventory_spec()
	spec += "background[6,6;3,2;mcl_villager_level_bar.png]"
	spec += "item_image[8,8;1,1;default:apple]"
	spec += "model[9,7;2,3;player;character.b3d;skin.png;0,0]"
	spec += "box[10,1;1,1;#ff0000]"
	var form := _new_form(spec, "conformance", MCL_THEME, "glass")
	var hint := _image_with(form, "mcl_inventory_empty_armor_slot_helmet.png")
	_check(hint.size() == 1 and hint[0].visible, "an empty slot's outline drawn over it is kept")
	var arrow := _image_with(form, "crafting_formspec_arrow.png")
	_check(arrow.size() == 1 and arrow[0].visible, "the crafting arrow is kept")
	var own := _image_with(form, "mcl_villager_level_bar.png")
	_check(own.size() == 1, "a form's own background is kept")
	if own.size() == 1:
		_check(own[0].get_index() > _glass_panes(form.bg_layer)[0].get_index(),
			"in front of the glass pane")
	_check(not _nodes_of_type(form, "SubViewportContainer").is_empty(), "a model is kept")
	_check(_colorrect_of(form, Color.RED) != null, "a box is kept")
	_discard(form)

# The slot frame rule: an image behind a slot, framing it, whose texture
# frames more than one slot, is window chrome; anything else is content.
func _test_glass_slot_frames() -> void:
	var form := _new_form(_mcl_inventory_spec(), "conformance", MCL_THEME, "glass")
	var frames := _image_with(form, "mcl_formspec_itemslot.png")
	var hidden := 0
	var spare: Control = null
	for f in frames:
		if not f.visible:
			hidden += 1
			_check(f.get_meta("glass_replaced", false), "a hidden frame is marked replaced")
		else:
			spare = f
	_equal(hidden, 4, "every slot frame behind a slot is replaced by the glass slot")
	_check(spare != null, "the frame texture with no slot on it is kept")
	var trash := _image_with(form, "crafting_creative_trash.png")
	_check(trash.size() == 1 and trash[0].visible, "a one of a kind image behind a slot is kept")
	var big := _image_with(form, "mcl_inventory_background9.png")
	_check(big.size() == 1 and big[0].visible, "an image much bigger than the slot is kept")
	var framed := 0
	for s in form.slots:
		if s.framed:
			framed += 1
	_equal(framed, 4, "the slots of the framed lists are drawn framed")
	var over_art: Array = []
	for s in form.slots:
		if s.over_art:
			over_art.append(s.listname)
	_equal(over_art, ["store", "main"],
		"only the slots over a kept picture are see-through: the trash can and the big image")
	_discard(form)
	# Minetest Game marks its hotbar row with gui_hb_bg.png under exactly
	# that row: it keeps a look of its own.
	var mtg := "size[8,9]image[0,4.7;1,1;gui_hb_bg.png]image[1,4.7;1,1;gui_hb_bg.png]"
	mtg += "list[current_player;main;0,4.7;2,1;]list[current_player;main;0,5.85;2,1;8]"
	var mform := _new_form(mtg, "conformance",
		"bgcolor[#080808BB;true]listcolors[#00000069;#5A5A5A;#141318;#30434C;#FFF]"
		+ "background9[5,5;1,1;gui_formbg.png;true;10]", "glass")
	_equal(mform.slots.size(), 4, "both Minetest Game rows build")
	if mform.slots.size() == 4:
		_check(mform.slots[0].framed and mform.slots[1].framed, "the hotbar row is framed")
		_check(not mform.slots[2].framed and not mform.slots[3].framed, "the row below is not")
	_discard(mform)

# Mineclonia's creative inventory says no_prepend[] and writes the theme out
# again with its background9 at a rectangle of its own, which becomes the
# glass pane's rectangle.
func _test_glass_repeated_theme() -> void:
	var spec := "formspec_version[6]size[13,11.43]no_prepend[]"
	spec += MCL_THEME.replace("background9[1,1;1,1;mcl_base_textures_background9.png;true;7]", "")
	spec += "background9[0,1.34;13,8.75;mcl_base_textures_background9.png;;7]"
	spec += "button[1,10.5;3,0.8;go;Go]"
	spec += "list[current_player;main;0.375,2;2,1;]"
	var form := _new_form(spec, "conformance", MCL_THEME, "glass")
	_check(form.prepend_elements.is_empty(), "no_prepend builds no prepend")
	_check(_image_with(form, "mcl_base_textures_background9.png").is_empty(),
		"the repeated theme background9 is not drawn")
	var panes := _glass_panes(form.bg_layer)
	_equal(panes.size(), 1, "it becomes one glass pane")
	if panes.size() == 1:
		_equal(panes[0].position, (Vector2(0, 1.34) * form.imgsize).floor(),
			"at the background9's position")
		_equal(panes[0].size, (Vector2(13, 8.75) * form.imgsize).floor(), "and size")
	_equal(form.listcolors["slot_bg"], Formspec.DEFAULT_LIST_SLOT_BG,
		"the repeated listcolors are not applied")
	var go := _button_named(form, "Go")
	_check(go != null and not go.has_theme_stylebox_override("normal"),
		"the repeated button style is dropped")
	_discard(form)

# A form that paints its own window, a book, keeps the game theme whole, text
# colours included: they were chosen for the page.
func _test_glass_bespoke() -> void:
	var spec := "size[8,9]background[-0.5,-0.5;9,10;mcl_books_book_bg.png]"
	spec += "label[1,1;Page one]button_exit[3,8;2,1;done;Done]"
	var form := _new_form(spec, "conformance", MCL_THEME, "glass")
	_check(form.bespoke and not form.glass, "a book is not drawn in glass")
	_equal(_image_with(form, "mcl_books_book_bg.png").size(), 1, "its page is drawn")
	_check(_glass_panes(form).is_empty(), "with no glass")
	var page := _text_named(form, "Page one")
	_check(page != null and page.get_meta("colours")[0] == Color.html("323232"),
		"its text keeps the theme's colour")
	_discard(form)

# The style is presentation only: the same form sends the same fields.
func _test_glass_sends_the_same() -> void:
	var spec := "formspec_version[6]size[10,8]"
	spec += "field[0.5,0.5;3,0.8;name;Name;Wombat]"
	spec += "checkbox[4,0.8;ready;Ready;true]"
	spec += "dropdown[4,2;3,0.8;colour;red,green,blue;2;false]"
	spec += "textlist[0.5,2;3,2;pick;one,two,#ff0000three;2]"
	spec += "tabheader[0.5,5;tabs;A,B,C;3;false;true]"
	spec += "scrollbar[9,1;0.5,5;vertical;bar;400]"
	spec += "button[0.5,6.5;3,0.8;send;Send]"
	var sent := {}
	for style in ["game", "glass"]:
		var form := _new_form(spec, "conformance", MCL_THEME, style)
		var got: Array = []
		form.fields_submitted.connect(func(f: Dictionary, _q: bool) -> void: got.append(f))
		(_button_named(form, "Send") as Button).pressed.emit()
		sent[style] = [form.collect_fields(), got]
		_discard(form)
	_equal(sent["glass"][0], sent["game"][0], "a glass form collects the same fields")
	_equal(sent["glass"][1], sent["game"][1], "and a button sends the same fields")
	# Changing style with a form open keeps what was typed and sends nothing.
	var live := _new_form(spec, "conformance", MCL_THEME, "glass")
	var sent_now: Array = []
	live.fields_submitted.connect(func(f: Dictionary, _q: bool) -> void: sent_now.append(f))
	(live.fields["name"] as LineEdit).text = "Quokka"
	(live.fields["ready"] as CheckBox).set_pressed_no_signal(false)
	(live.fields["colour"] as OptionButton).select(2)
	(live.fields["pick"] as ItemList).select(0)
	(live.fields["bar"] as ScrollBar).set_value_no_signal(700)
	live.style = "game"
	live.restyle()
	_check(not live.glass, "restyle rebuilds in the new style")
	_equal((live.fields["name"] as LineEdit).text, "Quokka", "keeping what was typed")
	_check(not (live.fields["ready"] as CheckBox).button_pressed, "and what was ticked")
	_equal((live.fields["colour"] as OptionButton).selected, 2, "and the dropdown's choice")
	_equal((live.fields["pick"] as ItemList).get_selected_items(), PackedInt32Array([0]),
		"and the list's selection")
	_equal((live.fields["bar"] as ScrollBar).value, 700.0, "and the scrollbar's place")
	_check(sent_now.is_empty(), "and sending nothing")
	_discard(live)

# Window art of the form's own: a background of plain grey panel art is a
# glass pane; grey art behind a tab or a model is a glass tile, and the one
# lighter than its peers is the selected tab; grey art behind nothing, a
# small swatch, and every picture stay.
func _test_glass_window_art() -> void:
	var spec := "formspec_version[6]size[12,10]no_prepend[]"
	spec += "background9[0,1;12,8;art_198_42.png;false;7]"
	# three tabs drawn as image[] behind item buttons, the second lighter
	for i in 3:
		var art := "art_202_64.png" if i == 1 else "art_158_64.png"
		spec += "image[%s,0;1.5,1.44;%s]" % [0.2 + i * 1.6, art]
		spec += "item_image_button[%s,0.24;1,1;default:stone;tab%d;]" % [0.44 + i * 1.6, i]
	# three tabs drawn as buttons with art of their own, the third lighter
	for i in 3:
		var art := "art_202_64.png" if i == 2 else "art_158_64.png"
		spec += "style[btab%d;border=false;bgimg=%s;bgimg_pressed=%s]" % [i, art, art]
		spec += "button[%s,9;1.5,0.9;btab%d;]" % [5 + i * 1.6, i]
	# a dark backing behind a model
	spec += "image[1,2;2.25,2.83;art_12_42.png]"
	spec += "model[1,2.1;2.2,2.7;player;character.b3d;skin.png;0,0]"
	# a picture of a grid, framing nothing
	spec += "image[5,2;3,2;art_180_128.png]"
	# a small grey swatch as a button face
	spec += "style[swatch;bgimg=art_128_16.png]button[9,2;1,1;swatch;]"
	var form := _new_form(spec, "conformance", MCL_THEME, "glass")
	_check(form.glass and not form.bespoke, "a form drawing its own grey panel is glass, not bespoke")
	_check(_image_with(form, "art_198_42.png").is_empty(),
		"its own plain panel background becomes glass")
	_equal(_glass_panes(form.bg_layer).size(), 1, "one glass pane in its place")
	var tabs := _image_with(form, "art_158_64.png") + _image_with(form, "art_202_64.png")
	var hidden := 0
	for t in tabs:
		if not t.visible:
			hidden += 1
	_equal(hidden, 3, "tab art behind the tab buttons is replaced")
	var selected: Array = []
	for c in _nodes_of_type(form, "Control"):
		if c.get_meta("art_selected", false):
			selected.append(c)
	_equal(selected.size(), 2, "one selected tab in each row")
	var btab2: Button = form.named_controls["btab2"]
	var btab0: Button = form.named_controls["btab0"]
	_check(btab2.get_meta("art_selected", false), "the lighter button tab is the selected one")
	_check(not btab0.get_meta("art_selected", false), "a darker one is not")
	_check(not (btab0.get_theme_stylebox("normal") is StyleBoxTexture),
		"a button's own plain art becomes a glass pane")
	_check(not (btab0.get_theme_stylebox("normal") is StyleBoxEmpty),
		"even with border=false, since the art was its face")
	_check(btab0.get_meta("glass_backed", false),
		"a tab outside the form's glass gets a pane of the same glass behind it")
	var item: Button = form.named_controls["tab1"]
	_equal(item.get_meta("content")["item"], fixture_source.item_icon("default:stone"),
		"the tab's icon is kept")
	var backing := _image_with(form, "art_12_42.png")
	_check(backing.size() == 1 and not backing[0].visible, "a model's dark backing becomes a tile")
	var picture := _image_with(form, "art_180_128.png")
	_check(picture.size() == 1 and picture[0].visible, "grey art that frames nothing is kept")
	var swatch: Button = form.named_controls["swatch"]
	_check(swatch.get_theme_stylebox("normal") is StyleBoxTexture, "a small grey swatch is kept")
	_discard(form)
	var game := _new_form(spec, "conformance", MCL_THEME)
	_equal(_image_with(game, "art_158_64.png").filter(func(c: Control) -> bool: return c.visible).size(),
		2, "the game theme keeps every tab's art")
	_discard(game)
	# A frame much bigger than its slot becomes a tile of its own size; dark
	# line art over a slot is drawn light; a neutral grey box is a sunken
	# tile; line art over the whole form does not make it a painted page.
	var more := "formspec_version[6]size[12,10]"
	more += "background[0,0;12,10;line_48.png;true]"
	more += "image[0.95,0.95;1.1,1.1;art_157_74.png]image[2.2,0.95;1.1,1.1;art_157_74.png]"
	more += "list[current_player;main;1,1;2,1;]"
	more += "image[4.8,0.8;1.4,1.4;art_157_74.png]list[current_player;main;5,1;1,1;2]"
	more += "list[current_player;main;7,1;1,1;3]image[7,1;1,1;line_16.png]"
	more += "box[1,4;3,2;#555555]box[5,4;3,2;#aa2222]box[1,7;6,0.03;#ffffff]"
	var art := _new_form(more, "conformance", "", "glass")
	_check(art.glass and not art.bespoke, "line art over the whole form is not a painted page")
	var big: Array = _image_with(art, "art_157_74.png").filter(func(c: Control) -> bool:
		return c.size.x > art.imgsize * 1.3)
	_check(big.size() == 1 and not big[0].visible and big[0].get_meta("glass_replaced", false),
		"a frame much bigger than its slot is replaced")
	var tiles: Array = []
	for c in _nodes_of_type(art, "Panel"):
		if c.has_meta("window_art_lum") and c.size.x > art.imgsize * 1.3:
			tiles.append(c)
	_equal(tiles.size(), 1, "by a glass tile of its own size")
	var line: Array = _image_with(art, "line_16.png")
	var lit: Array = []
	for c in _nodes_of_type(art, "TextureRect"):
		if c.get_meta("glass_line_art", false):
			lit.append(c)
	_equal(line.size(), 0, "the dark line art over a slot is not drawn as it was")
	_equal(lit.size(), 1, "it is drawn light")
	if lit.size() == 1:
		var px: Color = (lit[0].texture as Texture2D).get_image().get_pixel(8, 8)
		_check(GlassStyle.luminance(px) > 0.5 and px.a > 0.9, "light, and as opaque as it was")
	var grey_box: Array = []
	for c in _nodes_of_type(art, "Panel"):
		if c.get_meta("glass_box", false):
			grey_box.append(c)
	_equal(grey_box.size(), 1, "a neutral grey box becomes a sunken tile")
	_check(_colorrect_of(art, Color.html("aa2222")) != null, "a coloured box stays")
	_check(_colorrect_of(art, Color.WHITE) != null, "a thin light rule stays")
	_discard(art)


# A form older than version 3 draws in legacySortElements' order: boxes,
# everything else, images, item images, lists, labels. Mineclonia's brewing
# stand builds its slot frame images after its lists and relies on it.
func _test_legacy_draw_order() -> void:
	var spec := "size[9,8.75]label[0,0;Title]list[current_player;main;0,1;2,1;]"
	spec += "image[0,1;1,1;frame.png]image[1,1;1,1;frame.png]box[0,3;2,1;#ff0000]"
	var form := _new_form(spec)
	var frames := _image_with(form, "frame.png")
	var slot: Control = form.slots[0]
	var title := _text_named(form, "Title")
	var box := _colorrect_of(form, Color.RED)
	_check(frames.size() == 2 and frames[0].get_index() < slot.get_index(),
		"an image built after a list is drawn under it")
	_check(title != null and title.get_index() > slot.get_index(), "labels are drawn over lists")
	_check(box != null and box.get_index() < frames[0].get_index(), "boxes are drawn under images")
	_discard(form)
	var v3 := _new_form("formspec_version[3]size[9,8]list[current_player;main;0,1;2,1;]"
		+ "image[0,1;1,1;frame.png]")
	_check(_image_with(v3, "frame.png")[0].get_index() > v3.slots[0].get_index(),
		"version 3 and later draw in the order written")
	_discard(v3)
	# In dark glass those frames, now behind the slots, are slot frames.
	var glassy := _new_form(spec, "conformance", MCL_THEME, "glass")
	var hidden := 0
	for f in _image_with(glassy, "frame.png"):
		if not f.visible:
			hidden += 1
	_equal(hidden, 2, "frames sorted behind their slots are replaced in glass")
	_discard(glassy)


# The contrast arithmetic behind "text on glass is legible whatever the world
# behind it is".
func _test_glass_legibility() -> void:
	var worst: float = GlassStyle.PANEL_WORST
	for c in [GlassStyle.TEXT, GlassStyle.TEXT_DIM]:
		_check(GlassStyle.contrast(GlassStyle.luminance(c), worst) >= 4.5,
			"interface text %s reaches 4.5:1 on the brightest glass" % c.to_html(false))
	_check(GlassStyle.contrast(GlassStyle.luminance(GlassStyle.TEXT), GlassStyle.control_worst()) >= 4.5,
		"button text reaches 4.5:1 on a hovered button over the brightest glass")
	for fill in [GlassStyle.SLOT_FILL, GlassStyle.SLOT_FILL_FRAMED, GlassStyle.SLOT_HOVER]:
		_check(GlassStyle.contrast(1.0, GlassStyle.worst_under(fill)) >= 4.5,
			"a slot's white count reaches 4.5:1 on its tile")
	for hex in ["313131", "323232", "0000ff", "ff0000", "00ff00", "555555", "7f3f00"]:
		var inked := GlassStyle.ink(Color.html(hex))
		_check(GlassStyle.contrast(GlassStyle.luminance(inked), worst) >= 4.5,
			"#%s is made legible on glass" % hex)
	_equal(GlassStyle.ink(Color.WHITE), Color.WHITE, "a colour already legible is unchanged")
	var red := GlassStyle.ink(Color.RED)
	_check(red.r > red.g and red.r > red.b, "a lifted colour keeps its hue")
	_check(GlassStyle.PANEL_WORST < 0.1, "the glass is never brighter than a dark grey")

# The player setting: two named choices in the Appearance tab, stored as text.
func _test_glass_setting() -> void:
	var row: Array = []
	for entry in GameUi.SETTINGS:
		if entry[1] == GlassStyle.KEY:
			row = entry
	_check(not row.is_empty(), "the interface style is a setting")
	if not row.is_empty():
		_equal(row[0], "Appearance", "in the Appearance tab")
		_equal(row[2], "choice", "as a choice")
		var values: Array = []
		for choice in row[5]:
			values.append(choice[0])
		_equal(values, ["glass", "game"], "of dark glass, the default, and the game theme")
	_check(GameUi.TEXT_SETTING_KINDS.has("choice"), "stored as text, not a number")


func _colorrect_of(node: Node, colour: Color) -> ColorRect:
	for candidate in _nodes_of_type(node, "ColorRect"):
		if candidate.color.is_equal_approx(colour):
			return candidate
	return null


# A form button carries its label as a child, so it is found by the label
# the renderer recorded rather than by Button.text.
func _button_named(node: Node, caption: String) -> Button:
	for candidate in _nodes_of_type(node, "Button"):
		if String(candidate.get_meta("label", candidate.text)) == caption:
			return candidate
	return null


# Form text is a RichTextLabel carrying its plain text as meta.
func _text_named(node: Node, text: String) -> RichTextLabel:
	for candidate in _nodes_of_type(node, "RichTextLabel"):
		if String(candidate.get_meta("plain", "")) == text:
			return candidate
	return null


func _label_named(node: Node, caption: String) -> Label:
	for candidate in _nodes_of_type(node, "Label"):
		if candidate.text == caption:
			return candidate
	return null


func _nodes_of_type(node: Node, type_name: String) -> Array:
	var found: Array = []
	for child in node.get_children():
		if child.is_class(type_name):
			found.append(child)
		found.append_array(_nodes_of_type(child, type_name))
	return found


func _write_reference_shots() -> void:
	var directory := OS.get_environment("GOANNA_FORMSPEC_SHOTS")
	if directory == "":
		return
	var error := DirAccess.make_dir_recursive_absolute(directory)
	_check(error == OK, "create reference-shot directory")
	if error != OK:
		return
	var form := _new_form("formspec_version[6]size[9,6]bgcolor[#263342]"
		+ "label[0.5,0.5;Goanna formspec fixture]"
		+ "field[0.5,2;3,0.8;name;Name;Wombat]checkbox[4,2;ready;Ready;true]"
		+ "dropdown[4,3;3,0.8;colour;red,green,blue;2;false]"
		+ "list[current_player;main;0.5,4;4,1;0]button[7,4;1.5,0.8;go;Go]")
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	_check(image != null, "capture reference-shot viewport")
	if image == null:
		_discard(form)
		return
	var path := directory.path_join("controls.png")
	_check(image.save_png(path) == OK, "write reference shot " + path)
	_discard(form)
