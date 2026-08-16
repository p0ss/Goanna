# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Formspec renderer: parses a Luanti formspec string and builds Godot
# Controls for it. The layout rules (imgsize, spacing, padding, the two
# coordinate systems, position and anchor) follow GUIFormSpecMenu in
# luanti/src/gui/guiFormSpecMenu.cpp; the parser is a GDScript rewrite, not
# a transplant, because upstream's parser and its Irrlicht widgets are one
# class. Elements not yet handled are listed as skipped in the log.
#
# The scene using this provides an ItemSource (game_ui.gd) for inventory
# lists, item icons and the cursor stack, and receives:
#   fields_submitted(fields: Dictionary, quit: bool)
#   slot_clicked(location: String, listname: String, index: int, button: int, shift: bool)
extends Control

signal fields_submitted(fields: Dictionary, quit: bool)
signal slot_clicked(location: String, listname: String, index: int, button: int, shift: bool)
signal slot_released(location: String, listname: String, index: int, button: int)
signal closed()

const ELEM_SEP := "]"
const DEFAULT_LIST_SLOT_BG := Color(0, 0, 0, 0.55)
const DEFAULT_LIST_SLOT_BORDER := Color(1, 1, 1, 0.25)

var item_source: Node                # game_ui.gd, see get_list_items / item_icon
var formname := ""
var real_coordinates := false
var formspec_version := 1
var invsize := Vector2(8, 9)
var has_size := false
var imgsize := 48.0
var spacing := Vector2(60, 55.4)
var padding := Vector2(18, 18)
var pos_offset := Vector2.ZERO
var container_stack: Array = []
var form_position := Vector2(0.5, 0.5)
var form_anchor := Vector2(0.5, 0.5)
var form_padding := Vector2(0.05, 0.05)
var fullscreen_bg := Color(0, 0, 0, 0)
var form_bgcolor := Color(0, 0, 0, 0)
var has_form_bgcolor := false
var listcolors := {"slot_bg": DEFAULT_LIST_SLOT_BG, "slot_bg_h": Color(0.4, 0.4, 0.4, 0.6),
	"slot_border": DEFAULT_LIST_SLOT_BORDER, "tooltip_bg": Color(0.15, 0.15, 0.15, 0.95),
	"tooltip_fg": Color(1, 1, 1)}
var tooltips := {}                   # element name -> text
var list_rings: Array = []           # [{location, listname}]
var fields := {}                     # name -> Control (LineEdit/TextEdit/CheckBox/OptionButton/ItemList)
var field_close_on_enter := {}       # name -> bool
var slots: Array = []                # slot buttons for refresh
var pending_elements: Array = []     # parsed [name, params] awaiting layout
var root: Control                    # the form panel
var current_parent: Control
var skipped := {}

# --- public -----------------------------------------------------------------

func show_formspec(spec: String, name: String, screen: Vector2) -> void:
	formname = name
	for c in get_children():
		c.queue_free()
	_reset()
	_parse(spec)
	_layout(screen)
	_build()
	refresh_lists()

func refresh_lists() -> void:
	for s in slots:
		if is_instance_valid(s):
			s.refresh()

func collect_fields() -> Dictionary:
	var out := {}
	for n in fields:
		var c: Control = fields[n]
		if not is_instance_valid(c):
			continue
		if c is LineEdit:
			out[n] = c.text
		elif c is TextEdit:
			out[n] = c.text
		elif c is CheckBox:
			out[n] = "true" if c.button_pressed else "false"
		elif c is OptionButton:
			var ob := c as OptionButton
			var i: int = ob.selected
			if ob.get_meta("index_event", false):
				out[n] = str(i + 1)
			else:
				out[n] = ob.get_item_text(i) if i >= 0 else ""
		elif c is ItemList:
			var sel: PackedInt32Array = (c as ItemList).get_selected_items()
			out[n] = ("CHG:" + str(sel[0] + 1)) if sel.size() > 0 else ""
		elif c is TabBar:
			out[n] = str((c as TabBar).current_tab + 1)
	return out

func submit(extra: Dictionary, quit: bool) -> void:
	var f := collect_fields()
	for k in extra:
		f[k] = extra[k]
	if quit:
		f["quit"] = "true"
	fields_submitted.emit(f, quit)

# --- parsing ---------------------------------------------------------------

func _reset() -> void:
	real_coordinates = false
	formspec_version = 1
	invsize = Vector2(8, 9)
	has_size = false
	pos_offset = Vector2.ZERO
	container_stack.clear()
	form_position = Vector2(0.5, 0.5)
	form_anchor = Vector2(0.5, 0.5)
	form_padding = Vector2(0.05, 0.05)
	fullscreen_bg = Color(0, 0, 0, 0)
	form_bgcolor = Color(0, 0, 0, 0)
	has_form_bgcolor = false
	tooltips.clear()
	list_rings.clear()
	fields.clear()
	field_close_on_enter.clear()
	slots.clear()
	pending_elements.clear()
	skipped.clear()

# Luanti's split: a backslash escapes the next character (kept, unescaped later).
static func fs_split(s: String, delim: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	var esc := false
	for ch in s:
		if esc:
			cur += "\\" + ch
			esc = false
		elif ch == delim:
			out.append(cur)
			cur = ""
		elif ch == "\\":
			esc = true
		else:
			cur += ch
	out.append(cur)
	return out

static func fs_unescape(s: String) -> String:
	var out := ""
	var esc := false
	for ch in s:
		if esc:
			out += ch
			esc = false
		elif ch == "\\":
			esc = true
		else:
			out += ch
	# strip enriched-text escape sequences: ESC ( ... )
	var res := ""
	var i := 0
	while i < out.length():
		if out.unicode_at(i) == 0x1b and i + 1 < out.length() and out[i + 1] == "(":
			var j := out.find(")", i)
			if j < 0:
				break
			i = j + 1
			continue
		if out.unicode_at(i) == 0x1b:
			i += 2
			continue
		res += out[i]
		i += 1
	return res

func _parse(spec: String) -> void:
	for raw in fs_split(spec, ELEM_SEP):
		var e := raw.strip_edges()
		if e == "":
			continue
		var br := e.find("[")
		if br < 0:
			continue
		var name := e.substr(0, br).strip_edges()
		var params := e.substr(br + 1)
		# header elements are applied while parsing, the rest at build time
		match name:
			"formspec_version":
				formspec_version = int(params)
				if formspec_version >= 2:
					real_coordinates = true
			"real_coordinates":
				real_coordinates = params.strip_edges() == "true"
			"size":
				var p := fs_split(params, ",")
				if p.size() >= 2:
					invsize = Vector2(float(p[0]), float(p[1]))
					has_size = true
			"position":
				var p := fs_split(params, ",")
				if p.size() >= 2:
					form_position = Vector2(float(p[0]), float(p[1]))
			"anchor":
				var p := fs_split(params, ",")
				if p.size() >= 2:
					form_anchor = Vector2(float(p[0]), float(p[1]))
			"padding":
				var p := fs_split(params, ",")
				if p.size() >= 2:
					form_padding = Vector2(float(p[0]), float(p[1]))
			"no_prepend", "allow_close", "set_focus", "focus":
				pass
			_:
				pending_elements.append([name, params])

# --- layout maths (GUIFormSpecMenu::regenerateGui) ---------------------------

func _layout(screen: Vector2) -> void:
	var padded := Vector2(screen.x * (1.0 - form_padding.x * 2.0), screen.y * (1.0 - form_padding.y * 2.0))
	var fitx: float
	var fity: float
	if real_coordinates:
		fitx = padded.x / maxf(invsize.x, 0.01)
		fity = padded.y / maxf(invsize.y, 0.01)
	else:
		fitx = padded.x / ((5.0 / 4.0) * (0.5 + invsize.x))
		fity = padded.y / ((15.0 / 13.0) * (0.85 + invsize.y))
	var prefer := minf(padded.x, padded.y) / 15.0
	imgsize = floorf(minf(prefer, minf(fitx, fity)))
	spacing = Vector2(imgsize * 5.0 / 4.0, imgsize * 15.0 / 13.0)
	padding = Vector2(imgsize * 3.0 / 8.0, imgsize * 3.0 / 8.0)
	var btn_h := imgsize * 15.0 / 13.0 * 0.35
	var form_size: Vector2
	if real_coordinates:
		form_size = invsize * imgsize
	else:
		form_size = Vector2(padding.x * 2 + spacing.x * (invsize.x - 1.0) + imgsize,
			padding.y * 2 + spacing.y * (invsize.y - 1.0) + imgsize + btn_h * 2.0 / 3.0)
	var origin := Vector2(screen.x * form_position.x - form_anchor.x * form_size.x,
		screen.y * form_position.y - form_anchor.y * form_size.y)
	root = Panel.new()
	root.position = origin.floor()
	root.size = form_size.floor()
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	current_parent = root

func _pos(v: PackedStringArray) -> Vector2:
	if real_coordinates:
		return Vector2((float(v[0]) + pos_offset.x) * imgsize, (float(v[1]) + pos_offset.y) * imgsize)
	return Vector2(padding.x + (pos_offset.x + float(v[0])) * spacing.x,
		padding.y + (pos_offset.y + float(v[1])) * spacing.y)

func _geom(v: PackedStringArray) -> Vector2:
	if real_coordinates:
		return Vector2(float(v[0]) * imgsize, float(v[1]) * imgsize)
	return Vector2(float(v[0]) * spacing.x - (spacing.x - imgsize), float(v[1]) * spacing.y - (spacing.y - imgsize))

func _btn_geom(v: PackedStringArray) -> Rect2:
	# buttons in the old system: width in spacing units, fixed height
	if real_coordinates:
		return Rect2(Vector2.ZERO, _geom(v))
	var w := float(v[0]) * spacing.x - (spacing.x - imgsize)
	var h := imgsize * 15.0 / 13.0 * 0.35 * 2.0
	return Rect2(Vector2(0, -h / 2.0), Vector2(w, h))

static func parse_color(s: String, fallback: Color) -> Color:
	s = s.strip_edges()
	if s == "":
		return fallback
	if s.begins_with("#"):
		var h := s.substr(1)
		if h.length() == 3 or h.length() == 4:
			var e := ""
			for ch in h:
				e += ch + ch
			h = e
		if h.length() == 6 or h.length() == 8:
			return Color.html(h)
		return fallback
	if Color.html_is_valid(s):
		return Color.html(s)
	# named colours, a few common ones
	var named := {"white": Color.WHITE, "black": Color.BLACK, "red": Color.RED, "green": Color.GREEN,
		"blue": Color.BLUE, "yellow": Color.YELLOW, "gray": Color.GRAY, "grey": Color.GRAY,
		"orange": Color.ORANGE, "cyan": Color.CYAN, "magenta": Color.MAGENTA}
	var base := s
	var alpha := 1.0
	if s.contains("#"):
		base = s.get_slice("#", 0)
		alpha = ("0x" + s.get_slice("#", 1)).hex_to_int() / 255.0
	if named.has(base):
		var c: Color = named[base]
		c.a = alpha
		return c
	return fallback

# --- building --------------------------------------------------------------

func _build() -> void:
	# a fullscreen tint behind the form, if asked for
	add_child(root)
	for el in pending_elements:
		var name: String = el[0]
		var parts := fs_split(el[1], ";")
		match name:
			"container": _container(parts)
			"container_end": _container_end()
			"scroll_container": _scroll_container(parts)
			"scroll_container_end": _container_end()
			"bgcolor": _bgcolor(parts)
			"background", "background9": _background(parts)
			"box": _box(parts)
			"image": _image(parts)
			"animated_image": _animated_image(parts)
			"item_image": _item_image(parts)
			"label": _label(parts, false)
			"vertlabel": _label(parts, true)
			"hypertext": _hypertext(parts)
			"button", "button_exit", "button_url", "button_url_exit": _button(parts, name.ends_with("_exit"), "")
			"image_button", "image_button_exit": _image_button(parts, name.ends_with("_exit"))
			"item_image_button": _item_image_button(parts)
			"field", "pwdfield": _field(parts, name == "pwdfield")
			"textarea": _textarea(parts)
			"field_close_on_enter": _fcoe(parts)
			"checkbox": _checkbox(parts)
			"dropdown": _dropdown(parts)
			"textlist", "table": _textlist(parts)
			"tabheader": _tabheader(parts)
			"list": _list(parts)
			"listring": _listring(parts)
			"listcolors": _listcolors(parts)
			"tooltip": _tooltip(parts)
			"model": _model(parts)
			"style", "style_type", "tableoptions", "tablecolumns", "scrollbar", "scrollbaroptions", "set_focus", "focus":
				skipped[name] = skipped.get(name, 0) + 1
			_:
				skipped[name] = skipped.get(name, 0) + 1
	if skipped.size() > 0:
		print("formspec: elements not rendered: ", skipped)
	if not has_size and fields.size() > 0:
		# text-only form: implicit Proceed button
		var b := Button.new()
		b.text = "Proceed"
		b.position = Vector2(root.size.x / 2 - 60, root.size.y - 40)
		b.size = Vector2(120, 32)
		b.pressed.connect(func() -> void: submit({}, true))
		root.add_child(b)
	# a bare form with only images and buttons still needs a background
	if has_form_bgcolor:
		var sb := StyleBoxFlat.new()
		sb.bg_color = form_bgcolor
		root.add_theme_stylebox_override("panel", sb)
	else:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.13, 0.13, 0.13, 0.9)
		sb.set_corner_radius_all(int(imgsize * 0.08))
		root.add_theme_stylebox_override("panel", sb)

func _add(c: Control, pos: Vector2, size: Vector2) -> void:
	c.position = pos.floor()
	c.size = size.floor()
	current_parent.add_child(c)

func _container(parts: PackedStringArray) -> void:
	var v := fs_split(parts[0], ",") if parts.size() >= 1 else PackedStringArray()
	if v.size() < 2:
		return
	container_stack.push_back(pos_offset)
	pos_offset += Vector2(float(v[0]), float(v[1]))

func _container_end() -> void:
	if container_stack.size() > 0:
		pos_offset = container_stack.pop_back()
	if current_parent != root and current_parent.get_meta("scroll_end", false):
		current_parent = current_parent.get_parent().get_parent()

func _scroll_container(parts: PackedStringArray) -> void:
	# scroll_container[x,y;w,h;name;orientation;factor]
	if parts.size() < 2:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_add(sc, _pos(v), _geom(g))
	var inner := Control.new()
	inner.custom_minimum_size = Vector2(_geom(g).x, _geom(g).y * 3)
	inner.set_meta("scroll_end", true)
	sc.add_child(inner)
	container_stack.push_back(pos_offset)
	pos_offset = Vector2.ZERO
	current_parent = inner

func _bgcolor(parts: PackedStringArray) -> void:
	# bgcolor[color;fullscreen;fbgcolor]
	if parts.size() >= 1 and parts[0].strip_edges() != "":
		form_bgcolor = parse_color(parts[0], Color(0.13, 0.13, 0.13, 0.9))
		has_form_bgcolor = true
	if parts.size() >= 2:
		var fs := parts[1].strip_edges()
		if fs == "true" or fs == "both":
			fullscreen_bg = form_bgcolor
		if fs == "neither":
			has_form_bgcolor = false
	if parts.size() >= 3 and parts[2].strip_edges() != "":
		fullscreen_bg = parse_color(parts[2], fullscreen_bg)

func _background(parts: PackedStringArray) -> void:
	# background[x,y;w,h;texture;auto_clip] / background9[...;middle]
	if parts.size() < 3:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var tex: Texture2D = item_source.ui_texture(fs_unescape(parts[2])) if item_source else null
	if tex == null:
		return
	var auto_clip := parts.size() >= 4 and parts[3].strip_edges() == "true"
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if auto_clip:
		# fills the whole form, geometry gives an outset in imgsize units
		var out := Vector2(float(g[0]), float(g[1])) * (imgsize if real_coordinates else spacing.x)
		_add(r, -out, root.size + out * 2)
	else:
		_add(r, _pos(v), _geom(g))
	# backgrounds go behind everything added so far
	current_parent.move_child(r, 0)

func _box(parts: PackedStringArray) -> void:
	if parts.size() < 3:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var c := ColorRect.new()
	c.color = parse_color(parts[2], Color(0, 0, 0, 0.5))
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add(c, _pos(v), _geom(g))

func _image(parts: PackedStringArray) -> void:
	# image[x,y;w,h;texture;middle]
	if parts.size() < 3:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var tex: Texture2D = item_source.ui_texture(fs_unescape(parts[2])) if item_source else null
	if tex == null:
		return
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add(r, _pos(v), _geom(g))

func _animated_image(parts: PackedStringArray) -> void:
	# animated_image[x,y;w,h;name;texture;frame_count;frame_duration;frame_start]
	if parts.size() < 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var tex: Texture2D = item_source.ui_texture(fs_unescape(parts[3])) if item_source else null
	if tex == null:
		return
	var frames := maxi(int(parts[4]), 1)
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = Rect2(0, 0, tex.get_width(), tex.get_height() / float(frames))
	var r := TextureRect.new()
	r.texture = at
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add(r, _pos(v), _geom(g))

func _item_image(parts: PackedStringArray) -> void:
	# item_image[x,y;w,h;item name]
	if parts.size() < 3:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var r := TextureRect.new()
	r.texture = item_source.item_icon(fs_unescape(parts[2])) if item_source else null
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add(r, _pos(v), _geom(g))

func _label(parts: PackedStringArray, vertical: bool) -> void:
	# label[x,y;text]
	if parts.size() < 2:
		return
	var v := fs_split(parts[0], ",")
	if v.size() < 2:
		return
	var l := Label.new()
	var text := fs_unescape(parts[1])
	if vertical:
		var t := ""
		for ch in text:
			t += ch + "\n"
		text = t
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", _font_size())
	var p := _pos(v)
	current_parent.add_child(l)
	# real coordinates: y is the vertical centre of the first line; in the
	# old system the text is centred on the slot row starting at y
	var cy := p.y if real_coordinates else p.y + imgsize / 2.0
	l.position = Vector2(p.x, cy - l.get_line_height() / 2.0).floor()

func _hypertext(parts: PackedStringArray) -> void:
	# hypertext[x,y;w,h;name;text]: rendered as plain text, markup stripped
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var rt := RichTextLabel.new()
	var re := RegEx.new()
	re.compile("<[^>]*>")
	rt.text = re.sub(fs_unescape(parts[3]), "", true)
	rt.add_theme_font_size_override("normal_font_size", _font_size())
	rt.scroll_active = true
	_add(rt, _pos(v), _geom(g))

func _button(parts: PackedStringArray, exit: bool, _unused: String) -> void:
	# button[x,y;w,h;name;label]
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 1:
		return
	var b := Button.new()
	var bname := fs_unescape(parts[2])
	var label := fs_unescape(parts[3])
	b.text = label
	b.add_theme_font_size_override("font_size", _font_size())
	var r := _btn_geom(g)
	_add(b, _pos(v) + r.position, r.size)
	_wire_button(b, bname, label, exit)

func _image_button(parts: PackedStringArray, exit: bool) -> void:
	# image_button[x,y;w,h;texture;name;label;noclip;drawborder;pressed]
	if parts.size() < 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var b := Button.new()
	var tex: Texture2D = item_source.ui_texture(fs_unescape(parts[2])) if item_source else null
	var bname := fs_unescape(parts[3])
	var label := fs_unescape(parts[4]) if parts.size() >= 5 else ""
	b.text = label
	b.add_theme_font_size_override("font_size", _font_size())
	if tex:
		b.icon = tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var drawborder := parts.size() < 7 or parts[6].strip_edges() != "false"
	if not drawborder:
		b.flat = true
	_add(b, _pos(v), _geom(g))
	_wire_button(b, bname, label, exit)

func _item_item_icon(item: String) -> Texture2D:
	return item_source.item_icon(item) if item_source else null

func _item_image_button(parts: PackedStringArray) -> void:
	# item_image_button[x,y;w,h;item name;name;label]
	if parts.size() < 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var b := Button.new()
	var bname := fs_unescape(parts[3])
	var label := fs_unescape(parts[4]) if parts.size() >= 5 else ""
	b.text = label
	b.icon = _item_item_icon(fs_unescape(parts[2]))
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_add(b, _pos(v), _geom(g))
	_wire_button(b, bname, label, false)

func _wire_button(b: Button, bname: String, label: String, exit: bool) -> void:
	if tooltips.has(bname):
		b.tooltip_text = tooltips[bname]
	b.pressed.connect(func() -> void:
		submit({bname: label}, exit))

func _field(parts: PackedStringArray, password: bool) -> void:
	# field[x,y;w,h;name;label;default] or field[name;label;default]
	var e := LineEdit.new()
	e.secret = password
	e.add_theme_font_size_override("font_size", _font_size())
	var fname: String
	var label: String
	var def: String
	if parts.size() >= 5:
		var v := fs_split(parts[0], ",")
		var g := fs_split(parts[1], ",")
		if v.size() < 2 or g.size() < 1:
			return
		fname = fs_unescape(parts[2])
		label = fs_unescape(parts[3])
		def = fs_unescape(parts[4])
		var r := _btn_geom(g)
		var p := _pos(v) + r.position
		if label != "":
			var l := Label.new()
			l.text = label
			l.add_theme_font_size_override("font_size", _font_size())
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			current_parent.add_child(l)
			l.position = Vector2(p.x, p.y - _font_size() * 1.5).floor()
		_add(e, p, r.size)
	elif parts.size() >= 3:
		fname = fs_unescape(parts[0])
		label = fs_unescape(parts[1])
		def = fs_unescape(parts[2])
		var y := 40.0 + fields.size() * 60.0
		if label != "":
			var l := Label.new()
			l.text = label
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			current_parent.add_child(l)
			l.position = Vector2(20, y - 24)
		_add(e, Vector2(20, y), Vector2(root.size.x - 40, 32))
	else:
		return
	e.text = def
	fields[fname] = e
	e.text_submitted.connect(func(_t: String) -> void:
		var quit: bool = field_close_on_enter.get(fname, true)
		submit({"key_enter": "true", "key_enter_field": fname}, quit))

func _textarea(parts: PackedStringArray) -> void:
	# textarea[x,y;w,h;name;label;default]
	if parts.size() < 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var fname := fs_unescape(parts[2])
	var label := fs_unescape(parts[3])
	var p := _pos(v)
	if label != "":
		var l := Label.new()
		l.text = label
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		current_parent.add_child(l)
		l.position = Vector2(p.x, p.y - _font_size() * 1.5).floor()
	if fname == "":
		var rt := RichTextLabel.new()
		rt.text = fs_unescape(parts[4])
		rt.add_theme_font_size_override("normal_font_size", _font_size())
		_add(rt, p, _geom(g))
		return
	var e := TextEdit.new()
	e.text = fs_unescape(parts[4])
	e.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	e.add_theme_font_size_override("font_size", _font_size())
	_add(e, p, _geom(g))
	fields[fname] = e

func _fcoe(parts: PackedStringArray) -> void:
	if parts.size() >= 2:
		field_close_on_enter[fs_unescape(parts[0])] = parts[1].strip_edges() != "false"

func _checkbox(parts: PackedStringArray) -> void:
	# checkbox[x,y;name;label;selected]
	if parts.size() < 3:
		return
	var v := fs_split(parts[0], ",")
	if v.size() < 2:
		return
	var c := CheckBox.new()
	var cname := fs_unescape(parts[1])
	c.text = fs_unescape(parts[2])
	c.button_pressed = parts.size() >= 4 and parts[3].strip_edges() == "true"
	c.add_theme_font_size_override("font_size", _font_size())
	var p := _pos(v)
	current_parent.add_child(c)
	var cy := p.y if real_coordinates else p.y + imgsize / 2.0
	c.position = Vector2(p.x, cy - c.get_minimum_size().y / 2.0).floor()
	fields[cname] = c
	c.toggled.connect(func(_on: bool) -> void:
		submit({cname: "true" if c.button_pressed else "false"}, false))

func _dropdown(parts: PackedStringArray) -> void:
	# dropdown[x,y;w(,h);name;items;selected idx;index event]
	if parts.size() < 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 1:
		return
	var o := OptionButton.new()
	var dname := fs_unescape(parts[2])
	for it in fs_split(parts[3], ","):
		o.add_item(fs_unescape(it))
	var sel := int(parts[4]) - 1
	if sel >= 0 and sel < o.item_count:
		o.select(sel)
	o.set_meta("index_event", parts.size() >= 6 and parts[5].strip_edges() == "true")
	o.add_theme_font_size_override("font_size", _font_size())
	var size: Vector2
	if g.size() >= 2:
		size = _geom(g)
	else:
		var r := _btn_geom(g)
		size = r.size
	_add(o, _pos(v), size)
	fields[dname] = o
	o.item_selected.connect(func(_i: int) -> void:
		var f := collect_fields()
		submit({dname: f[dname]}, false))

func _textlist(parts: PackedStringArray) -> void:
	# textlist[x,y;w,h;name;items;selected;transparent]
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var il := ItemList.new()
	var lname := fs_unescape(parts[2])
	for it in fs_split(parts[3], ","):
		var t := fs_unescape(it)
		if t.begins_with("#") and t.length() >= 7:
			t = t.substr(7)
		il.add_item(t)
	if parts.size() >= 5 and int(parts[4]) > 0 and int(parts[4]) <= il.item_count:
		il.select(int(parts[4]) - 1)
	il.add_theme_font_size_override("font_size", _font_size())
	_add(il, _pos(v), _geom(g))
	fields[lname] = il
	il.item_selected.connect(func(i: int) -> void:
		submit({lname: "CHG:" + str(i + 1)}, false))
	il.item_activated.connect(func(i: int) -> void:
		submit({lname: "DCL:" + str(i + 1)}, false))

func _tabheader(parts: PackedStringArray) -> void:
	# tabheader[x,y(;w,h);name;caption 1,caption 2,...;current_tab;transparent;draw_border]
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	if v.size() < 2:
		return
	var idx := 1
	var size := Vector2.ZERO
	var g := fs_split(parts[1], ",")
	if g.size() >= 2 and parts.size() >= 5 and not parts[2].contains(","):
		# has geometry
		size = _geom(g)
		idx = 2
	var tname := fs_unescape(parts[idx])
	var tb := TabBar.new()
	for cap in fs_split(parts[idx + 1], ","):
		tb.add_tab(fs_unescape(cap))
	var cur := int(parts[idx + 2]) - 1 if parts.size() > idx + 2 else 0
	if cur >= 0 and cur < tb.tab_count:
		tb.current_tab = cur
	tb.add_theme_font_size_override("font_size", _font_size())
	var p := _pos(v)
	if size == Vector2.ZERO:
		size = Vector2(root.size.x - p.x, _font_size() * 2.2)
	current_parent.add_child(tb)
	tb.position = Vector2(p.x, p.y - size.y).floor()
	tb.size = size
	fields[tname] = tb
	tb.tab_changed.connect(func(i: int) -> void:
		submit({tname: str(i + 1)}, false))

func _list(parts: PackedStringArray) -> void:
	# list[inventory location;list name;x,y;w,h;starting item index]
	if parts.size() < 4:
		return
	var loc := fs_unescape(parts[0])
	var lname := fs_unescape(parts[1])
	var v := fs_split(parts[2], ",")
	var g := fs_split(parts[3], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var start := int(parts[4]) if parts.size() >= 5 and parts[4].strip_edges() != "" else 0
	var cols := int(g[0])
	var rows := int(g[1])
	var slot_size := Vector2(imgsize, imgsize)
	var slot_spacing := (Vector2(imgsize * 0.25, imgsize * 0.25) if real_coordinates
		else Vector2(spacing.x - imgsize, spacing.y - imgsize)) + slot_size
	var base := _pos(v)
	for row in rows:
		for col in cols:
			var i := start + row * cols + col
			var s: FormspecSlot = FormspecSlot.new()
			s.setup(self, loc, lname, i, listcolors)
			s.mouse_filter = Control.MOUSE_FILTER_STOP
			_add(s, base + Vector2(col, row) * slot_spacing, slot_size)
			slots.append(s)

func _listring(parts: PackedStringArray) -> void:
	if parts.size() >= 2:
		list_rings.append({"location": fs_unescape(parts[0]), "listname": fs_unescape(parts[1])})
	elif list_rings.size() == 0 and slots.size() > 0:
		# listring[] with no arguments rings the lists defined so far, in order
		var seen := {}
		for s in slots:
			var key: String = s.location + "|" + s.listname
			if not seen.has(key):
				seen[key] = true
				list_rings.append({"location": s.location, "listname": s.listname})

func _listcolors(parts: PackedStringArray) -> void:
	# listcolors[slot_bg_normal;slot_bg_hover;slot_border;tooltip_bgcolor;tooltip_fontcolor]
	if parts.size() >= 2:
		listcolors["slot_bg"] = parse_color(parts[0], listcolors["slot_bg"])
		listcolors["slot_bg_h"] = parse_color(parts[1], listcolors["slot_bg_h"])
	if parts.size() >= 3:
		listcolors["slot_border"] = parse_color(parts[2], listcolors["slot_border"])
	if parts.size() >= 5:
		listcolors["tooltip_bg"] = parse_color(parts[3], listcolors["tooltip_bg"])
		listcolors["tooltip_fg"] = parse_color(parts[4], listcolors["tooltip_fg"])

func _tooltip(parts: PackedStringArray) -> void:
	# tooltip[element name;text;bgcolor;fontcolor] (area form skipped)
	if parts.size() >= 2 and not parts[0].contains(","):
		tooltips[fs_unescape(parts[0])] = fs_unescape(parts[1])

# model[x,y;w,h;name;mesh;textures;...]: the 3D mesh preview is not rendered
# yet. Drawing nothing leaves the game's own dark panel showing as a black
# void, which reads as broken, so fill the area with a muted placeholder and
# label it with the mesh name. Replace this with a real SubViewport render
# when the entity model path is reachable from the UI.
func _model(parts: PackedStringArray) -> void:
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var panel := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.17, 0.19, 0.85)
	sb.set_corner_radius_all(int(imgsize * 0.06))
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_add(panel, _pos(v), _geom(g))
	var mesh := fs_unescape(parts[3])
	var base := mesh.get_file().get_basename()
	var l := Label.new()
	l.text = base if base != "" else "3D model"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", maxi(int(imgsize * 0.22), 9))
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(l)

func _font_size() -> int:
	return maxi(int(imgsize * 0.32), 10)

# Called by a slot; forwarded to the owner.
func _slot_clicked(loc: String, lname: String, index: int, button: int, shift: bool) -> void:
	slot_clicked.emit(loc, lname, index, button, shift)

# Mouse released over a slot: completes a drag started on another slot.
func _slot_released(loc: String, lname: String, index: int, button: int) -> void:
	slot_released.emit(loc, lname, index, button)

# The next list in the ring after (loc, lname), for shift-click moves; empty if none.
func next_in_ring(loc: String, lname: String) -> Dictionary:
	if list_rings.size() < 2:
		return {}
	for i in list_rings.size():
		var lr: Dictionary = list_rings[i]
		if lr["location"] == loc and lr["listname"] == lname:
			return list_rings[(i + 1) % list_rings.size()]
	return {}


# One inventory slot. Draws the slot background, the item icon, count and
# wear bar, and reports clicks.
class FormspecSlot extends Control:
	var form: Control
	var location: String
	var listname: String
	var index: int
	var colors: Dictionary
	var hovered := false
	var icon: Texture2D
	var item := {}

	func setup(f: Control, loc: String, lname: String, i: int, cols: Dictionary) -> void:
		form = f
		location = loc
		listname = lname
		index = i
		colors = cols
		mouse_entered.connect(func() -> void: hovered = true; queue_redraw())
		mouse_exited.connect(func() -> void: hovered = false; queue_redraw())

	func refresh() -> void:
		item = form.item_source.get_list_item(location, listname, index) if form.item_source else {}
		icon = form.item_source.item_icon(item.get("name", "")) if (form.item_source and item.get("name", "") != "") else null
		tooltip_text = item.get("description", "") if item.get("name", "") != "" else ""
		if tooltip_text == "":
			tooltip_text = item.get("name", "")
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, colors["slot_bg_h"] if hovered else colors["slot_bg"])
		draw_rect(r, colors["slot_border"], false, 1.0)
		if icon:
			var pad := size * 0.1
			draw_texture_rect(icon, Rect2(pad, size - pad * 2), false)
		var count: int = item.get("count", 0)
		if count > 1:
			var fs := maxi(int(size.y * 0.3), 9)
			var f := get_theme_default_font()
			var txt := str(count)
			var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_RIGHT, -1, fs).x
			draw_string(f, Vector2(size.x - w - 2, size.y - 3), txt, HORIZONTAL_ALIGNMENT_RIGHT, -1, fs, Color.WHITE)
		var wear: int = item.get("wear", 0)
		if wear > 0:
			var frac := 1.0 - wear / 65535.0
			var bar := Rect2(Vector2(size.x * 0.1, size.y * 0.85), Vector2(size.x * 0.8 * frac, size.y * 0.08))
			draw_rect(bar, Color(1.0 - frac, frac, 0.1))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton \
				and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if event.pressed:
				form._slot_clicked(location, listname, index, event.button_index, event.shift_pressed)
			else:
				# Releasing over a different slot completes a drag: the press
				# picked the stack up, so this drops it here. Releasing over the
				# same slot is an ordinary click and leaves it on the cursor.
				form._slot_released(location, listname, index, event.button_index)
			accept_event()
