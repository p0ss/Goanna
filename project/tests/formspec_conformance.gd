# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless structural and behavioural checks for Goanna's formspec renderer.
extends SceneTree

const Formspec := preload("res://ui/formspec.gd")

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

	func get_list_item(location: String, listname: String, index: int) -> Dictionary:
		var items: Array = inventories.get(location + "|" + listname, [])
		return items[index] if index >= 0 and index < items.size() else {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_source = FakeItemSource.new()
	root.add_child(fixture_source)
	_test_split_and_unescape()
	_test_layout_headers()
	_test_controls_and_submission()
	_test_inventory_and_listring()
	_test_partial_elements()
	_test_scroll_container()
	_test_styles()
	_test_table()
	_test_hypertext()
	_test_nothing_skipped()
	await _write_reference_shots()
	if failures == 0:
		print("formspec conformance: PASS: ", checks, " checks")
		quit(0)
	else:
		push_error("formspec conformance: FAIL: %d of %d checks failed" % [failures, checks])
		quit(1)


func _new_form(spec: String, formname := "conformance") -> Control:
	var form := Formspec.new()
	form.item_source = fixture_source
	root.add_child(form)
	form.show_formspec(spec, formname, Vector2(1200, 800))
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


func _test_partial_elements() -> void:
	var spec := "formspec_version[6]size[10,7]"
	spec += "animated_image[0,0;1,1;anim;fixture.png;4;100;1]"
	spec += "background9[1,0;2,2;fixture.png;false;4]"
	spec += "hypertext[0,2;3,2;rich;<b>Plain fallback</b>]"
	spec += "button_url[3.5,2;2,0.8;url;Open;https://example.invalid]"
	spec += "table[6,0;3,2;rows;alpha,beta;1]"
	spec += "model[6,3;3,3;preview;character.b3d;skin.png]"
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
	_check(_label_named(form, "character") != null, "model placeholder is labelled")
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
