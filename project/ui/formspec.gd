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
var allow_close := true
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
var named_controls := {}             # element name -> focusable/tooltip Control
var focus_name := ""
var focus_force := false
var slots: Array = []                # slot buttons for refresh
# Scroll containers and the scrollbars that drive them. In Luanti a
# scroll_container has no scroll of its own: it is moved by the named
# scrollbar's value times the scroll factor (guiScrollContainer.cpp,
# updateScrolling), so the two have to find each other by name whichever
# order the formspec declares them in.
var scroll_containers := {}          # scrollbar name -> mover Control
var scrollbars := {}                 # scrollbar name -> ScrollBar
var scrollbar_options := {}          # options for the next scrollbar[]
var parent_stack: Array = []         # current_parent to restore at a container end
var building := false                # suppresses field events while _build runs
# style[] and style_type[] declarations, in the order they were parsed. Each
# entry is {states: PackedStringArray, props: Dictionary}; an entry applies
# when every one of its states is active, which is upstream's rule.
var style_by_name := {}              # element name -> Array of entries
var style_by_type := {}              # element type -> Array of entries
var current_element := ""            # the type being built, for style lookup
var table_columns: Array = []        # tablecolumns[] for the next table[]
var table_options := {}              # tableoptions[] for the next table[]
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
		if c is AnimatedFormspecImage:
			out[n] = str((c as AnimatedFormspecImage).current_frame + 1)
		elif c is LineEdit:
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
		elif c is ScrollBar:
			out[n] = "VAL:" + str(int((c as ScrollBar).value))
		elif c is Tree:
			var row := _table_row(c as Tree)
			out[n] = ("CHG:" + str(row)) if row > 0 else ""
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
	allow_close = true
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
	named_controls.clear()
	focus_name = ""
	focus_force = false
	slots.clear()
	scroll_containers.clear()
	scrollbars.clear()
	scrollbar_options = _default_scrollbar_options()
	parent_stack.clear()
	style_by_name.clear()
	style_by_type.clear()
	current_element = ""
	table_columns.clear()
	table_options = {}
	pending_elements.clear()
	skipped.clear()

# scrollbaroptions[] defaults, from parseScrollBarOptions.
static func _default_scrollbar_options() -> Dictionary:
	return {"min": 0, "max": 1000, "smallstep": 10, "largestep": 100,
		"thumbsize": 1, "arrows": "default"}

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
	return strip_enriched(out)

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
			"allow_close":
				allow_close = params.strip_edges() != "false"
			"set_focus", "focus":
				var p := fs_split(params, ";")
				if p.size() >= 1:
					focus_name = fs_unescape(p[0])
					focus_force = p.size() >= 2 and p[1].strip_edges() == "true"
			"no_prepend":
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

# Splits Luanti's enriched-text escape sequences into colour runs, for
# anything that draws its own text instead of handing it to a Label:
# HUD text, item tooltips, chat. `core.get_color_escape_sequence` writes
# `ESC(c@#rrggbb)`; `core.colorize` wraps it with `ESC(c@)` to reset. A
# translated string arrives as `ESC(T@textdomain)...ESCE`, from
# `core.translate`: Goanna has no client-side translation catalogue, so,
# like an upstream client missing the language pack, the marked text is
# kept as-is rather than translated (docs/lua_api.md, "Escape sequences").
static func parse_enriched_runs(s: String, default_color: Color) -> Array:
	var runs := []
	var cur := default_color
	var buf := ""
	var i := 0
	var n := s.length()
	while i < n:
		if s.unicode_at(i) == 0x1b:
			if buf != "":
				runs.append({"text": buf, "color": cur})
				buf = ""
			i += 1
			if i >= n:
				break
			var seq := ""
			if s[i] == "(":
				i += 1
				var start := i
				while i < n and s[i] != ")":
					if s[i] == "\\":
						i += 1
					i += 1
				seq = s.substr(start, i - start)
				if i < n:
					i += 1  # skip ')'
			else:
				seq = s[i]
				i += 1
			var parts := seq.split("@")
			if parts[0] == "c":
				cur = parse_color(parts[1], default_color) if parts.size() > 1 and parts[1] != "" else default_color
			# "T" (translation start), "E" (its end) and "F" (an argument's
			# start) carry no colour of their own; leave cur as it is.
		else:
			buf += s[i]
			i += 1
	if buf != "":
		runs.append({"text": buf, "color": cur})
	return runs

# The plain-text form of parse_enriched_runs, for contexts (tooltips, chat)
# that can only show one colour.
static func strip_enriched(s: String) -> String:
	var out := ""
	for run in parse_enriched_runs(s, Color.WHITE):
		out += run["text"]
	return out

# --- building --------------------------------------------------------------

func _build() -> void:
	# Named tooltips apply regardless of whether they appear before or after
	# their target element. Area tooltips still build in normal element order.
	for el in pending_elements:
		if el[0] == "tooltip":
			var tooltip_parts := fs_split(el[1], ";")
			if tooltip_parts.size() >= 2 and not tooltip_parts[0].contains(","):
				tooltips[fs_unescape(tooltip_parts[0])] = fs_unescape(tooltip_parts[1])
	# a fullscreen tint behind the form, if asked for
	add_child(root)
	building = true
	for el in pending_elements:
		var name: String = el[0]
		var parts := fs_split(el[1], ";")
		current_element = name
		match name:
			"style": _style(parts, false)
			"style_type": _style(parts, true)
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
			"button", "button_exit", "button_url", "button_url_exit", "button_key":
				_button(parts, name.ends_with("_exit"), name)
			"image_button", "image_button_exit": _image_button(parts, name.ends_with("_exit"))
			"item_image_button": _item_image_button(parts)
			"field", "pwdfield": _field(parts, name == "pwdfield")
			"textarea": _textarea(parts)
			"field_close_on_enter": _fcoe(parts)
			# Android only: it makes the on-screen keyboard's Done button
			# simulate Enter. A desktop client has nothing to do with it.
			"field_enter_after_edit": pass
			"checkbox": _checkbox(parts)
			"dropdown": _dropdown(parts)
			"textlist": _textlist(parts)
			"table": _table(parts)
			"tablecolumns": _tablecolumns(parts)
			"tableoptions": _tableoptions(parts)
			"tabheader": _tabheader(parts)
			"list": _list(parts)
			"listring": _listring(parts)
			"listcolors": _listcolors(parts)
			"tooltip": _tooltip(parts)
			"model": _model(parts)
			"scrollbar": _scrollbar(parts)
			"scrollbaroptions": _scrollbaroptions(parts)
			_:
				skipped[name] = skipped.get(name, 0) + 1
	building = false
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
	_apply_focus()

func _add(c: Control, pos: Vector2, size: Vector2) -> void:
	c.position = pos.floor()
	c.size = size.floor()
	current_parent.add_child(c)

func _register_named_control(name: String, control: Control) -> void:
	if name == "":
		return
	named_controls[name] = control
	control.set_meta("formspec_name", name)
	if tooltips.has(name):
		control.tooltip_text = tooltips[name]

func _apply_focus() -> void:
	if focus_name == "":
		return
	var target: Control = named_controls.get(focus_name)
	if target == null:
		target = fields.get(focus_name)
	if target != null and (focus_force or not target.has_focus()):
		target.grab_focus()

func _container(parts: PackedStringArray) -> void:
	var v := fs_split(parts[0], ",") if parts.size() >= 1 else PackedStringArray()
	if v.size() < 2:
		return
	container_stack.push_back(pos_offset)
	pos_offset += Vector2(float(v[0]), float(v[1]))

func _container_end() -> void:
	if container_stack.size() > 0:
		pos_offset = container_stack.pop_back()
	if current_parent.get_meta("scroll_mover", false) and parent_stack.size() > 0:
		current_parent = parent_stack.pop_back()

# scroll_container[x,y;w,h;scrollbar name;orientation;scroll factor;content padding]
#
# Built as upstream builds it (parseScrollContainer): a clipper at the given
# rectangle, and inside it a mover holding the contents, which the scrollbar
# slides. Positions and sizes here are always real coordinates, whatever the
# form asked for, because upstream calls getRealCoordinate* unconditionally.
func _scroll_container(parts: PackedStringArray) -> void:
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var sname := fs_unescape(parts[2])
	var orientation := fs_unescape(parts[3]).strip_edges()
	var vertical := orientation != "horizontal"
	var factor := 0.1
	if parts.size() >= 5 and parts[4].strip_edges() != "":
		factor = float(parts[4])
	# The sign is upstream's: a positive scroll factor moves the contents up.
	factor = -factor * imgsize
	var size := Vector2(float(g[0]), float(g[1])) * imgsize
	var clip := Control.new()
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_PASS
	clip.position = (Vector2(float(v[0]) + pos_offset.x, float(v[1]) + pos_offset.y) * imgsize).floor()
	clip.size = size.floor()
	current_parent.add_child(clip)
	var mover := Control.new()
	mover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mover.size = size.floor()
	mover.set_meta("scroll_mover", true)
	mover.set_meta("vertical", vertical)
	mover.set_meta("factor", factor)
	mover.set_meta("view", size.y if vertical else size.x)
	if parts.size() >= 7 and parts[6].strip_edges() != "":
		mover.set_meta("content_padding", float(parts[6]) * imgsize)
	clip.add_child(mover)
	scroll_containers[sname] = mover
	# The mouse wheel over the container drives its scrollbar, as
	# GUIScrollContainer::OnEvent does.
	clip.gui_input.connect(func(event: InputEvent) -> void:
		_scroll_container_wheel(sname, event))
	parent_stack.push_back(current_parent)
	container_stack.push_back(pos_offset)
	pos_offset = Vector2.ZERO
	current_parent = mover
	if scrollbars.has(sname):
		_link_scroll(sname)

func _scroll_container_wheel(sname: String, event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var bar: ScrollBar = scrollbars.get(sname)
	if bar == null:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		bar.value -= bar.step
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		bar.value += bar.step
	else:
		return
	get_viewport().set_input_as_handled()

# Joins a scrollbar to the container of the same name, and applies the
# content-padding sizing if the container asked for it. Called from whichever
# of the two is built second.
func _link_scroll(sname: String) -> void:
	var mover: Control = scroll_containers.get(sname)
	var bar: ScrollBar = scrollbars.get(sname)
	if mover == null or bar == null:
		return
	var vertical: bool = mover.get_meta("vertical", true)
	var factor: float = mover.get_meta("factor", -0.1)
	if mover.has_meta("content_padding") and factor != 0.0:
		# GUIScrollContainer::setScrollBar: derive max and thumb from how much
		# content there actually is, rather than from scrollbaroptions.
		var view: float = mover.get_meta("view", 1.0)
		var extent := 0.0
		for c in mover.get_children():
			if c is Control:
				var e: float = (c as Control).position.y + (c as Control).size.y if vertical 					else (c as Control).position.x + (c as Control).size.x
				extent = maxf(extent, e)
		var total: float = float(mover.get_meta("content_padding")) + extent
		var hidden := maxf(0.0, total - view)
		var span := ceilf(hidden / absf(factor))
		bar.min_value = 0
		bar.page = maxf(span * view / maxf(total - view, 1.0), 1.0) if span > 0 else 1.0
		bar.max_value = span + bar.page
	_apply_scroll(sname)

func _apply_scroll(sname: String) -> void:
	var mover: Control = scroll_containers.get(sname)
	var bar: ScrollBar = scrollbars.get(sname)
	if mover == null or bar == null:
		return
	var offset: float = bar.value * float(mover.get_meta("factor", -0.1))
	if bool(mover.get_meta("vertical", true)):
		mover.position = Vector2(mover.position.x, floorf(offset))
	else:
		mover.position = Vector2(floorf(offset), mover.position.y)

# scrollbaroptions[opt1;opt2;...]: options for every following scrollbar[].
func _scrollbaroptions(parts: PackedStringArray) -> void:
	for raw in parts:
		var p := fs_unescape(raw).strip_edges()
		var eq := p.find("=")
		if eq < 0:
			continue
		var key := p.substr(0, eq).strip_edges()
		var value := p.substr(eq + 1).strip_edges()
		match key:
			"min", "max":
				scrollbar_options[key] = int(value)
			"smallstep":
				scrollbar_options[key] = int(value) if int(value) >= 0 else 10
			"largestep":
				scrollbar_options[key] = int(value) if int(value) >= 0 else 100
			"thumbsize":
				scrollbar_options[key] = maxi(int(value), 1)
			"arrows":
				scrollbar_options[key] = value

# scrollbar[x,y;w,h;orientation;name;value]
func _scrollbar(parts: PackedStringArray) -> void:
	if parts.size() < 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var vertical := fs_unescape(parts[2]).strip_edges() == "vertical"
	var sname := fs_unescape(parts[3])
	var bar: ScrollBar = VScrollBar.new() if vertical else HScrollBar.new()
	var lo: int = scrollbar_options["min"]
	var hi: int = scrollbar_options["max"]
	# Godot's Range reserves `page` at the top of its span, so the reachable
	# values are [min_value, max_value - page]. Adding the thumb to the max is
	# what keeps the value range the [min, max] the formspec asked for, and it
	# leaves the thumb spanning thumbsize units of the bar, as documented.
	bar.page = float(scrollbar_options["thumbsize"])
	bar.min_value = lo
	bar.max_value = maxf(float(hi) + bar.page, float(lo) + bar.page)
	bar.step = maxf(float(scrollbar_options["smallstep"]), 1.0)
	bar.value = clampf(float(int(parts[4])), lo, maxf(hi, lo))
	# max == min disables the scrollbar (scrollbaroptions documentation).
	if hi == lo:
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.modulate = Color(1, 1, 1, 0.4)
	var size := _geom(g)
	if not real_coordinates:
		size = Vector2(float(g[0]) * spacing.x, float(g[1]) * spacing.y)
	_add(bar, _pos(v), size)
	scrollbars[sname] = bar
	fields[sname] = bar
	_register_named_control(sname, bar)
	_apply_style(bar, sname)
	# Upstream sends a change event for every scrollbar, including one that
	# only drives a container: Mineclonia's creative inventory reads it and
	# deliberately returns without resending the form (mcl_inventory).
	bar.value_changed.connect(func(_val: float) -> void:
		_apply_scroll(sname)
		if not building:
			submit({sname: "CHG:" + str(int(bar.value))}, false))
	if scroll_containers.has(sname):
		_link_scroll(sname)

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
	var middle := parts[4] if parts.size() >= 5 else ""
	var r := _texture_rect(tex, middle)
	if auto_clip:
		# fills the whole form, geometry gives an outset in imgsize units
		var out := Vector2(float(g[0]), float(g[1])) * (imgsize if real_coordinates else spacing.x)
		_add(r, -out, root.size + out * 2)
	else:
		_add(r, _pos(v), _geom(g))
	# backgrounds go behind everything added so far
	current_parent.move_child(r, 0)

func _middle_margins(value: String, tex: Texture2D) -> Vector4:
	if value.strip_edges() == "":
		return Vector4.ZERO
	var values := fs_split(value, ",")
	var left: int
	var top: int
	var right_edge: int
	var bottom_edge: int
	if values.size() == 1:
		left = int(values[0])
		top = left
		right_edge = -left
		bottom_edge = -top
	elif values.size() == 2:
		left = int(values[0])
		top = int(values[1])
		right_edge = -left
		bottom_edge = -top
	elif values.size() == 4:
		left = int(values[0])
		top = int(values[1])
		right_edge = int(values[2])
		bottom_edge = int(values[3])
	else:
		return Vector4.ZERO
	var right := -right_edge if right_edge < 0 else tex.get_width() - right_edge
	var bottom := -bottom_edge if bottom_edge < 0 else tex.get_height() - bottom_edge
	return Vector4(maxi(left, 0), maxi(top, 0), maxi(right, 0), maxi(bottom, 0))

func _texture_rect(tex: Texture2D, middle: String) -> Control:
	var margins := _middle_margins(middle, tex)
	if margins != Vector4.ZERO:
		var nine := NinePatchRect.new()
		nine.texture = tex
		nine.patch_margin_left = int(margins.x)
		nine.patch_margin_top = int(margins.y)
		nine.patch_margin_right = int(margins.z)
		nine.patch_margin_bottom = int(margins.w)
		nine.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		nine.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return nine
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect

func _box(parts: PackedStringArray) -> void:
	if parts.size() < 3:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	# A box takes its style only when the element itself left the colour
	# unspecified, which is the note against box in lua_api.md.
	var st := _style_for("", "default") if parts[2].strip_edges() == "" else {}
	if _has_style(st, "colors") or _has_style(st, "bordercolors") or _has_style(st, "borderwidths"):
		var panel := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = parse_color(fs_split(String(st.get("colors", "black")), ",")[0], Color.BLACK)
		var bw := int(String(st.get("borderwidths", "0")).split(",")[0])
		if bw != 0:
			# A negative width draws the border inside the box, a positive one
			# outside; Godot only grows inward, so the extent is what carries.
			sb.set_border_width_all(absi(bw))
			sb.border_color = parse_color(fs_split(String(st.get("bordercolors", "black")), ",")[0], Color.BLACK)
		panel.add_theme_stylebox_override("panel", sb)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_add(panel, _pos(v), _geom(g))
		return
	var c := ColorRect.new()
	c.color = parse_color(parts[2], Color(0, 0, 0, 0.5))
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add(c, _pos(v), _geom(g))

func _image(parts: PackedStringArray) -> void:
	# image[x,y;texture] or image[x,y;w,h;texture;middle]
	if parts.size() < 2:
		return
	var v := fs_split(parts[0], ",")
	if v.size() < 2:
		return
	var has_geometry := parts.size() >= 3
	var texture_index := 2 if has_geometry else 1
	var tex: Texture2D = item_source.ui_texture(fs_unescape(parts[texture_index])) if item_source else null
	if tex == null:
		return
	var middle := parts[3] if parts.size() >= 4 else ""
	var r := _texture_rect(tex, middle)
	var size := Vector2(tex.get_width(), tex.get_height())
	if has_geometry:
		var g := fs_split(parts[1], ",")
		if g.size() < 2:
			return
		size = _geom(g)
	_add(r, _pos(v), size)

func _animated_image(parts: PackedStringArray) -> void:
	# animated_image[x,y;w,h;name;texture;frame_count;frame_duration;frame_start]
	if parts.size() < 6:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var tex: Texture2D = item_source.ui_texture(fs_unescape(parts[3])) if item_source else null
	if tex == null:
		return
	var frames := maxi(int(parts[4]), 1)
	var frame_duration := maxi(int(parts[5]), 1)
	var frame_start := clampi(int(parts[6]) - 1, 0, frames - 1) if parts.size() >= 7 else 0
	var margins := _middle_margins(parts[7], tex) if parts.size() >= 8 else Vector4.ZERO
	var r := AnimatedFormspecImage.new()
	r.setup(tex, frames, frame_duration, frame_start, margins)
	_add(r, _pos(v), _geom(g))
	var aname := fs_unescape(parts[2])
	fields[aname] = r
	_register_named_control(aname, r)

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
	_apply_style(l, "")
	var cy := p.y if real_coordinates else p.y + imgsize / 2.0
	l.position = Vector2(p.x, cy - l.get_line_height() / 2.0).floor()

# The default tag styles, from ParsedText::ParsedText in guiHyperText.cpp.
# Sizes there are pixels against a 16 pixel root, so they are carried here as
# a ratio of whatever this form's own text size works out to be.
const MARKUP_TAGS := {
	"action": {"color": "#0000FF", "underline": "true"},
	"b": {"bold": "true"},
	"i": {"italic": "true"},
	"u": {"underline": "true"},
	"mono": {"font": "mono"},
	"normal": {"size": "16"},
	"big": {"size": "24"},
	"bigger": {"size": "36"},
	"center": {"halign": "center"},
	"justify": {"halign": "justify"},
	"left": {"halign": "left"},
	"right": {"halign": "right"},
}
const MARKUP_ROOT_SIZE := 16.0

# hypertext[x,y;w,h;name;text]
func _hypertext(parts: PackedStringArray) -> void:
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var hname := fs_unescape(parts[2])
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = false
	rt.scroll_active = true
	rt.selection_enabled = true
	rt.add_theme_font_size_override("normal_font_size", _font_size())
	rt.add_theme_color_override("default_color", Color.html("EEEEEE"))
	_add(rt, _pos(v), _geom(g))
	_register_named_control(hname, rt)
	# <action> sends "action:<name>" under the element's own field name, and
	# may carry a url, which is offered rather than opened (see _offer_url).
	rt.meta_clicked.connect(func(meta: Variant) -> void:
		var m := String(meta)
		var bar := m.find("\u0001")
		if bar >= 0:
			_offer_url(m.substr(bar + 1))
			m = m.substr(0, bar)
		if m != "":
			submit({hname: "action:" + m}, false))
	_render_markup(rt, fs_unescape(parts[3]))

# Walks Luanti's hypertext markup and drives the RichTextLabel directly
# rather than translating to BBCode: <img> and <item> name client media and
# item stacks, which BBCode has no way to address.
func _render_markup(rt: RichTextLabel, text: String) -> void:
	var tags := {}
	for k in MARKUP_TAGS:
		tags[k] = (MARKUP_TAGS[k] as Dictionary).duplicate()
	var open_stack: Array = []          # pops owed to each open tag
	var i := 0
	var run := ""
	var n := text.length()
	while i < n:
		var ch := text[i]
		if ch == "\\" and i + 1 < n:
			run += text[i + 1]
			i += 2
			continue
		if ch != "<":
			run += ch
			i += 1
			continue
		var close := _markup_tag_end(text, i)
		if close < 0:
			run += ch
			i += 1
			continue
		if run != "":
			rt.add_text(run)
			run = ""
		_markup_tag(rt, text.substr(i + 1, close - i - 1), tags, open_stack)
		i = close + 1
	if run != "":
		rt.add_text(run)
	while open_stack.size() > 0:
		for _p in range(int(open_stack.pop_back())):
			rt.pop()

# The index of the > that closes the tag opening at `start`, skipping any
# inside a quoted attribute value. Returns -1 if the tag is never closed.
static func _markup_tag_end(text: String, start: int) -> int:
	var i := start + 1
	var quote := ""
	while i < text.length():
		var c := text[i]
		if c == "\\":
			i += 2
			continue
		if quote != "":
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == ">":
			return i
		i += 1
	return -1

# One tag body, without its angle brackets.
func _markup_tag(rt: RichTextLabel, body: String, tags: Dictionary, open_stack: Array) -> void:
	body = body.strip_edges()
	if body == "":
		return
	if body.begins_with("/"):
		if open_stack.size() > 0:
			for _p in range(int(open_stack.pop_back())):
				rt.pop()
		return
	var space := body.find(" ")
	var name := (body.substr(0, space) if space >= 0 else body).strip_edges().to_lower()
	var attrs := _markup_attrs(body.substr(space + 1)) if space >= 0 else {}
	match name:
		"global":
			# Applies to the element as a whole rather than to a span.
			if attrs.has("color"):
				rt.add_theme_color_override("default_color",
					parse_color(String(attrs["color"]), Color.html("EEEEEE")))
			if attrs.has("size"):
				rt.add_theme_font_size_override("normal_font_size", _markup_size(String(attrs["size"])))
			if attrs.has("background"):
				var sb := StyleBoxFlat.new()
				sb.bg_color = Color.TRANSPARENT if String(attrs["background"]) == "none" \
					else parse_color(String(attrs["background"]), Color.TRANSPARENT)
				if attrs.has("margin"):
					var m := float(attrs["margin"])
					sb.content_margin_left = m
					sb.content_margin_right = m
					sb.content_margin_top = m
					sb.content_margin_bottom = m
				rt.add_theme_stylebox_override("normal", sb)
			return
		"tag":
			# Defines or redefines a tag, which later spans can then open.
			var tname := String(attrs.get("name", "")).to_lower()
			if tname != "":
				var style: Dictionary = tags.get(tname, {}).duplicate()
				for k in ["color", "hovercolor", "size", "font"]:
					if attrs.has(k):
						style[k] = attrs[k]
				tags[tname] = style
			return
		"img", "item":
			_markup_image(rt, name, attrs)
			return
	# An opening span: either a style tag or one of the defined tags.
	var style: Dictionary = attrs if name == "style" else tags.get(name, {})
	if style.is_empty() and name != "style":
		# An unknown tag renders as nothing, as upstream's parser does; keep
		# the stack balanced so its closing tag does not pop someone else.
		open_stack.append(0)
		return
	var pushes := 0
	if String(style.get("halign", "")) != "":
		match String(style["halign"]):
			"center": rt.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER)
			"right": rt.push_paragraph(HORIZONTAL_ALIGNMENT_RIGHT)
			"justify": rt.push_paragraph(HORIZONTAL_ALIGNMENT_FILL)
			_: rt.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
		pushes += 1
	if name == "action":
		var meta := String(attrs.get("name", ""))
		if attrs.has("url"):
			meta += "\u0001" + String(attrs["url"])
		rt.push_meta(meta)
		pushes += 1
	if String(style.get("color", "")) != "":
		rt.push_color(parse_color(String(style["color"]), Color.html("EEEEEE")))
		pushes += 1
	if String(style.get("size", "")) != "":
		rt.push_font_size(_markup_size(String(style["size"])))
		pushes += 1
	if String(style.get("font", "")) == "mono":
		var mono := rt.get_theme_font("mono_font")
		if mono != null:
			rt.push_font(mono)
			pushes += 1
	if String(style.get("bold", "")) == "true":
		rt.push_bold()
		pushes += 1
	if String(style.get("italic", "")) == "true":
		rt.push_italics()
		pushes += 1
	if String(style.get("underline", "")) == "true":
		rt.push_underline()
		pushes += 1
	open_stack.append(pushes)

# <img name=... width=... height=...> and the same for <item>, whose name is
# an item string rather than a texture.
func _markup_image(rt: RichTextLabel, kind: String, attrs: Dictionary) -> void:
	if item_source == null:
		return
	var iname := String(attrs.get("name", ""))
	if iname == "":
		return
	var tex: Texture2D = item_source.item_icon(iname) if kind == "item" \
		else item_source.ui_texture(iname)
	if tex == null:
		return
	var w := int(attrs.get("width", 0))
	var h := int(attrs.get("height", 0))
	# Only one of the two given keeps the texture's aspect, which is what
	# lua_api.md asks for; neither given uses the texture's own size.
	if w > 0 and h <= 0:
		h = int(round(w * float(tex.get_height()) / maxf(float(tex.get_width()), 1.0)))
	elif h > 0 and w <= 0:
		w = int(round(h * float(tex.get_width()) / maxf(float(tex.get_height()), 1.0)))
	if w > 0 and h > 0:
		rt.add_image(tex, w, h)
	else:
		rt.add_image(tex)

# A markup size is in the same pixels as the 16 pixel root, so it scales with
# whatever this form's text size is.
func _markup_size(value: String) -> int:
	var raw := float(value)
	if raw <= 0.0:
		return _font_size()
	return maxi(int(round(raw * _font_size() / MARKUP_ROOT_SIZE)), 1)

# key=value pairs, values optionally quoted with " or ', with a backslash
# escaping the next character.
static func _markup_attrs(text: String) -> Dictionary:
	var out := {}
	var i := 0
	var n := text.length()
	while i < n:
		while i < n and text[i] == " ":
			i += 1
		var key := ""
		while i < n and text[i] != "=" and text[i] != " ":
			key += text[i]
			i += 1
		while i < n and text[i] == " ":
			i += 1
		if i >= n or text[i] != "=":
			if key != "":
				out[key.to_lower()] = ""
			continue
		i += 1
		while i < n and text[i] == " ":
			i += 1
		var value := ""
		if i < n and (text[i] == "\"" or text[i] == "'"):
			var quote := text[i]
			i += 1
			while i < n and text[i] != quote:
				if text[i] == "\\" and i + 1 < n:
					i += 1
				value += text[i]
				i += 1
			i += 1
		else:
			while i < n and text[i] != " ":
				if text[i] == "\\" and i + 1 < n:
					i += 1
				value += text[i]
				i += 1
		if key != "":
			out[key.to_lower()] = value
	return out

# button[x,y;w,h;name;label], and the button_exit, button_url, button_url_exit
# and button_key variants, which upstream also builds through parseButton.
func _button(parts: PackedStringArray, exit: bool, kind: String) -> void:
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
	if kind.begins_with("button_url") and parts.size() >= 5:
		b.set_meta("url", fs_unescape(parts[4]))
	_wire_button(b, bname, label, exit)
	_apply_style(b, bname)

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
	_apply_style(b, bname)

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
	_apply_style(b, bname)

func _wire_button(b: Button, bname: String, label: String, exit: bool) -> void:
	_register_named_control(bname, b)
	b.pressed.connect(func() -> void:
		if b.has_meta("url"):
			_offer_url(String(b.get_meta("url")))
		submit({bname: label}, exit))

# A button_url sends its fields like any other button and additionally offers
# the address. In game, upstream asks first (showOpenURLDialog) rather than
# opening straight away, so a form cannot make the client follow a link on
# its own. Only http and https are offered, which is what lua_api.md requires
# of the element.
func _offer_url(url: String) -> void:
	var lower := url.strip_edges().to_lower()
	if not (lower.begins_with("http://") or lower.begins_with("https://")):
		print("formspec: refusing a button_url that is not http or https: ", url)
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Open link"
	dialog.dialog_text = "This form wants to open:\n\n" + url
	dialog.ok_button_text = "Open"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void: OS.shell_open(url))
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.popup_centered()

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
	_register_named_control(fname, e)
	_apply_style(e, fname)
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
	_register_named_control(fname, e)
	_apply_style(e, fname)

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
	_register_named_control(cname, c)
	_apply_style(c, cname)
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
	_register_named_control(dname, o)
	_apply_style(o, dname)
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
	_register_named_control(lname, il)
	_apply_style(il, lname)
	il.item_selected.connect(func(i: int) -> void:
		submit({lname: "CHG:" + str(i + 1)}, false))
	il.item_activated.connect(func(i: int) -> void:
		submit({lname: "DCL:" + str(i + 1)}, false))

# tableoptions[opt 1;opt 2;...]: colours and border for every following table.
func _tableoptions(parts: PackedStringArray) -> void:
	for raw in parts:
		var p := fs_unescape(raw).strip_edges()
		var eq := p.find("=")
		if eq < 0:
			continue
		table_options[p.substr(0, eq).strip_edges()] = p.substr(eq + 1).strip_edges()

# tablecolumns[type,opt=val,...;type,opt=val,...]: the column layout for every
# following table. Only the text and image types are columns the player sees.
# The tint and indent types consume a cell each and change how the next
# visible cell is drawn, so they are read but never given a column.
func _tablecolumns(parts: PackedStringArray) -> void:
	table_columns.clear()
	for raw in parts:
		var bits := fs_split(raw, ",")
		if bits.size() == 0:
			continue
		var col := {"type": fs_unescape(bits[0]).strip_edges(), "opts": {}}
		for i in range(1, bits.size()):
			var o := fs_unescape(bits[i])
			var eq := o.find("=")
			if eq < 0:
				continue
			col["opts"][o.substr(0, eq).strip_edges()] = o.substr(eq + 1).strip_edges()
		if col["type"] != "":
			table_columns.append(col)

# table[x,y;w,h;name;cell 1,cell 2,...;selected idx]
#
# Cells run row-major across the declared columns. Without a tablecolumns[]
# the table is a single text column, which is what upstream falls back to.
func _table(parts: PackedStringArray) -> void:
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var tname := fs_unescape(parts[2])
	var cells := fs_split(parts[3], ",")
	var cols: Array = table_columns.duplicate(true) if not table_columns.is_empty() \
		else [{"type": "text", "opts": {}}]
	var visible: Array = []
	for c in cols:
		if c["type"] == "text" or c["type"] == "image":
			visible.append(c)
	if visible.is_empty():
		visible = [{"type": "text", "opts": {}}]
	var has_tree := false
	var has_indent := false
	for c in cols:
		if c["type"] == "tree":
			has_tree = true
		elif c["type"] == "indent":
			has_indent = true

	var t := Tree.new()
	t.columns = visible.size()
	t.hide_root = true
	t.column_titles_visible = false
	t.select_mode = Tree.SELECT_ROW
	t.allow_reselect = true
	# Only a tree column offers folding. An indent column builds the same
	# hierarchy but is not meant to be opened or closed.
	t.hide_folding = has_indent and not has_tree
	t.add_theme_font_size_override("font_size", _font_size())
	_apply_table_options(t)
	var em := float(_font_size())
	for i in visible.size():
		var opts: Dictionary = visible[i]["opts"]
		if opts.has("width"):
			t.set_column_custom_minimum_width(i, int(float(opts["width"]) * em))
		t.set_column_expand(i, not opts.has("width"))

	var root_item := t.create_item()
	var opendepth := int(table_options.get("opendepth", "0"))
	var depth_items := {0: root_item}
	var rows := 0
	var i := 0
	while i < cells.size():
		var depth := 0
		var pending := Color.TRANSPARENT
		var has_pending := false
		var vals: Array = []
		var icons: Array = []
		var col_i := 0
		# Read one row: every declared column consumes one cell.
		for c in cols:
			var cell := fs_unescape(cells[i]) if i < cells.size() else ""
			i += 1
			match c["type"]:
				"color":
					pending = parse_color(cell, Color.WHITE)
					has_pending = true
				"indent", "tree":
					depth = maxi(int(cell), 0)
				"image":
					vals.append("")
					icons.append(String(c["opts"].get(cell, "")))
					col_i += 1
				_:
					vals.append(cell)
					icons.append("")
					col_i += 1
		rows += 1
		var parent: TreeItem = depth_items.get(depth, root_item)
		var item := t.create_item(parent)
		item.set_meta("row", rows)
		depth_items[depth + 1] = item
		if has_tree:
			item.collapsed = depth + 1 >= opendepth
		for ci in visible.size():
			if ci >= vals.size():
				break
			item.set_text(ci, String(vals[ci]))
			var opts: Dictionary = visible[ci]["opts"]
			match String(opts.get("align", "left")):
				"center": item.set_text_alignment(ci, HORIZONTAL_ALIGNMENT_CENTER)
				"right": item.set_text_alignment(ci, HORIZONTAL_ALIGNMENT_RIGHT)
			if opts.has("tooltip"):
				item.set_tooltip_text(ci, String(opts["tooltip"]))
			if has_pending:
				item.set_custom_color(ci, pending)
			elif table_options.has("color"):
				item.set_custom_color(ci, parse_color(String(table_options["color"]), Color.WHITE))
			if String(icons[ci]) != "" and item_source:
				var tex: Texture2D = item_source.ui_texture(String(icons[ci]))
				if tex:
					item.set_icon(ci, tex)

	_add(t, _pos(v), _geom(g))
	var sel := int(parts[4]) if parts.size() >= 5 and parts[4].strip_edges() != "" else 0
	if sel > 0:
		_select_table_row(t, sel)
	fields[tname] = t
	_register_named_control(tname, t)
	_apply_style(t, tname)
	t.item_selected.connect(func() -> void:
		submit({tname: "CHG:" + str(_table_row(t))}, false))
	t.item_activated.connect(func() -> void:
		submit({tname: "DCL:" + str(_table_row(t))}, false))

func _apply_table_options(t: Tree) -> void:
	if table_options.is_empty():
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = parse_color(String(table_options.get("background", "#000000")), Color.BLACK)
	if String(table_options.get("border", "true")) != "false":
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 0.25)
	t.add_theme_stylebox_override("panel", sb)
	if table_options.has("highlight"):
		var hl := StyleBoxFlat.new()
		hl.bg_color = parse_color(String(table_options["highlight"]), Color("466432"))
		t.add_theme_stylebox_override("selected", hl)
		t.add_theme_stylebox_override("selected_focus", hl)
	if table_options.has("highlight_text"):
		t.add_theme_color_override("font_selected_color",
			parse_color(String(table_options["highlight_text"]), Color.WHITE))

# The 1-based row the table reports, which is the row it was built from
# rather than its position among the currently expanded items.
static func _table_row(t: Tree) -> int:
	var item := t.get_selected()
	return int(item.get_meta("row", 0)) if item != null else 0

static func _select_table_row(t: Tree, row: int) -> void:
	var item := t.get_root()
	while item != null:
		if int(item.get_meta("row", 0)) == row:
			item.select(0)
			return
		item = item.get_next_in_tree()

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
	_register_named_control(tname, tb)
	_apply_style(tb, tname)
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
	# style[] can resize the slots and the gaps between them, in coordinates.
	# A list carries no element name upstream (parseList builds its FieldSpec
	# with an empty fname), so only style_type[list] and style[*] reach it.
	var st := _style_for("", "default")
	if _has_style(st, "size"):
		var sv := fs_split(String(st["size"]), ",")
		if sv.size() >= 2:
			var gap := slot_spacing - slot_size
			slot_size = Vector2(float(sv[0]), float(sv[1])) * imgsize
			slot_spacing = slot_size + gap
	if _has_style(st, "spacing"):
		var pv := fs_split(String(st["spacing"]), ",")
		if pv.size() >= 2:
			slot_spacing = slot_size + Vector2(float(pv[0]), float(pv[1])) * imgsize
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
	# tooltip[element name;text;bgcolor;fontcolor] or
	# tooltip[x,y;w,h;text;bgcolor;fontcolor]
	if parts.size() >= 2 and not parts[0].contains(","):
		tooltips[fs_unescape(parts[0])] = fs_unescape(parts[1])
		if named_controls.has(fs_unescape(parts[0])):
			named_controls[fs_unescape(parts[0])].tooltip_text = fs_unescape(parts[1])
		return
	if parts.size() < 3:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var area := Control.new()
	area.tooltip_text = fs_unescape(parts[2])
	area.mouse_filter = Control.MOUSE_FILTER_STOP
	_add(area, _pos(v), _geom(g))
	# Keep the transparent tooltip region behind interactive controls. This
	# preserves hover help over images without swallowing a button's clicks.
	current_parent.move_child(area, 0)

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
	_register_named_control(fs_unescape(parts[2]), panel)

func _font_size() -> int:
	return maxi(int(imgsize * 0.32), 10)

# Called by a slot; forwarded to the owner.
# --- styles (style[] and style_type[]) --------------------------------------

# Which type a style falls back to when the element's own type says nothing,
# from "Supported Element Types" in lua_api.md.
const STYLE_INHERITS := {
	"button_exit": "button",
	"image_button_exit": "image_button",
	"pwdfield": "field",
	"vertlabel": "label",
	"animated_image": "image",
}

# The states each Godot visual counts as active. Upstream applies a style when
# every state in its selector is active, so a pressed button is also hovered.
const STYLE_STATES := {
	"default": [],
	"hovered": ["hovered"],
	"pressed": ["pressed", "hovered"],
	"focused": ["focused"],
}

# style[selector 1,selector 2,...;prop=value;...], and style_type[] with the
# same shape. A selector is a name (or type) optionally followed by a colon
# and a +-separated list of states.
func _style(parts: PackedStringArray, by_type: bool) -> void:
	if parts.size() < 1:
		return
	var props := {}
	for i in range(1, parts.size()):
		var p := fs_unescape(parts[i])
		var eq := p.find("=")
		if eq < 0:
			continue
		props[p.substr(0, eq).strip_edges().to_lower()] = p.substr(eq + 1).strip_edges()
	if props.is_empty():
		return
	var target := style_by_type if by_type else style_by_name
	for raw in fs_split(parts[0], ","):
		var sel := fs_unescape(raw).strip_edges()
		if sel == "":
			continue
		var states := PackedStringArray()
		var colon := sel.find(":")
		if colon >= 0:
			for st in sel.substr(colon + 1).split("+", false):
				states.append(st.strip_edges().to_lower())
			sel = sel.substr(0, colon).strip_edges()
		if not target.has(sel):
			target[sel] = []
		target[sel].append({"states": states, "props": props})

# The properties in force for one element in one visual state, merged in
# upstream's precedence: every type in the inheritance chain under `*`, then
# the name, with a later declaration beating an earlier one.
func _style_for(ename: String, state: String) -> Dictionary:
	var out := {}
	if style_by_name.is_empty() and style_by_type.is_empty():
		return out
	var active: Array = STYLE_STATES.get(state, [])
	var chain: Array = ["*"]
	var t := current_element
	var parents: Array = []
	while t != "":
		parents.push_front(t)
		t = str(STYLE_INHERITS.get(t, ""))
	chain.append_array(parents)
	for ty in chain:
		_merge_style(out, style_by_type.get(ty, []), active)
	for nm in ["*", ename]:
		if nm != "":
			_merge_style(out, style_by_name.get(nm, []), active)
	return out

func _merge_style(out: Dictionary, entries: Array, active: Array) -> void:
	for e in entries:
		var ok := true
		for st in e["states"]:
			if not active.has(st):
				ok = false
				break
		if ok:
			for k in e["props"]:
				out[k] = e["props"][k]

# A style value that was set to nothing resets the property to its default,
# so an empty string means "not set" everywhere below.
static func _has_style(st: Dictionary, key: String) -> bool:
	return st.has(key) and String(st[key]) != ""

# font_size takes an absolute number, a +/- offset in points, or a *multiplier.
func _style_font_size(value: String, base: int) -> int:
	var v := value.strip_edges()
	if v == "":
		return base
	if v.begins_with("*"):
		return maxi(int(round(base * float(v.substr(1)))), 1)
	if v.begins_with("+") or v.begins_with("-"):
		return maxi(base + int(v), 1)
	return maxi(int(v), 1)

# The background for one button state: a nine-sliced or plain texture if the
# style names one, a flat fill if it names a colour, nothing if it turned the
# border off, and null to leave Godot's own theme alone.
func _style_box(st: Dictionary, img_key: String, color_key: String) -> StyleBox:
	if _has_style(st, img_key):
		var tex: Texture2D = item_source.ui_texture(String(st[img_key])) if item_source else null
		if tex:
			var sb := StyleBoxTexture.new()
			sb.texture = tex
			var middle := String(st.get("bgimg_middle", ""))
			if middle != "":
				var m := _middle_margins(middle, tex)
				sb.texture_margin_left = m.x
				sb.texture_margin_top = m.y
				sb.texture_margin_right = m.z
				sb.texture_margin_bottom = m.w
			return sb
	if _has_style(st, color_key):
		var sb := StyleBoxFlat.new()
		sb.bg_color = parse_color(String(st[color_key]), Color.TRANSPARENT)
		return sb
	if st.get("border", "") == "false":
		return StyleBoxEmpty.new()
	return null

# Applies whatever style[] and style_type[] asked for to a built control. The
# element type comes from current_element, so this stays a single call at the
# end of each builder.
func _apply_style(c: Control, ename: String) -> void:
	if style_by_name.is_empty() and style_by_type.is_empty():
		return
	var base := _style_for(ename, "default")
	if base.is_empty() and not (c is Button):
		return
	var base_font := _font_size()
	if _has_style(base, "font_size"):
		c.add_theme_font_size_override(
			"normal_font_size" if c is RichTextLabel else "font_size",
			_style_font_size(String(base["font_size"]), base_font))
	if c is Button:
		var b := c as Button
		for pair in [["normal", "default", "bgimg", "bgcolor"],
				["hover", "hovered", "bgimg_hovered", "bgcolor_hovered"],
				["pressed", "pressed", "bgimg_pressed", "bgcolor_pressed"],
				["focus", "focused", "bgimg", "bgcolor"]]:
			var st := _style_for(ename, pair[1])
			# The legacy per-state properties name their own keys; the state
			# selectors reuse the plain ones, so try both.
			var sb := _style_box(st, pair[2], pair[3])
			if sb == null and pair[1] != "default":
				sb = _style_box(st, "bgimg", "bgcolor")
			if sb != null:
				b.add_theme_stylebox_override(pair[0], sb)
			if _has_style(st, "textcolor"):
				var key := "font_color"
				match pair[1]:
					"hovered": key = "font_hover_color"
					"pressed": key = "font_pressed_color"
					"focused": key = "font_focus_color"
				b.add_theme_color_override(key, parse_color(String(st["textcolor"]), Color.WHITE))
		if _has_style(base, "fgimg") and item_source:
			var fg: Texture2D = item_source.ui_texture(String(base["fgimg"]))
			if fg:
				b.icon = fg
				b.expand_icon = true
				b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
				b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		if base.get("border", "") == "false":
			b.flat = true
		return
	if _has_style(base, "textcolor"):
		var col := parse_color(String(base["textcolor"]), Color.WHITE)
		if c is LineEdit or c is TextEdit or c is Label:
			c.add_theme_color_override("font_color", col)
		elif c is TabBar:
			c.add_theme_color_override("font_unselected_color", col)
			c.add_theme_color_override("font_selected_color", col)
	if base.get("border", "") == "false" and (c is LineEdit or c is TextEdit):
		c.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		c.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		if c is TextEdit:
			c.add_theme_stylebox_override("read_only", StyleBoxEmpty.new())

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


class AnimatedFormspecImage extends Control:
	var atlas := AtlasTexture.new()
	var current_frame := 0
	var frame_count := 1

	func setup(source: Texture2D, frames: int, duration_ms: int, start: int,
			margins: Vector4) -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame_count = maxi(frames, 1)
		atlas.atlas = source
		current_frame = clampi(start, 0, frame_count - 1)
		var display: Control
		if margins != Vector4.ZERO:
			var nine := NinePatchRect.new()
			nine.texture = atlas
			nine.patch_margin_left = int(margins.x)
			nine.patch_margin_top = int(margins.y)
			nine.patch_margin_right = int(margins.z)
			nine.patch_margin_bottom = int(margins.w)
			display = nine
		else:
			var rect := TextureRect.new()
			rect.texture = atlas
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_SCALE
			display = rect
		display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		display.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(display)
		_set_frame(current_frame)
		if frame_count > 1:
			var timer := Timer.new()
			timer.wait_time = maxf(duration_ms / 1000.0, 0.001)
			timer.autostart = true
			timer.timeout.connect(advance_frame)
			add_child(timer)

	func _set_frame(frame: int) -> void:
		current_frame = posmod(frame, frame_count)
		var frame_height := atlas.atlas.get_height() / float(frame_count)
		atlas.region = Rect2(0, current_frame * frame_height,
			atlas.atlas.get_width(), frame_height)

	func advance_frame() -> void:
		_set_frame(current_frame + 1)


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
		# Item icons are pixel art; the default 2D filter is linear, which
		# blurs their hard silhouette edges into the transparent background
		# and reads as a soft grey fringe, worst on thin shapes like tool
		# heads where edge pixels are a large share of the icon.
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		mouse_entered.connect(func() -> void: hovered = true; queue_redraw())
		mouse_exited.connect(func() -> void: hovered = false; queue_redraw())

	func refresh() -> void:
		item = form.item_source.get_list_item(location, listname, index) if form.item_source else {}
		icon = form.item_source.item_icon(item.get("name", "")) if (form.item_source and item.get("name", "") != "") else null
		tooltip_text = form.strip_enriched(String(item.get("description", ""))) if item.get("name", "") != "" else ""
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
