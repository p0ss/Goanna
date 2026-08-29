# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless structural and behavioural checks for Goanna's formspec renderer.
extends SceneTree

const Formspec := preload("res://ui/formspec.gd")
const GameUi := preload("res://ui/game_ui.gd")

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

	func ui_texture(_name: String) -> Texture2D:
		return texture

	func item_icon(_name: String) -> Texture2D:
		return texture

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

	func inventory_action(action: String) -> void:
		actions.append(action)

	func inventory_state_at(_location: String) -> Dictionary:
		return {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_source = FakeItemSource.new()
	root.add_child(fixture_source)
	_test_split_and_unescape()
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
	_test_table()
	_test_hypertext()
	_test_nothing_skipped()
	_test_prepend()
	await _write_reference_shots()
	if failures == 0:
		print("formspec conformance: PASS: ", checks, " checks")
		quit(0)
	else:
		push_error("formspec conformance: FAIL: %d of %d checks failed" % [failures, checks])
		quit(1)


func _new_form(spec: String, formname := "conformance", prepend := "") -> Control:
	var form := Formspec.new()
	form.item_source = fixture_source
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
	spec += "field[0.5,3;3,0.8;name;Name;Ada]pwdfield[4,3;3,0.8;secret;Secret;key]"
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
	_equal(form.collect_fields()["secret"], "key", "password field default")
	_equal(form.collect_fields()["enabled"], "true", "checkbox default")
	_equal(form.collect_fields()["choice"], "2", "index-event dropdown default")
	_equal(form.collect_fields()["rows"], "CHG:2", "text list default")

	var submissions: Array = []
	form.fields_submitted.connect(func(fields: Dictionary, quit: bool) -> void:
		submissions.append({"fields": fields, "quit": quit}))
	var submit_button := _button_named(form, "Submit")
	_check(submit_button != null, "ordinary button is built")
	if submit_button:
		_check(submit_button.has_focus(), "set_focus targets a named button")
		_equal(submit_button.tooltip_text, "Submit tooltip", "named tooltip")
		submit_button.pressed.emit()
		_equal(submissions.back()["fields"]["go"], "Submit", "button field value")
		_check(not submissions.back()["quit"], "ordinary button keeps form open")
	var exit_button := _button_named(form, "Leave")
	_check(exit_button != null, "exit button is built")
	if exit_button:
		exit_button.pressed.emit()
		_check(submissions.back()["quit"], "exit button requests close")
	var name_field: LineEdit = form.fields["name"]
	name_field.text_submitted.emit(name_field.text)
	_equal(submissions.back()["fields"]["key_enter_field"], "name", "enter field name")
	_check(not submissions.back()["quit"], "field_close_on_enter false is honoured")
	var area_tooltip := _control_with_tooltip(form, "Area tooltip")
	_check(area_tooltip != null, "area tooltip is built")
	if area_tooltip and submit_button:
		_check(area_tooltip.get_index() < submit_button.get_index(),
			"area tooltip stays behind interactive controls")
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
	_equal(bar.min_value, 0.0, "scrollbar minimum from scrollbaroptions")
	_check(bar.max_value - bar.page == 15.0, "scrollbar reaches the requested maximum")
	_equal(bar.step, 1.0, "smallstep becomes the scrollbar step")
	_equal(mover.position.y, 0.0, "mover starts unscrolled")
	# One scroll unit moves the contents up by factor * imgsize, and the sign
	# is upstream's: a positive factor scrolls the content out of the top.
	bar.value = 4
	var expected := floorf(4.0 * -1.25 * form.imgsize)
	_equal(mover.position.y, expected, "mover follows the scrollbar by value times factor")
	_check(mover.get_parent().clip_contents, "scroll container clips its contents")
	_equal(form.collect_fields()["scroll"], "VAL:4", "scrollbar reports its value")
	_discard(form)


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
	_equal(plain.get_theme_color("font_color"), Color.html("ff0000"),
		"textcolor from style_type")
	# size=0.5 halves the slot, and spacing=0.25 is the gap added on top of it.
	var slot: Control = form.slots[0]
	_equal(slot.size, Vector2(form.imgsize * 0.5, form.imgsize * 0.5).floor(),
		"style_type[list;size] resizes inventory slots")
	_equal(form.slots[1].position.x - slot.position.x, floorf(form.imgsize * 0.75),
		"style_type[list;spacing] sets the gap between slots")
	_discard(form)


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
	_equal(form.collect_fields()["rows"], "CHG:2", "table reports the selected row")
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


func _colorrect_of(node: Node, colour: Color) -> ColorRect:
	for candidate in _nodes_of_type(node, "ColorRect"):
		if candidate.color.is_equal_approx(colour):
			return candidate
	return null


func _button_named(node: Node, caption: String) -> Button:
	for candidate in _nodes_of_type(node, "Button"):
		if candidate.text == caption:
			return candidate
	return null


func _label_named(node: Node, caption: String) -> Label:
	for candidate in _nodes_of_type(node, "Label"):
		if candidate.text == caption:
			return candidate
	return null


func _control_with_tooltip(node: Node, tooltip: String) -> Control:
	for candidate in _nodes_of_type(node, "Control"):
		if candidate.tooltip_text == tooltip:
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
