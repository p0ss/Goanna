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
#   slot_dragged(location: String, listname: String, index: int, button: int)
#   slot_released(location: String, listname: String, index: int, button: int)
#   slot_double_clicked(location: String, listname: String, index: int)
extends Control

signal fields_submitted(fields: Dictionary, quit: bool)
signal slot_clicked(location: String, listname: String, index: int, button: int, shift: bool)
# The pointer crossed into another slot with a mouse button held down. One
# report per slot entered, so a drag can share a stack out over the slots it
# passes over.
signal slot_dragged(location: String, listname: String, index: int, button: int)
# A mouse button came up. The slot named is the one under the pointer, which
# is not necessarily the one the press went to; an empty listname means the
# pointer was not over a slot at all.
signal slot_released(location: String, listname: String, index: int, button: int)
signal slot_double_clicked(location: String, listname: String, index: int)
signal closed()

const ELEM_SEP := "]"
const GlassStyle := preload("res://ui/glass_style.gd")
# GUIInventoryList::Options and the tooltip colours regenerateGui starts
# from: opaque grey slots, lighter under the pointer, no border until
# listcolors[] names one, and olive tooltips with white text.
const DEFAULT_LIST_SLOT_BG := Color8(128, 128, 128)
const DEFAULT_LIST_SLOT_BG_HOVER := Color8(192, 192, 192)
const DEFAULT_LIST_SLOT_BORDER := Color8(0, 0, 0, 200)
const DEFAULT_TOOLTIP_BG := Color8(110, 130, 60)
const DEFAULT_TOOLTIP_FG := Color8(255, 255, 255)

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
# Shared by reference with every slot, so a listcolors[] after a list still
# reaches it, as parseListColors updates the lists already parsed.
var listcolors := _default_listcolors()
# Tooltips, which the form draws itself as GUIFormSpecMenu does rather than
# through Godot's per-control tooltips: those cannot show colour escapes or
# markup on Godot's own controls, nor stand at a fixed position.
var tooltips := {}                   # element name -> {text, bg, fg}
var hypertips := {}                  # element name -> hypertip spec
var tooltip_areas: Array = []        # [{area: Control, tip: spec}] in element order
var tooltip_box: Control = null      # the one tooltip on screen
var tooltip_shown := {}              # the spec tooltip_box was built for
var hover_name := ""                 # the named element under the pointer
var hover_since := 0                 # when the pointer reached it, in ms
var list_rings: Array = []           # [{location, listname}]
var fields := {}                     # name -> Control (LineEdit/TextEdit/CheckBox/OptionButton/ItemList)
var field_close_on_enter := {}       # name -> bool
var named_controls := {}             # element name -> focusable/tooltip Control
var focus_name := ""
var focus_force := false
var slots: Array = []                # slot buttons for refresh
var drag_over_slot: Control = null   # slot the pointer was last reported over
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
# The game's window theme, from TOCLIENT_FORMSPEC_PREPEND. It is kept in its
# own list because it is built before the form's own elements, and with the
# old coordinate system whatever the form asked for.
var prepend_elements: Array = []     # parsed prepend [name, params]
var enable_prepends := true          # cleared by no_prepend[]
var root: Control                    # the form panel
var bg_layer: Control                # every background[], first child of root
var current_parent: Control
var skipped := {}
var screen_size := Vector2.ZERO     # the screen the form was laid out for
var simple_field_count := 0         # field[name;label;default] elements so far

# The interface style (ui/glass_style.gd). The host sets `style` before
# show_formspec; "game" draws the game's own window art, which is the
# renderer's parity mode and its default here. `glass` is whether this form
# is actually drawn in dark glass, which a form that paints its own window
# is not (see _paints_own_window). docs/interface-style.md has the rule for
# what is chrome and what is content.
var style := GlassStyle.GAME
var glass := false
var bespoke := false                 # glass was asked for and the form paints its own window
# While an element of the game's window theme builds: the prepend itself, or
# a form element that repeats it (see _repeats_theme).
var chrome_building := false
var theme_signatures := {}           # every prepend element, as written
var theme_textures := {}             # textures the prepend's backgrounds use
var glass_panes := 0                 # glass panes built where the theme had a background
var own_fullscreen := false          # the form itself set a full screen colour
var build_seq := 0                   # the element being built, counted from 1
var last_show: Array = []            # show_formspec's arguments, for restyle()

# --- public -----------------------------------------------------------------

# `prepend` is the game's window theme, from TOCLIENT_FORMSPEC_PREPEND. It is
# built behind the form unless the form asked for no_prepend[], which is why
# it is parsed after the form and not simply glued in front of it.
func show_formspec(spec: String, name: String, screen: Vector2, prepend := "") -> void:
	last_show = [spec, name, screen, prepend]
	_show(spec, name, screen, prepend, style == GlassStyle.GLASS)
	if glass and _paints_own_window():
		# A book, a map, a game's bespoke screen: the form draws its own
		# window, and its text and controls are made for that art, so all of
		# it keeps the game's look.
		_show(spec, name, screen, prepend, false)
		bespoke = true

func _show(spec: String, name: String, screen: Vector2, prepend: String, want_glass: bool) -> void:
	formname = name
	# Out of the tree at once, not at the end of the frame, so that a form
	# built twice in one frame (restyle, or a book first tried in glass)
	# never has the old controls standing behind the new.
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_reset()
	glass = want_glass
	_parse(spec)
	_theme_reference(prepend)
	if enable_prepends:
		_parse_prepend(prepend)
	_layout(screen)
	_build()
	refresh_lists()

# Builds the open form again in the current `style`, keeping what the player
# has typed, ticked or chosen. Nothing is sent to the server.
func restyle() -> void:
	if last_show.is_empty() or root == null:
		return
	var kept := {}
	for n in fields:
		var old: Control = fields[n]
		if not is_instance_valid(old):
			continue
		if old is LineEdit or old is TextEdit:
			kept[n] = old.get("text")
		elif old is CheckBox:
			kept[n] = (old as CheckBox).button_pressed
		elif old is OptionButton:
			kept[n] = (old as OptionButton).selected
		elif old is ItemList:
			kept[n] = (old as ItemList).get_selected_items()
		elif old is ScrollBar:
			kept[n] = (old as ScrollBar).value
	show_formspec(last_show[0], last_show[1], last_show[2], last_show[3])
	# Put back what the player changed, without the signals that would send
	# it to the server again. A tab header is left as the form says: choosing
	# a tab already went to the server, which answers with the form to show.
	var was := building
	building = true
	for n in kept:
		var c: Control = fields.get(n)
		if c == null or not is_instance_valid(c):
			continue
		var v: Variant = kept[n]
		if (c is LineEdit or c is TextEdit) and v is String:
			c.set("text", v)
		elif c is CheckBox and v is bool:
			(c as CheckBox).set_pressed_no_signal(v)
		elif c is OptionButton and v is int and v < (c as OptionButton).item_count:
			(c as OptionButton).select(v)
		elif c is ItemList and v is PackedInt32Array:
			for i in v:
				if i < (c as ItemList).item_count:
					(c as ItemList).select(i)
		elif c is ScrollBar and v is float:
			(c as ScrollBar).set_value_no_signal(float(kept[n]))
			_apply_scroll(n)
	building = was

func refresh_lists() -> void:
	for s in slots:
		if is_instance_valid(s):
			s.refresh()

# The fields every submission carries, as GUIFormSpecMenu::acceptInput sends
# them: the elements whose FieldSpec is built with send set, which are edit
# boxes and password fields, dropdowns, scrollbars and animated images.
# Buttons, check boxes, tab headers, text lists and tables are sent only by
# the event they cause (submit's `extra`), never along with another's. A form
# that reads a check box's field as "the player changed this" would otherwise
# see every check box change whenever any button is pressed, which is what
# kept Mineclonia's player settings form from ever going back to the
# inventory.
func collect_fields(dropdowns := true) -> Dictionary:
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
		elif c is OptionButton:
			if dropdowns and (c as OptionButton).selected >= 0:
				out[n] = _dropdown_value(c as OptionButton)
		elif c is ScrollBar:
			out[n] = "VAL:" + str(int((c as ScrollBar).value))
	return out

# A dropdown's field: its 1-based index when the form asked for index events,
# otherwise the text of the chosen item.
static func _dropdown_value(ob: OptionButton) -> String:
	var i: int = ob.selected
	if ob.get_meta("index_event", false):
		return str(i + 1)
	return ob.get_item_text(i) if i >= 0 else ""

# `extra` is what the event itself sends. A changed dropdown is the one
# dropdown upstream sends with it, so `dropdowns` is false for that event.
func submit(extra: Dictionary, quit: bool, dropdowns := true) -> void:
	var f := collect_fields(dropdowns)
	for k in extra:
		f[k] = extra[k]
	if quit:
		f["quit"] = "true"
	fields_submitted.emit(f, quit)

# --- introspection, read only ------------------------------------------------

# The form as the control channel's ui_tree reports it (docs/control-channel.md):
# every named element with its formspec type, every inventory slot with its
# stack, and the tooltip on screen. `visible` is false for anything hidden or
# scrolled out of its scroll_container. Nothing here changes the form.
func describe() -> Dictionary:
	var elements: Array = []
	for n in named_controls:
		var c: Control = named_controls[n]
		if is_instance_valid(c):
			elements.append({"name": n, "type": String(c.get_meta("formspec_type", "")),
				"control": c, "visible": shown_rect(c).has_area(),
				"tooltip": String(tooltips.get(n, {}).get("text", ""))})
	var list_slots: Array = []
	for s in slots:
		if is_instance_valid(s):
			list_slots.append({"location": s.location, "listname": s.listname,
				"index": s.index, "item": s.item, "control": s,
				"visible": shown_rect(s).has_area()})
	var tip := {}
	if tooltip_box != null and is_instance_valid(tooltip_box) and tooltip_box.visible:
		tip = tooltip_shown.duplicate()
		tip["rect"] = tooltip_box.get_global_rect()
	return {"formname": formname, "formspec_version": formspec_version,
		"allow_close": allow_close, "rect": root.get_global_rect() if root else Rect2(),
		"elements": elements, "slots": list_slots, "tooltip": tip, "hovered": hover_name}

# The part of a control the player can see: its rectangle cut by every
# clipping ancestor, such as a scroll_container's clipper, or an empty one
# when it is hidden.
func shown_rect(c: Control) -> Rect2:
	if not c.is_visible_in_tree():
		return Rect2()
	var r := c.get_global_rect()
	var p := c.get_parent() as Control
	while p != null:
		if p.clip_contents:
			r = r.intersection(p.get_global_rect())
		p = p.get_parent() as Control
	return r

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
	listcolors = _default_listcolors()
	tooltips.clear()
	list_rings.clear()
	fields.clear()
	field_close_on_enter.clear()
	named_controls.clear()
	focus_name = ""
	focus_force = false
	slots.clear()
	drag_over_slot = null
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
	prepend_elements.clear()
	enable_prepends = true
	skipped.clear()
	hypertips.clear()
	tooltip_areas.clear()
	tooltip_box = null
	tooltip_shown = {}
	hover_name = ""
	simple_field_count = 0
	key_capture = null
	glass = false
	bespoke = false
	chrome_building = false
	theme_signatures.clear()
	theme_textures.clear()
	glass_panes = 0
	own_fullscreen = false
	build_seq = 0

static func _default_listcolors() -> Dictionary:
	return {"slot_bg": DEFAULT_LIST_SLOT_BG, "slot_bg_h": DEFAULT_LIST_SLOT_BG_HOVER,
		"slot_border": DEFAULT_LIST_SLOT_BORDER, "slot_border_on": false,
		"tooltip_bg": DEFAULT_TOOLTIP_BG, "tooltip_fg": DEFAULT_TOOLTIP_FG}

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
	return strip_enriched(fs_unescape_raw(s))

# unescape_string: the backslashes gone and colour escapes kept, for text
# upstream draws as an EnrichedString.
static func fs_unescape_raw(s: String) -> String:
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
	return out

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
				enable_prepends = false
			_:
				pending_elements.append([name, params])

# The game's window theme, sent once as TOCLIENT_FORMSPEC_PREPEND and applied
# to every server form that does not opt out. Upstream feeds it to the
# ordinary element parser (GUIFormSpecMenu::regenerateGui), so the headers
# that are only read from the front of a form, size, position, anchor,
# padding and no_prepend, are not elements here at all and are dropped. The
# rest, formspec_version and real_coordinates included, are elements, and
# _build applies them while the prepend builds and undoes them afterwards.
func _parse_prepend(prepend: String) -> void:
	for raw in fs_split(prepend, ELEM_SEP):
		var e := raw.strip_edges()
		if e == "":
			continue
		var br := e.find("[")
		if br < 0:
			continue
		var name := e.substr(0, br).strip_edges()
		match name:
			"size", "position", "anchor", "padding", "no_prepend":
				pass
			_:
				prepend_elements.append([name, e.substr(br + 1)])

# What the game's window theme is made of, noted whether or not this form
# uses the prepend, so that the dark glass style can recognise the theme when
# a form repeats it by hand. Mineclonia's creative inventory says
# no_prepend[] and then writes the same listcolors, styles and bgcolor
# itself, with the theme's background9 at a rectangle of its own.
func _theme_reference(prepend: String) -> void:
	for raw in fs_split(prepend, ELEM_SEP):
		var e := raw.strip_edges()
		var br := e.find("[")
		if br < 0:
			continue
		var name := e.substr(0, br).strip_edges()
		var params := e.substr(br + 1)
		theme_signatures[_signature(name, params)] = true
		if name == "background" or name == "background9":
			var p := fs_split(params, ";")
			if p.size() >= 3:
				theme_textures[fs_unescape(p[2]).strip_edges()] = true

static func _signature(name: String, params: String) -> String:
	return name + "[" + params.replace(" ", "").replace("\t", "").replace("\n", "")

# Whether a form element is the game's window theme written out again: the
# same element as one in the prepend, or a background or background9 drawn
# with a texture the prepend's own backgrounds use.
func _repeats_theme(name: String, params: String) -> bool:
	if theme_signatures.has(_signature(name, params)):
		return true
	if name == "background" or name == "background9":
		var p := fs_split(params, ";")
		return p.size() >= 3 and theme_textures.has(fs_unescape(p[2]).strip_edges())
	return false

# True while the element being built is window chrome that the dark glass
# style replaces.
func _chrome() -> bool:
	return glass and chrome_building

# A text colour as it is drawn: unchanged in the game theme, and lifted where
# needed to stay legible on dark glass (GlassStyle.ink).
func _ink(c: Color, surface := GlassStyle.PANEL_WORST) -> Color:
	return GlassStyle.ink(c, surface) if glass else c

# A form paints its own window when a background of its own, not the theme's
# and not plain window art, covers nine tenths of the form or more and is at
# least half opaque: a book's page, not line art drawn over the game's panel.
func _paints_own_window() -> bool:
	if root == null or bg_layer == null:
		return false
	var form := Rect2(Vector2.ZERO, root.size)
	var area := maxf(form.get_area(), 1.0)
	for c in bg_layer.get_children():
		if c.has_meta("glass_surface") or not (c is Control):
			continue
		var r := Rect2((c as Control).position, (c as Control).size)
		if r.intersection(form).get_area() >= area * 0.9 \
				and _opaque_share(c.get("texture")) >= 0.5:
			return true
	return false

# How much of a texture is opaque, 0 to 1: a book's page is nearly all of
# it, the brewing stand's tubes, drawn over the game's panel, a twentieth.
static func _opaque_share(tex: Texture2D) -> float:
	if tex == null:
		return 0.0
	var img := tex.get_image()
	if img == null or img.get_width() == 0:
		return 0.0
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	if maxi(img.get_width(), img.get_height()) > 64:
		var sc := 64.0 / maxi(img.get_width(), img.get_height())
		img.resize(maxi(int(img.get_width() * sc), 1), maxi(int(img.get_height() * sc), 1),
			Image.INTERPOLATE_NEAREST)
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a >= 0.5:
				n += 1
	return float(n) / (img.get_width() * img.get_height())

# --- layout maths (GUIFormSpecMenu::regenerateGui) ---------------------------

func _layout(screen: Vector2) -> void:
	screen_size = screen
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
	if not has_size:
		# A form without size[] is only unpositioned fields and a Proceed
		# button, in a 580 by 300 window until _build fits it to them.
		form_size = Vector2(580, 300)
	elif real_coordinates:
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
	root.theme = GlassStyle.form_theme(_mono_font()) if glass else _form_theme()
	current_parent = root

# Luanti draws every piece of form text with a shadow one pixel down and
# right at half alpha: the font_shadow and font_shadow_alpha defaults, which
# the font engine applies to labels, button labels and hypertext alike.
static func _form_theme() -> Theme:
	var t := Theme.new()
	for type in ["Label", "RichTextLabel"]:
		t.set_color("font_shadow_color", type, Color(0, 0, 0, 127.0 / 255.0))
		t.set_constant("shadow_offset_x", type, 1)
		t.set_constant("shadow_offset_y", type, 1)
	# The mono face <mono>, font=mono and the font style property ask for.
	t.set_font("mono_font", "RichTextLabel", _mono_font())
	# CGUIScrollBar in Luanti's skin: the track in EGDC_SCROLLBAR's
	# translucent light grey, the thumb an opaque dark button pane, measured
	# at (62, 62, 62) against the vanilla client, EGDS_SCROLLBAR_SIZE's 21
	# pixels across. The form's own
	# scrollbar[] takes it, and so do the bars inside hypertext, textareas
	# and lists.
	var track := StyleBoxFlat.new()
	track.bg_color = Color8(230, 230, 230, 101)
	var thumb := StyleBoxFlat.new()
	thumb.bg_color = Color8(62, 62, 62)
	thumb.set_border_width_all(1)
	thumb.border_color = Color8(30, 30, 30)
	for type in ["VScrollBar", "HScrollBar"]:
		var across := track.duplicate() as StyleBoxFlat
		# The thumb is never shorter than the bar is wide, as the vanilla
		# client draws a small page as a square.
		var square := thumb.duplicate() as StyleBoxFlat
		if type == "VScrollBar":
			across.content_margin_left = 10.5
			across.content_margin_right = 10.5
			square.content_margin_top = 10.5
			square.content_margin_bottom = 10.5
		else:
			across.content_margin_top = 10.5
			across.content_margin_bottom = 10.5
			square.content_margin_left = 10.5
			square.content_margin_right = 10.5
		t.set_stylebox("scroll", type, across)
		t.set_stylebox("scroll_focus", type, across)
		for key in ["grabber", "grabber_highlight", "grabber_pressed"]:
			t.set_stylebox(key, type, square)
	return t

func _pos(v: PackedStringArray) -> Vector2:
	if real_coordinates:
		return Vector2((float(v[0]) + pos_offset.x) * imgsize, (float(v[1]) + pos_offset.y) * imgsize)
	return Vector2(padding.x + (pos_offset.x + float(v[0])) * spacing.x,
		padding.y + (pos_offset.y + float(v[1])) * spacing.y)

func _geom(v: PackedStringArray) -> Vector2:
	if real_coordinates:
		return Vector2(float(v[0]) * imgsize, float(v[1]) * imgsize)
	return Vector2(float(v[0]) * spacing.x - (spacing.x - imgsize), float(v[1]) * spacing.y - (spacing.y - imgsize))

# A button's rectangle relative to its position (parseButton). In the old
# system the height is fixed at two button-heights, centred half the given
# height in slots below y.
func _btn_geom(v: PackedStringArray) -> Rect2:
	if real_coordinates:
		return Rect2(Vector2.ZERO, _geom(v))
	var w := float(v[0]) * spacing.x - (spacing.x - imgsize)
	var btn_h := imgsize * 15.0 / 13.0 * 0.35
	var slots := float(v[1]) if v.size() >= 2 else 0.0
	return Rect2(Vector2(0, slots * imgsize / 2.0 - btn_h), Vector2(w, btn_h * 2.0))

# The colour names parseColorString accepts: the CSS table in
# luanti/src/util/string.cpp, which is not Godot's (Godot's green is lime).
const NAMED_COLOURS := {
	"aliceblue": 0xf0f8ff, "antiquewhite": 0xfaebd7, "aqua": 0x00ffff, "aquamarine": 0x7fffd4,
	"azure": 0xf0ffff, "beige": 0xf5f5dc, "bisque": 0xffe4c4, "black": 0x000000,
	"blanchedalmond": 0xffebcd, "blue": 0x0000ff, "blueviolet": 0x8a2be2, "brown": 0xa52a2a,
	"burlywood": 0xdeb887, "cadetblue": 0x5f9ea0, "chartreuse": 0x7fff00, "chocolate": 0xd2691e,
	"coral": 0xff7f50, "cornflowerblue": 0x6495ed, "cornsilk": 0xfff8dc, "crimson": 0xdc143c,
	"cyan": 0x00ffff, "darkblue": 0x00008b, "darkcyan": 0x008b8b, "darkgoldenrod": 0xb8860b,
	"darkgray": 0xa9a9a9, "darkgreen": 0x006400, "darkgrey": 0xa9a9a9, "darkkhaki": 0xbdb76b,
	"darkmagenta": 0x8b008b, "darkolivegreen": 0x556b2f, "darkorange": 0xff8c00,
	"darkorchid": 0x9932cc, "darkred": 0x8b0000, "darksalmon": 0xe9967a, "darkseagreen": 0x8fbc8f,
	"darkslateblue": 0x483d8b, "darkslategray": 0x2f4f4f, "darkslategrey": 0x2f4f4f,
	"darkturquoise": 0x00ced1, "darkviolet": 0x9400d3, "deeppink": 0xff1493,
	"deepskyblue": 0x00bfff, "dimgray": 0x696969, "dimgrey": 0x696969, "dodgerblue": 0x1e90ff,
	"firebrick": 0xb22222, "floralwhite": 0xfffaf0, "forestgreen": 0x228b22, "fuchsia": 0xff00ff,
	"gainsboro": 0xdcdcdc, "ghostwhite": 0xf8f8ff, "gold": 0xffd700, "goldenrod": 0xdaa520,
	"gray": 0x808080, "green": 0x008000, "greenyellow": 0xadff2f, "grey": 0x808080,
	"honeydew": 0xf0fff0, "hotpink": 0xff69b4, "indianred": 0xcd5c5c, "indigo": 0x4b0082,
	"ivory": 0xfffff0, "khaki": 0xf0e68c, "lavender": 0xe6e6fa, "lavenderblush": 0xfff0f5,
	"lawngreen": 0x7cfc00, "lemonchiffon": 0xfffacd, "lightblue": 0xadd8e6,
	"lightcoral": 0xf08080, "lightcyan": 0xe0ffff, "lightgoldenrodyellow": 0xfafad2,
	"lightgray": 0xd3d3d3, "lightgreen": 0x90ee90, "lightgrey": 0xd3d3d3, "lightpink": 0xffb6c1,
	"lightsalmon": 0xffa07a, "lightseagreen": 0x20b2aa, "lightskyblue": 0x87cefa,
	"lightslategray": 0x778899, "lightslategrey": 0x778899, "lightsteelblue": 0xb0c4de,
	"lightyellow": 0xffffe0, "lime": 0x00ff00, "limegreen": 0x32cd32, "linen": 0xfaf0e6,
	"magenta": 0xff00ff, "maroon": 0x800000, "mediumaquamarine": 0x66cdaa, "mediumblue": 0x0000cd,
	"mediumorchid": 0xba55d3, "mediumpurple": 0x9370db, "mediumseagreen": 0x3cb371,
	"mediumslateblue": 0x7b68ee, "mediumspringgreen": 0x00fa9a, "mediumturquoise": 0x48d1cc,
	"mediumvioletred": 0xc71585, "midnightblue": 0x191970, "mintcream": 0xf5fffa,
	"mistyrose": 0xffe4e1, "moccasin": 0xffe4b5, "navajowhite": 0xffdead, "navy": 0x000080,
	"oldlace": 0xfdf5e6, "olive": 0x808000, "olivedrab": 0x6b8e23, "orange": 0xffa500,
	"orangered": 0xff4500, "orchid": 0xda70d6, "palegoldenrod": 0xeee8aa, "palegreen": 0x98fb98,
	"paleturquoise": 0xafeeee, "palevioletred": 0xdb7093, "papayawhip": 0xffefd5,
	"peachpuff": 0xffdab9, "peru": 0xcd853f, "pink": 0xffc0cb, "plum": 0xdda0dd,
	"powderblue": 0xb0e0e6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xff0000,
	"rosybrown": 0xbc8f8f, "royalblue": 0x4169e1, "saddlebrown": 0x8b4513, "salmon": 0xfa8072,
	"sandybrown": 0xf4a460, "seagreen": 0x2e8b57, "seashell": 0xfff5ee, "sienna": 0xa0522d,
	"silver": 0xc0c0c0, "skyblue": 0x87ceeb, "slateblue": 0x6a5acd, "slategray": 0x708090,
	"slategrey": 0x708090, "snow": 0xfffafa, "springgreen": 0x00ff7f, "steelblue": 0x4682b4,
	"tan": 0xd2b48c, "teal": 0x008080, "thistle": 0xd8bfd8, "tomato": 0xff6347,
	"turquoise": 0x40e0d0, "violet": 0xee82ee, "wheat": 0xf5deb3, "white": 0xffffff,
	"whitesmoke": 0xf5f5f5, "yellow": 0xffff00, "yellowgreen": 0x9acd32
}

# parseColorString in luanti/src/util/string.cpp: #RGB, #RGBA, #RRGGBB or
# #RRGGBBAA, or a colour name, in any case, optionally followed by # and one
# or two hex digits of alpha. Anything else is the fallback.
static func parse_color(s: String, fallback: Color) -> Color:
	s = s.strip_edges()
	if s == "":
		return fallback
	if s.begins_with("#"):
		var h := s.substr(1)
		if not h.is_valid_hex_number():
			return fallback
		if h.length() == 3 or h.length() == 4:
			var e := ""
			for ch in h:
				e += ch + ch
			h = e
		if h.length() == 6:
			h += "ff"
		if h.length() != 8:
			return fallback
		return Color.hex(("0x" + h).hex_to_int())
	var base := s
	var alpha := "ff"
	var sharp := s.find("#")
	if sharp >= 0:
		base = s.substr(0, sharp)
		alpha = s.substr(sharp + 1)
		if alpha.length() == 1:
			alpha += alpha
		if alpha.length() != 2 or not alpha.is_valid_hex_number():
			return fallback
	base = base.to_lower()
	if not NAMED_COLOURS.has(base):
		return fallback
	return Color.hex((int(NAMED_COLOURS[base]) << 8) | ("0x" + alpha).hex_to_int())

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
	# Named tooltips are looked up by name when the pointer reaches the
	# element, as m_tooltips is, so one may come before or after its element.
	# Each keeps the colours in force where it was parsed: its own, or the
	# listcolors[] defaults up to that point (parseTooltip).
	var tip_bg := DEFAULT_TOOLTIP_BG
	var tip_fg := DEFAULT_TOOLTIP_FG
	for el in prepend_elements + pending_elements:
		var p := fs_split(el[1], ";")
		if el[0] == "listcolors" and p.size() == 5 and not glass:
			tip_bg = parse_color(p[3], tip_bg)
			tip_fg = parse_color(p[4], tip_fg)
		elif el[0] == "tooltip" and not p[0].contains(",") and (p.size() == 2 or p.size() == 4):
			if p.size() == 4 and not (_is_colour(p[2]) and _is_colour(p[3])):
				continue
			tooltips[fs_unescape(p[0])] = {"text": fs_unescape_raw(p[1]),
				"bg": parse_color(p[2], tip_bg) if p.size() == 4 else tip_bg,
				"fg": parse_color(p[3], tip_fg) if p.size() == 4 else tip_fg}
	# a fullscreen tint behind the form, if asked for
	add_child(root)
	bg_layer = Control.new()
	bg_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg_layer)
	building = true
	# The game's window theme first, so that it is behind the form's own
	# elements. Upstream builds it with the old coordinate system whatever
	# the form asked for, and puts the formspec version back afterwards, so
	# that a version 6 form does not drag the prepend into real coordinates
	# (GUIFormSpecMenu::regenerateGui).
	# Where the old draw order starts sorting (regenerateGui's
	# legacy_sort_start): after the background layer, or after the prepend
	# when the prepend was built at version 3 or later.
	var sort_from := 1
	if prepend_elements.size() > 0:
		var real_backup := real_coordinates
		var version_backup := formspec_version
		real_coordinates = false
		chrome_building = true
		for el in prepend_elements:
			build_seq += 1
			_build_element(el[0], el[1])
		chrome_building = false
		if formspec_version >= 3:
			sort_from = root.get_child_count()
		elif version_backup >= 3:
			_legacy_sort(1)
			sort_from = root.get_child_count()
		formspec_version = version_backup
		real_coordinates = real_backup
	for el in pending_elements:
		build_seq += 1
		chrome_building = glass and _repeats_theme(el[0], el[1])
		_build_element(el[0], el[1])
		chrome_building = false
	if formspec_version < 3:
		_legacy_sort(sort_from)
	building = false
	if glass:
		_replace_slot_frames()
		_glass_window_art()
		_glass_line_art()
		_mark_selected_art()
		_glass_back_outside()
	if skipped.size() > 0:
		print("formspec: elements not rendered: ", skipped)
	if not has_size and simple_field_count > 0:
		# regenerateGui: the window grows sixty pixels a field from 270,
		# centred on the screen, and an unstyled Proceed button 140 wide sits
		# under the fields.
		var n := simple_field_count
		root.size = Vector2(580, 270 + 60 * n)
		root.position = (Vector2(screen_size.x / 2.0 - 290, screen_size.y / 2.0 - 150)).floor()
		var b := Button.new()
		current_parent = root
		_add(b, Vector2(580 / 2.0 - 70, (n + 2) * 60.0), Vector2(140, _button_height() * 2.0))
		var content := _button_content(b, "Proceed", false)
		b.pressed.connect(func() -> void: submit({}, true))
		var none: Array = []
		for i in 8:
			none.append({})
		_style_button(b, "", none, content)
	# a bare form with only images and buttons still needs a background
	if glass:
		_glass_window()
	elif has_form_bgcolor:
		var sb := StyleBoxFlat.new()
		sb.bg_color = form_bgcolor
		root.add_theme_stylebox_override("panel", sb)
	else:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.13, 0.13, 0.13, 0.9)
		sb.set_corner_radius_all(int(imgsize * 0.08))
		root.add_theme_stylebox_override("panel", sb)
	_apply_focus()

# --- the dark glass style ----------------------------------------------------

# The form's window in dark glass. Where the theme drew a background, a glass
# pane already stands in its place (_background). Otherwise the whole form is
# glass, unless the form itself asked for no panel with a transparent
# bgcolor[] of its own. The game's full screen colour gives way to a light
# dim; one the form set itself is kept.
func _glass_window() -> void:
	root.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var no_panel := has_form_bgcolor and form_bgcolor.a <= 0.0
	if glass_panes == 0 and not no_panel:
		var pane := GlassStyle.surface()
		pane.size = root.size
		bg_layer.add_child(pane)
		bg_layer.move_child(pane, 0)
		glass_panes += 1
	if not own_fullscreen:
		fullscreen_bg = GlassStyle.BACKDROP

static var _art_cache := {}

# Whether a texture is plain window art: a panel, button or tab face rather
# than a picture. It must be at least 24 pixels each way (node textures,
# item icons and bars are smaller), nine tenths opaque, grey (no pixel's
# channels more than 16 apart in nineteen of twenty pixels), and flat (one
# colour, to four bits a channel, covering nine twentieths of it).
# Mineclonia's slot, panel, tab and model backing art passes; its trash can
# (a red cross), armour outlines (mostly clear), arrows and pictures do not.
# Returns {art, lum}, lum being the mean relative luminance.
static func _window_art(tex: Texture2D) -> Dictionary:
	if tex == null:
		return {"art": false, "lum": 0.0}
	var key := tex.get_instance_id()
	if _art_cache.has(key):
		return _art_cache[key]
	var out := {"art": false, "lum": 0.0}
	var img := tex.get_image()
	if img != null and img.get_width() >= 24 and img.get_height() >= 24:
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		if maxi(img.get_width(), img.get_height()) > 128:
			var s := 128.0 / maxi(img.get_width(), img.get_height())
			img.resize(maxi(int(img.get_width() * s), 1), maxi(int(img.get_height() * s), 1),
				Image.INTERPOLATE_NEAREST)
		var total := img.get_width() * img.get_height()
		var opaque := 0
		var grey := 0
		var lum := 0.0
		var counts := {}
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.a < 0.5:
					continue
				opaque += 1
				if maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) <= 16.0 / 255.0:
					grey += 1
				lum += GlassStyle.luminance(c)
				var q := (c.r8 >> 4) << 8 | (c.g8 >> 4) << 4 | (c.b8 >> 4)
				counts[q] = int(counts.get(q, 0)) + 1
		if opaque > 0:
			var mode := 0
			for q in counts:
				mode = maxi(mode, int(counts[q]))
			out["lum"] = lum / opaque
			out["art"] = opaque >= total * 0.9 and grey >= opaque * 0.95 and mode >= opaque * 0.45
	_art_cache[key] = out
	return out

# Window art the form draws with image[] behind something the player uses:
# the frame of a tab (Mineclonia's survival inventory tabs under their item
# buttons) or of a model (the black backing of the player preview). The
# image must be built before the element, hold the element's centre, and be
# at most four times its area. It becomes a glass tile of the same
# rectangle; window art that frames nothing, such as a picture of a
# crafting grid on a help page, is kept.
func _glass_window_art() -> void:
	var framed: Array = []
	for c in _form_controls(root):
		if c is BaseButton or c is FormspecSlot or c is FormspecModel or c is LineEdit \
				or c is TextEdit or c is OptionButton:
			framed.append(c)
	for img in _form_controls(root):
		if not (img as Control).has_meta("fs_image") or not img.visible \
				or img.get_meta("glass_replaced", false):
			continue
		var tex: Texture2D = img.get("texture")
		var art := _window_art(tex)
		if not bool(art["art"]):
			continue
		var ir: Rect2 = (img as Control).get_global_rect()
		var frames := false
		for e in framed:
			var er: Rect2 = (e as Control).get_global_rect()
			if int(e.get_meta("seq", 0)) > int(img.get_meta("seq", 0)) \
					and ir.has_point(er.get_center()) \
					and ir.get_area() <= er.get_area() * 4.0 + 1.0:
				frames = true
				break
		if not frames:
			continue
		var tile := Panel.new()
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.position = (img as Control).position
		tile.size = (img as Control).size
		var dark := float(art["lum"]) < 0.25
		tile.add_theme_stylebox_override("panel", GlassStyle.tile_box(dark, false))
		tile.set_meta("window_art_lum", float(art["lum"]))
		tile.set_meta("tile_dark", dark)
		img.get_parent().add_child(tile)
		img.get_parent().move_child(tile, img.get_index() + 1)
		img.visible = false
		img.set_meta("glass_replaced", true)

static var _line_art_cache := {}

# Dark line art in or behind an inventory slot (Mineclonia's empty armour,
# shield, banner, dye and template outlines) was drawn for a light grey slot
# and nearly vanishes on glass. It is drawn light instead, its shading
# inverted and its shape and transparency kept, as text colours are lifted.
# A texture qualifies when it is between a fiftieth and three fifths opaque,
# its opaque pixels grey and dark (mean relative luminance under 0.2).
func _glass_line_art() -> void:
	var slot_rects: Array = []
	for s in slots:
		if is_instance_valid(s):
			slot_rects.append((s as Control).get_global_rect())
	for img in _form_controls(root):
		if not (img as Control).has_meta("fs_image") or not img.visible \
				or img.get_meta("glass_replaced", false):
			continue
		var ir: Rect2 = (img as Control).get_global_rect()
		var over := false
		for sr in slot_rects:
			if sr.has_point(ir.get_center()) or ir.has_point((sr as Rect2).get_center()):
				over = true
				break
		if not over:
			continue
		var tex: Texture2D = img.get("texture")
		var lit := _light_line_art(tex)
		if lit != null:
			img.set("texture", lit)
			img.set_meta("glass_line_art", true)

static func _light_line_art(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	var key := tex.get_instance_id()
	if _line_art_cache.has(key):
		return _line_art_cache[key]
	var out: Texture2D = null
	var img := tex.get_image()
	if img != null and img.get_width() > 0:
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var total := img.get_width() * img.get_height()
		var opaque := 0
		var grey := 0
		var lum := 0.0
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.a < 0.5:
					continue
				opaque += 1
				if maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) <= 24.0 / 255.0:
					grey += 1
				lum += GlassStyle.luminance(c)
		if opaque >= total * 0.02 and opaque <= total * 0.6 and grey >= opaque * 0.9 \
				and lum / opaque < 0.2:
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					img.set_pixel(x, y, Color((1.0 - c.r) * 0.82, (1.0 - c.g) * 0.84,
						(1.0 - c.b) * 0.88, c.a))
			out = ImageTexture.create_from_image(img)
	_line_art_cache[key] = out
	return out

# The piece of window art that is lighter than all the others of its size
# is the selected one, as Mineclonia draws its chosen tab in lighter art than
# the rest. In a group of two or more of the same size, a piece at least
# 0.1 lighter (in relative luminance) than every other piece of the group is
# drawn selected: an accent fill and ring. A group with no such piece, or
# with more than half its pieces that light, has none.
func _mark_selected_art() -> void:
	var groups := {}
	for c in _form_controls(root):
		if not (c as Control).has_meta("window_art_lum") or not (c as Control).visible:
			continue
		var key := Vector2i(((c as Control).size / 4.0).round())
		if not groups.has(key):
			groups[key] = []
		groups[key].append(c)
	for key in groups:
		var members: Array = groups[key]
		if members.size() < 2:
			continue
		var chosen: Array = []
		for m in members:
			var lum := float(m.get_meta("window_art_lum"))
			var lighter := true
			for other in members:
				if other != m and lum - float(other.get_meta("window_art_lum")) < 0.1:
					lighter = false
					break
			if lighter:
				chosen.append(m)
		if chosen.is_empty() or chosen.size() * 2 > members.size():
			continue
		for m in chosen:
			m.set_meta("art_selected", true)
			if m is Button:
				for look in ["normal", "hover", "pressed", "hover_pressed"]:
					(m as Button).add_theme_stylebox_override(look, GlassStyle.selected_box())
			elif m is Panel:
				(m as Panel).add_theme_stylebox_override("panel",
					GlassStyle.tile_box(bool(m.get_meta("tile_dark", false)), true))

# Replaced window art that stands outside the form's glass, such as
# Mineclonia's creative tabs above and below its window, gets a pane of the
# same glass behind it, so that a tab is not a faint tile over the bare world.
func _glass_back_outside() -> void:
	var panes: Array = []
	for p in bg_layer.get_children():
		if p.has_meta("glass_surface"):
			panes.append((p as Control).get_global_rect())
	if panes.is_empty():
		return
	for c in _form_controls(root):
		if not (c as Control).has_meta("window_art_lum") or not (c as Control).visible:
			continue
		var centre: Vector2 = (c as Control).get_global_rect().get_center()
		var inside := false
		for r in panes:
			if (r as Rect2).has_point(centre):
				inside = true
				break
		if inside:
			continue
		var pane := GlassStyle.surface()
		pane.position = (c as Control).position
		pane.size = (c as Control).size
		c.get_parent().add_child(pane)
		c.get_parent().move_child(pane, c.get_index())
		c.set_meta("glass_backed", true)

# Slot frames: a form's own image[] drawn behind an inventory slot to frame
# it, as Mineclonia draws mcl_formspec_itemslot.png under every slot and
# Minetest Game gui_hb_bg.png under its hotbar row. In dark glass the slot
# draws its own glass frame, so the image is hidden. An image counts as a
# frame only when all of these hold, which keeps any image that says
# something (the empty armour slot outlines, a trash can, a fuel hint):
#   - it is built before the slot, so it lies behind it;
#   - it contains the slot and is at most an eighth of a slot larger on
#     each side (a bigger frame, a furnace's large output slot, becomes a
#     glass tile of its own size instead, in _glass_window_art);
#   - the same texture frames at least two slots in this form.
# A list with any framed slot is drawn in the lighter framed look, so a row
# the game set apart from the others stays apart.
func _replace_slot_frames() -> void:
	if slots.is_empty():
		return
	var buckets := {}
	for s in slots:
		var r: Rect2 = (s as Control).get_global_rect()
		var key := Vector2i((r.get_center() / 8.0).round())
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(s)
	var framing := {}   # image -> slots it frames
	var per_texture := {}
	for img in _form_controls(root):
		if not (img as Control).has_meta("fs_image"):
			continue
		var ir: Rect2 = (img as Control).get_global_rect()
		var centre := Vector2i((ir.get_center() / 8.0).round())
		var found: Array = []
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for s in buckets.get(centre + Vector2i(dx, dy), []):
					var sr: Rect2 = (s as Control).get_global_rect()
					if int(s.get_meta("seq", 0)) <= int(img.get_meta("seq", 0)):
						continue
					if not ir.grow(1.0).encloses(sr):
						continue
					if ir.size.x > sr.size.x * 1.25 + 1.0 or ir.size.y > sr.size.y * 1.25 + 1.0:
						continue
					found.append(s)
		if found.is_empty():
			continue
		framing[img] = found
		var tex := String(img.get_meta("fs_image"))
		per_texture[tex] = int(per_texture.get(tex, 0)) + found.size()
	var framed_lists := {}
	for img in framing:
		if int(per_texture[String(img.get_meta("fs_image"))]) < 2:
			continue
		img.visible = false
		img.set_meta("glass_replaced", true)
		for s in framing[img]:
			framed_lists[int(s.get_meta("list", 0))] = true
	for s in slots:
		if framed_lists.has(int(s.get_meta("list", 0))):
			s.framed = true
	_replace_empty_slot_frames(framing)
	# A slot over a picture the form keeps (Mineclonia's trash can, anything
	# drawn behind a list that is not a frame) is drawn see-through, as the
	# game's own translucent slot colour would be, so the picture still shows.
	for img in _form_controls(root):
		if not (img as Control).has_meta("fs_image") or img.get_meta("glass_replaced", false):
			continue
		var ir: Rect2 = (img as Control).get_global_rect()
		for s in slots:
			if int(s.get_meta("seq", 0)) > int(img.get_meta("seq", 0)) \
					and ir.has_point((s as Control).get_global_rect().get_center()):
				s.over_art = true

# The same slot art where no slot is: a creative tab with fewer items than
# its grid, Mineclonia's trade slots before a trade is chosen. The game shows
# an empty slot there, so dark glass shows an empty glass slot, placed inside
# the art as the frames that did hold a slot place theirs. Only a texture
# already replaced as a slot frame in this form, at the size it framed a
# slot, counts, so a picture that merely shares a texture is kept.
func _replace_empty_slot_frames(framing: Dictionary) -> void:
	var looks := {}   # texture -> [frame size, slot offset and size as parts of it]
	for img in framing:
		if not img.get_meta("glass_replaced", false):
			continue
		var tex := String(img.get_meta("fs_image"))
		if looks.has(tex):
			continue
		var ir: Rect2 = (img as Control).get_global_rect()
		var sr: Rect2 = (framing[img][0] as Control).get_global_rect()
		if ir.size.x <= 0.0 or ir.size.y <= 0.0:
			continue
		looks[tex] = [ir.size, (sr.position - ir.position) / ir.size, sr.size / ir.size]
	if looks.is_empty():
		return
	for img in _form_controls(root):
		if not (img as Control).has_meta("fs_image") or img.get_meta("glass_replaced", false) \
				or framing.has(img):
			continue
		var look = looks.get(String(img.get_meta("fs_image")))
		if look == null:
			continue
		var ir: Rect2 = (img as Control).get_global_rect()
		if absf(ir.size.x - look[0].x) > 2.0 or absf(ir.size.y - look[0].y) > 2.0:
			continue
		var c := img as Control
		var tile := GlassEmptySlot.new()
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.position = c.position + c.size * (look[1] as Vector2)
		tile.size = c.size * (look[2] as Vector2)
		tile.set_meta("seq", c.get_meta("seq", 0))
		tile.set_meta("glass_empty_slot", true)
		c.add_sibling(tile)
		c.visible = false
		c.set_meta("glass_replaced", true)

class GlassEmptySlot extends Control:
	func _draw() -> void:
		GlassStyle.draw_slot(self, Rect2(Vector2.ZERO, size), false, true)

# One element, from the form itself or from the prepend. The headers a form
# only accepts at its front are elements when a prepend uses them, which is
# why formspec_version, real_coordinates, allow_close and set_focus appear
# here as well as in _parse.
func _build_element(name: String, params: String) -> void:
	var parts := fs_split(params, ";")
	current_element = name
	match name:
		"formspec_version": formspec_version = int(params)
		"real_coordinates": real_coordinates = params.strip_edges() == "true"
		"allow_close": allow_close = params.strip_edges() != "false"
		"set_focus", "focus":
			focus_name = fs_unescape(parts[0]) if parts.size() >= 1 else ""
			focus_force = parts.size() >= 2 and parts[1].strip_edges() == "true"
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
		"hypertip": _hypertip(parts)
		"model": _model(parts)
		"scrollbar": _scrollbar(parts)
		"scrollbaroptions": _scrollbaroptions(parts)
		_:
			skipped[name] = skipped.get(name, 0) + 1

# m_btn_height: a share of imgsize in a form with size[], and seven eighths of
# a line of text in one without, which has no imgsize to speak of.
func _button_height() -> float:
	if has_size:
		return imgsize * 15.0 / 13.0 * 0.35
	return get_theme_default_font().get_height(_font_size()) * 0.875

# m_form_src->resolveText: in a node's own form, a field default, hypertext
# or hypertip that is a whole "${key}" shows that key of the node's metadata.
func _resolve(text: String) -> String:
	if item_source and item_source.has_method("resolve_text"):
		return item_source.resolve_text(text)
	return text

func _add(c: Control, pos: Vector2, size: Vector2) -> void:
	c.position = pos.floor()
	c.size = size.floor()
	current_parent.add_child(c)
	# Which element built it, in order, for the dark glass passes that ask
	# what lies behind what, and its place in the old draw order.
	c.set_meta("seq", build_seq)
	c.set_meta("fs_prio", int(LEGACY_PRIORITY.get(current_element, 0)))

# The draw order of a form older than formspec version 3
# (GUIFormSpecMenu::legacySortElements, from the priorities each parse
# function gives its FieldSpec): boxes, then everything else, then images,
# item images and item buttons, lists, and labels on top. Mineclonia's
# brewing stand frames its slots with images drawn after the lists, which
# the old order puts back underneath.
const LEGACY_PRIORITY := {"box": -2, "image": 1, "item_image": 2, "item_image_button": 2,
	"list": 3, "label": 4}

# Reorders the children of the form, from `first` on, by that priority,
# keeping the build order among equals, as std::stable_sort keeps it.
func _legacy_sort(first: int) -> void:
	var kids: Array = []
	var i := 0
	for c in root.get_children():
		if c.get_index() >= first:
			kids.append([int(c.get_meta("fs_prio", 0)), i, c])
		i += 1
	kids.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	for k in kids.size():
		root.move_child(kids[k][2], first + k)
		# What lies behind what is now the drawing order, not the build
		# order, for the dark glass passes that ask.
		kids[k][2].set_meta("seq", first + k)

func _register_named_control(name: String, control: Control) -> void:
	if name == "":
		return
	named_controls[name] = control
	control.set_meta("formspec_name", name)
	control.set_meta("formspec_type", current_element)  # for describe()

func _apply_focus() -> void:
	if focus_name != "":
		var target: Control = named_controls.get(focus_name)
		if target == null:
			target = fields.get(focus_name)
		if target != null and (focus_force or not target.has_focus()):
			target.grab_focus()
			return
	_initial_focus()

# GUIFormSpecMenu::setInitialFocus, when set_focus[] named nothing: the first
# empty edit box, else the first edit box, else the first table, else the
# last button. A focused button draws no ring, as upstream draws none until
# the player navigates by keyboard.
func _initial_focus() -> void:
	var edits: Array = []
	var tables: Array = []
	var buttons: Array = []
	for c in _form_controls(root):
		if c is LineEdit or c is TextEdit:
			edits.append(c)
		elif c is Tree:
			tables.append(c)
		elif c is Button and not (c is CheckBox) and not (c is OptionButton):
			buttons.append(c)
	for e in edits:
		if (e as Control).get("text") == "":
			e.grab_focus()
			return
	if edits.size() > 0:
		edits[0].grab_focus()
	elif tables.size() > 0:
		tables[0].grab_focus()
	elif buttons.size() > 0:
		var b: Button = buttons.back()
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.grab_focus()

# The form's controls in the order they were built, depth first.
static func _form_controls(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Control:
			out.append(child)
			out.append_array(_form_controls(child))
	return out

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
		bar.value -= bar.custom_step
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		bar.value += bar.custom_step
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
	var hi: int = maxi(scrollbar_options["max"], lo)
	var size := _geom(g)
	if not real_coordinates:
		size = Vector2(float(g[0]) * spacing.x, float(g[1]) * spacing.y)
	_add(bar, _pos(v), size)
	var across := floorf(size.x if vertical else size.y)
	var along := floorf(size.y if vertical else size.x)
	# CGUIScrollBar::refreshControls: arrow buttons as square as the bar is
	# thick at both ends, shown when asked for, hidden when asked, and by
	# default only on a bar at least four times as long as it is thick.
	var arrows := String(scrollbar_options["arrows"])
	var show_arrows := arrows == "show" or (arrows != "hide" and along >= across * 4.0)
	var border := across if show_arrows else 0.0
	# setPosRaw: the thumb is thumbsize parts of max - min + 1 of the room
	# between the arrows, never shorter than the bar is thick (or half its
	# length), never longer than that room.
	var thumb_area := maxf(along - border * 2.0, 1.0)
	var thumb_min := minf(across, along / 2.0)
	var span := hi - lo
	var draw_h := clampf(thumb_area * float(scrollbar_options["thumbsize"]) / float(span + 1),
		thumb_min, thumb_area)
	# Godot's Range reserves `page` at the top of its span and draws the
	# thumb page / (max - min) of the track, so the page that gives
	# upstream's thumb is solved for, and the reachable values stay the
	# [min, max] the formspec asked for.
	var page := 1.0
	if span > 0:
		page = draw_h * span / maxf(thumb_area - draw_h, 0.001)
	bar.min_value = lo
	bar.max_value = hi + page
	bar.page = page
	bar.step = 1.0
	bar.custom_step = maxf(float(scrollbar_options["smallstep"]), 1.0)
	bar.set_meta("smallstep", bar.custom_step)
	bar.value = clampf(float(int(parts[4])), lo, hi)
	var thumb := (bar.get_theme_stylebox("grabber") as StyleBox).duplicate()
	if vertical:
		thumb.content_margin_top = thumb_min / 2.0
		thumb.content_margin_bottom = thumb_min / 2.0
	else:
		thumb.content_margin_left = thumb_min / 2.0
		thumb.content_margin_right = thumb_min / 2.0
	if span == 0:
		# max == min: upstream draws the track and no thumb, and the arrows
		# greyed out, and the bar takes no input.
		thumb = StyleBoxEmpty.new()
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for key in ["grabber", "grabber_highlight", "grabber_pressed"]:
		bar.add_theme_stylebox_override(key, thumb)
	# The theme's track is as thick as EGDS_SCROLLBAR_SIZE, which is right for
	# the bars inside lists and text areas; a scrollbar[] is as thick as the
	# form says, so its own track asks for no thickness at all.
	var track := (bar.get_theme_stylebox("scroll") as StyleBox).duplicate()
	if vertical:
		track.content_margin_left = 0
		track.content_margin_right = 0
	else:
		track.content_margin_top = 0
		track.content_margin_bottom = 0
	bar.add_theme_stylebox_override("scroll", track)
	bar.add_theme_stylebox_override("scroll_focus", track)
	bar.size = Vector2(size.x, size.y).floor()
	_scrollbar_arrows(bar, vertical, int(across) if show_arrows else 0, span > 0)
	# The wheel moves a scrollbar by its small step, as CGUIScrollBar does.
	bar.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			var dir := 0
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				dir = -1
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				dir = 1
			if dir != 0:
				bar.value += dir * bar.custom_step
				bar.accept_event())
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

static var _arrow_cache := {}

# The arrow buttons at a scrollbar's ends, `size` pixels square, or none for
# 0. In the game theme they are Luanti's skin: a dark button pane with a
# light triangle, grey when the bar is disabled. In dark glass, a chevron on
# the track.
func _scrollbar_arrows(bar: ScrollBar, vertical: bool, size: int, enabled: bool) -> void:
	if size <= 0:
		# Godot's own scrollbar icons are empty, so there are no buttons.
		return
	var looks := {"": 0, "_highlight": 1, "_pressed": 2}
	for end in ["decrement", "increment"]:
		var dir: String
		if vertical:
			dir = "up" if end == "decrement" else "down"
		else:
			dir = "left" if end == "decrement" else "right"
		for suffix in looks:
			bar.add_theme_icon_override(end + suffix,
				_arrow_texture(size, dir, glass, enabled, int(looks[suffix])))

static func _arrow_texture(size: int, dir: String, glassy: bool, enabled: bool, state: int) -> Texture2D:
	var key := "%d|%s|%s|%s|%d" % [size, dir, glassy, enabled, state]
	if _arrow_cache.has(key):
		return _arrow_cache[key]
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var symbol: Color
	if glassy:
		img.fill(Color(1, 1, 1, [0.0, 0.08, 0.16][state]))
		symbol = Color(GlassStyle.TEXT_DIM, 1.0 if enabled else 0.35)
	else:
		img.fill(Color8(30, 30, 30))
		var face: Color = [Color8(62, 62, 62), Color8(78, 78, 78), Color8(50, 50, 50)][state]
		img.fill_rect(Rect2i(1, 1, size - 2, size - 2), face)
		symbol = Color8(230, 230, 230) if enabled else Color8(130, 130, 130)
	# A triangle pointing `dir`, in the middle third of the square.
	var s := float(size)
	var lo := s * 0.3
	var hi := s * 0.7
	for y in size:
		for x in size:
			var px := x + 0.5
			var py := y + 0.5
			var along: float
			var across: float
			match dir:
				"up":
					along = hi - py
					across = absf(px - s / 2.0)
				"down":
					along = py - lo
					across = absf(px - s / 2.0)
				"left":
					along = hi - px
					across = absf(py - s / 2.0)
				_:
					along = px - lo
					across = absf(py - s / 2.0)
			var depth := hi - lo
			if along >= 0.0 and along <= depth and across <= (depth - along) * 0.9:
				img.set_pixel(x, y, symbol)
	var tex := ImageTexture.create_from_image(img)
	_arrow_cache[key] = tex
	return tex

func _bgcolor(parts: PackedStringArray) -> void:
	# bgcolor[color;fullscreen;fbgcolor]
	if _chrome():
		# The theme's window colour is what the glass replaces.
		return
	if glass and parts.size() >= 2 and parts[1].strip_edges() in ["true", "both"] \
			or glass and parts.size() >= 3 and parts[2].strip_edges() != "":
		own_fullscreen = true
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
	if tex == null and not _chrome():
		return
	var auto_clip := parts.size() >= 4 and parts[3].strip_edges() == "true"
	var middle := parts[4] if parts.size() >= 5 else ""
	# In dark glass the theme's window art becomes a glass pane of the same
	# rectangle, and so does a background of the form's own that is plain
	# window art (_window_art), such as a crafting guide that draws the
	# game's panel itself.
	var pane := _chrome() or (glass and tex != null and bool(_window_art(tex)["art"]))
	var r: Control = GlassStyle.surface() if pane else _texture_rect(tex, middle)
	if pane:
		glass_panes += 1
	if auto_clip:
		# Fills the form, and the position, not the geometry, moves its
		# edges: raw pixels outward in the old coordinate system, imgsize
		# units inward in the new one (parseBackground and
		# GUIBackgroundImage::draw).
		var out := Vector2(float(v[0]), float(v[1]))
		if real_coordinates:
			out = -out * imgsize
		r.position = (-out).floor()
		r.size = (root.size + out * 2).floor()
	else:
		r.position = _pos(v).floor()
		r.size = _geom(g).floor()
	# Every background goes to one layer at the back of the form, in the
	# order the form gives them, as regenerateGui's background_parent keeps
	# them: behind all other elements, but the game theme's background9
	# still under a form's own backgrounds.
	bg_layer.add_child(r)

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
	var colour := parse_color(parts[2], Color(0, 0, 0, 0.5))
	var size := _geom(g)
	if glass and _grey_panel(colour, size):
		# A form's own box of neutral grey, at least half a slot each way, is
		# a panel (the recipe and pattern lists of Mineclonia's stonecutter
		# and loom): a sunken glass tile. A coloured box, a light one, or a
		# thin rule is content and stays.
		var tile := Panel.new()
		tile.add_theme_stylebox_override("panel", GlassStyle.tile_box(true, false))
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.set_meta("glass_box", true)
		_add(tile, _pos(v), size)
		return
	var c := ColorRect.new()
	c.color = colour
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add(c, _pos(v), size)

func _grey_panel(c: Color, size: Vector2) -> bool:
	return c.a >= 0.5 and maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) <= 12.0 / 255.0 \
		and GlassStyle.luminance(c) <= 0.5 and size.x >= imgsize * 0.5 and size.y >= imgsize * 0.5

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
	# For _replace_slot_frames: which texture, and when it was built.
	r.set_meta("fs_image", fs_unescape(parts[texture_index]).strip_edges())
	r.set_meta("seq", build_seq)

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

# label[x,y;text], and from formspec version 9 the area label
# label[x,y;w,h;text], which the old coordinate system does not have
# (parseLabel).
#
# A plain label is one element per line, each drawn from an EnrichedString
# so colour escapes keep their colour. In real coordinates line i is centred
# i half-imgsizes below y; in the old system the first line is centred on
# (y + 7/30) spacings and each next one two fifths of a slot lower. An area
# label wraps inside its rectangle, aligned by the halign and valign styles
# of formspec version 11.
func _label(parts: PackedStringArray, vertical: bool) -> void:
	if vertical:
		_vertlabel(parts)
		return
	if parts.size() < 2 or (parts.size() > 2 and not real_coordinates) or parts.size() > 3:
		return
	var v := fs_split(parts[0], ",")
	if v.size() < 2:
		return
	var st := _style_for("", "default")
	var colour := parse_color(String(st.get("textcolor", "")), Color.WHITE)
	var size := _style_font_size(String(st.get("font_size", "")), _font_size())
	var p := _pos(v)
	if parts.size() == 3:
		var g := fs_split(parts[1], ",")
		if g.size() < 2:
			return
		var area := _rich_text(fs_unescape_raw(parts[2]), colour, size, st)
		area.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		area.clip_contents = true
		area.horizontal_alignment = _style_halign(st)
		area.vertical_alignment = _style_valign(st)
		_add(area, p, _geom(g))
		return
	var btn_h := imgsize * 15.0 / 13.0 * 0.35
	var font := get_theme_default_font()
	var lines := fs_unescape_raw(parts[1]).split("\n")
	var carried := ""
	for i in lines.size():
		# EnrichedString::getNextLine carries the colour in force at the end
		# of a line into the next.
		var line := carried + lines[i]
		var runs := parse_enriched_runs(line, colour)
		if runs.size() > 0:
			carried = char(0x1b) + "(c@#" + (runs.back()["color"] as Color).to_html() + ")"
		var width := font.get_string_size(strip_enriched(line), HORIZONTAL_ALIGNMENT_LEFT,
			-1, size).x
		var rect: Rect2
		if real_coordinates:
			rect = Rect2(p.x, p.y - imgsize / 2.0 + imgsize * i / 2.0, width, imgsize)
		else:
			var y := p.y + 7.0 / 30.0 * spacing.y + i * spacing.y * 2.0 / 5.0
			rect = Rect2(p.x, y - btn_h, width, btn_h * 2.0)
		var rt := _rich_text(line, colour, size, st)
		rt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# A little slack, so rounding never clips the last glyph.
		rect.size.x += 4.0
		_add(rt, rect.position, rect.size)

# vertlabel[x,y;text]: one character per line, centred in a column one
# imgsize wide whose left edge is half an imgsize left of x in real
# coordinates, and fifteen pixels wide from x in the old system
# (parseVertLabel).
func _vertlabel(parts: PackedStringArray) -> void:
	if parts.size() != 2:
		return
	var v := fs_split(parts[0], ",")
	if v.size() < 2:
		return
	var st := _style_for("", "default")
	var colour := parse_color(String(st.get("textcolor", "")), Color.WHITE)
	var size := _style_font_size(String(st.get("font_size", "")), _font_size())
	var text := fs_unescape_raw(parts[1])
	var column := ""
	var count := 0
	for run in parse_enriched_runs(text, colour):
		for ch in String(run["text"]):
			column += char(0x1b) + "(c@#" + (run["color"] as Color).to_html() + ")" + ch + "\n"
			count += 1
	var line_h := get_theme_default_font().get_height(size)
	var p := _pos(v)
	var rect: Rect2
	if real_coordinates:
		rect = Rect2(p.x - imgsize / 2.0, p.y, imgsize, line_h * count)
	else:
		var btn_h := imgsize * 15.0 / 13.0 * 0.35
		var top := p.y + imgsize / 2.0 - btn_h
		rect = Rect2(p.x, top, 15.0, line_h * (count + 1))
	var rt := _rich_text(column.trim_suffix("\n"), colour, size, st)
	rt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_add(rt, rect.position, rect.size)

# Form text drawn from an EnrichedString: colour escapes become colour runs
# over `colour`, and the style's font picks mono, bold and italic.
func _rich_text(text: String, colour: Color, size: int, st: Dictionary) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = false
	rt.scroll_active = false
	rt.selection_enabled = false
	rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_font_size_override("normal_font_size", size)
	for key in ["bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		rt.add_theme_font_size_override(key, size)
	rt.add_theme_color_override("default_color", _ink(colour))
	var pushes := _push_style_font(rt, String(st.get("font", "")))
	var drawn: Array = []
	for run in parse_enriched_runs(text, colour):
		var c := _ink(run["color"])
		drawn.append(c)
		rt.push_color(c)
		rt.add_text(run["text"])
		rt.pop()
	# The colours the runs were drawn in, for the suite to read.
	rt.set_meta("colours", drawn)
	for _i in pushes:
		rt.pop()
	rt.set_meta("plain", strip_enriched(text))
	return rt

# The font style property as a Font for Godot's own controls: the form's
# font, or a system monospace for mono, made bold or italic by variation.
# Null for plain normal, which needs nothing changed.
func _style_font(value: String) -> Font:
	var opts := value.to_lower().replace(" ", "").split(",", false)
	var mono := opts.has("mono")
	var bold := opts.has("bold")
	var italic := opts.has("italic")
	if not (mono or bold or italic):
		return null
	var base: Font = _mono_font() if mono else get_theme_default_font()
	if not (bold or italic):
		return base
	var fv := FontVariation.new()
	fv.base_font = base
	if bold:
		fv.variation_embolden = 0.8
	if italic:
		fv.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
	return fv

# Luanti's mono font is Cousine; Goanna asks the system for its monospace
# face instead of carrying a font file.
static func _mono_font() -> Font:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["monospace"])
	return sf

# The font style property: normal or mono, with bold and italic added.
# Returns how many pushes the caller owes a pop.
static func _push_style_font(rt: RichTextLabel, value: String) -> int:
	var opts := value.to_lower().replace(" ", "").split(",", false)
	var pushes := 0
	if opts.has("mono"):
		rt.push_mono()
		pushes += 1
	if opts.has("bold") and opts.has("italic"):
		rt.push_bold_italics()
		pushes += 1
	elif opts.has("bold"):
		rt.push_bold()
		pushes += 1
	elif opts.has("italic"):
		rt.push_italics()
		pushes += 1
	return pushes

# get_halign and get_valign in guiFormSpecMenu.cpp: anything unknown is the
# default, left and top.
static func _style_halign(st: Dictionary) -> HorizontalAlignment:
	match String(st.get("halign", "")):
		"center":
			return HORIZONTAL_ALIGNMENT_CENTER
		"right":
			return HORIZONTAL_ALIGNMENT_RIGHT
	return HORIZONTAL_ALIGNMENT_LEFT

static func _style_valign(st: Dictionary) -> VerticalAlignment:
	match String(st.get("valign", "")):
		"center":
			return VERTICAL_ALIGNMENT_CENTER
		"bottom":
			return VERTICAL_ALIGNMENT_BOTTOM
	return VERTICAL_ALIGNMENT_TOP

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
# The root tag's hovercolor, which every action inherits.
const MARKUP_HOVER := "#FF0000"

# hypertext[x,y;w,h;name;text] (parseHyperText): white text, no selection.
# The old system starts it without the form padding, a button-height lower,
# with its height in slots less one gap.
func _hypertext(parts: PackedStringArray) -> void:
	if parts.size() != 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var rect: Rect2
	if real_coordinates:
		rect = Rect2(_pos(v), _geom(g))
	else:
		var p := _pos(v) - padding
		rect = Rect2(p.x, p.y + _button_height(), float(g[0]) * spacing.x - (spacing.x - imgsize),
			float(g[1]) * imgsize - (spacing.y - imgsize))
	var hname := fs_unescape(parts[2])
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = false
	rt.scroll_active = true
	rt.selection_enabled = false
	rt.add_theme_color_override("default_color", Color.WHITE)
	_add(rt, rect.position, rect.size)
	_register_named_control(hname, rt)
	var text := fs_unescape(_resolve(parts[3]))
	rt.set_meta("hovered_action", -1)
	# <action> sends "action:<name>" under the element's own field name, and
	# may carry a url, which is offered rather than opened (see _offer_url).
	var sound := _style_sound(hname)
	rt.meta_clicked.connect(func(meta: Variant) -> void:
		_play_sound(sound)
		var m: Dictionary = meta
		if String(m.get("url", "")) != "":
			_offer_url(String(m["url"]))
		if String(m.get("name", "")) != "":
			submit({hname: "action:" + String(m["name"])}, false))
	# An action is drawn in its hovercolor while the pointer is on it
	# (TextDrawer::draw), so the text is laid out again for that action.
	rt.meta_hover_started.connect(func(meta: Variant) -> void:
		var idx := int((meta as Dictionary).get("index", -1))
		if idx != int(rt.get_meta("hovered_action")):
			rt.set_meta("hovered_action", idx)
			_render_markup.call_deferred(rt, text, idx))
	rt.meta_hover_ended.connect(func(_meta: Variant) -> void:
		if int(rt.get_meta("hovered_action")) != -1:
			rt.set_meta("hovered_action", -1)
			_render_markup.call_deferred(rt, text, -1))
	_render_markup(rt, text, -1)

# Walks Luanti's hypertext markup and drives the RichTextLabel directly
# rather than translating to BBCode: <img> and <item> name client media and
# item stacks, which BBCode has no way to address. `hover` is the number of
# the action under the pointer, counted in order of appearance, or -1.
func _render_markup(rt: RichTextLabel, text: String, hover := -1) -> void:
	if not is_instance_valid(rt):
		return
	rt.clear()
	# The colour each action was drawn in, in order, for the suite to read.
	rt.set_meta("action_colours", [])
	var tags := {}
	for k in MARKUP_TAGS:
		tags[k] = (MARKUP_TAGS[k] as Dictionary).duplicate()
	var root := _apply_markup_page(rt, _markup_page(text))
	var stack: Array = [{"pops": 0, "style": root}]
	if String(root["font"]) == "mono":
		rt.push_mono()
		stack[0]["pops"] = 1
	var state := {"actions": 0, "hover": hover}
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
		_markup_tag(rt, text.substr(i + 1, close - i - 1), tags, stack, state)
		i = close + 1
	if run != "":
		rt.add_text(run)
	while stack.size() > 0:
		for _p in int(stack.pop_back()["pops"]):
			rt.pop()

# The page settings <global> carries (ParsedText::globalTag), gathered from
# the whole text wherever the tag stands, since upstream lays the page out
# after it has parsed all of it.
static func _markup_page(text: String) -> Dictionary:
	var page := {}
	var i := 0
	while i < text.length():
		var at := text.find("<", i)
		if at < 0:
			break
		if at > 0 and text[at - 1] == "\\":
			i = at + 1
			continue
		var close := _markup_tag_end(text, at)
		if close < 0:
			break
		var body := text.substr(at + 1, close - at - 1).strip_edges()
		var space := body.find(" ")
		if space >= 0 and body.substr(0, space).to_lower() == "global":
			var attrs := _markup_attrs(body.substr(space + 1))
			for k in attrs:
				page[k] = attrs[k]
		i = close + 1
	return page

# Applies the page settings to the label and returns the root style every
# span inherits. The margin, vertical alignment, background and horizontal
# alignment belong to the page; the text colour, hover colour, size and font
# change the root style, each only when valid, as parseGenericStyleAttr
# checks them.
func _apply_markup_page(rt: RichTextLabel, page: Dictionary) -> Dictionary:
	var root := {"hovercolor": MARKUP_HOVER, "size": "16", "font": "normal"}
	# A page with a background of its own keeps the colours chosen for it; on
	# glass they are made legible (_markup_ink).
	var own_bg := String(page.get("background", ""))
	rt.set_meta("own_background", own_bg != "" and own_bg != "none" and _is_colour(own_bg))
	if page.has("color") and _is_colour(String(page["color"])):
		rt.add_theme_color_override("default_color",
			_markup_ink(rt, parse_color(String(page["color"]), Color.WHITE)))
	if page.has("hovercolor") and _is_colour(String(page["hovercolor"])):
		root["hovercolor"] = page["hovercolor"]
	if page.has("size") and String(page["size"]).is_valid_int():
		root["size"] = page["size"]
	if page.get("font", "") in ["mono", "normal"]:
		root["font"] = page["font"]
	rt.add_theme_font_size_override("normal_font_size", _markup_size(String(root["size"])))
	for key in ["bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		rt.add_theme_font_size_override(key, _markup_size(String(root["size"])))
	match String(page.get("halign", "")):
		"center":
			rt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		"right":
			rt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		"justify":
			rt.horizontal_alignment = HORIZONTAL_ALIGNMENT_FILL
		_:
			rt.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	match String(page.get("valign", "")):
		"middle":
			rt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		"bottom":
			rt.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_:
			rt.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	var margin := HYPERTEXT_MARGIN
	if String(page.get("margin", "")).is_valid_int():
		margin = float(page["margin"])
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.TRANSPARENT
	var bg := String(page.get("background", ""))
	if bg != "" and bg != "none" and _is_colour(bg):
		sb.bg_color = parse_color(bg, Color.TRANSPARENT)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin
	sb.content_margin_bottom = margin
	rt.add_theme_stylebox_override("normal", sb)
	rt.set_meta("markup_margin", margin)
	return root

func _markup_ink(rt: RichTextLabel, c: Color) -> Color:
	return c if bool(rt.get_meta("own_background", false)) else _ink(c)

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

# One tag body, without its angle brackets. `stack` holds, for each open
# span, the pops it owes and the style in force inside it; the root style is
# at the bottom and is never closed.
func _markup_tag(rt: RichTextLabel, body: String, tags: Dictionary, stack: Array,
		state: Dictionary) -> void:
	body = body.strip_edges()
	if body == "":
		return
	if body.begins_with("/"):
		if stack.size() > 1:
			for _p in int(stack.pop_back()["pops"]):
				rt.pop()
		return
	var space := body.find(" ")
	var name := (body.substr(0, space) if space >= 0 else body).strip_edges().to_lower()
	var attrs := _markup_attrs(body.substr(space + 1)) if space >= 0 else {}
	match name:
		"global":
			# Page settings, already applied by _apply_markup_page.
			return
		"tag":
			# Defines or redefines a tag, which later spans can then open.
			var tname := String(attrs.get("name", "")).to_lower()
			if tname != "":
				var defined: Dictionary = tags.get(tname, {}).duplicate()
				for k in ["color", "hovercolor", "size", "font"]:
					if attrs.has(k):
						defined[k] = attrs[k]
				tags[tname] = defined
			return
		"img", "item":
			_markup_image(rt, name, attrs)
			return
	var outer: Dictionary = stack.back()["style"]
	# An opening span: either a style tag or one of the defined tags. An
	# unknown tag renders as nothing, as upstream's parser does, but still
	# takes a place on the stack so its closing tag pops only itself.
	var style: Dictionary = attrs if name == "style" else tags.get(name, {})
	if style.is_empty() and name != "style":
		stack.append({"pops": 0, "style": outer})
		return
	var inner := outer.duplicate()
	for k in style:
		inner[k] = style[k]
	var pushes := 0
	if String(style.get("halign", "")) != "":
		match String(style["halign"]):
			"center": rt.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER)
			"right": rt.push_paragraph(HORIZONTAL_ALIGNMENT_RIGHT)
			"justify": rt.push_paragraph(HORIZONTAL_ALIGNMENT_FILL)
			_: rt.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
		pushes += 1
	var colour := String(style.get("color", ""))
	if name == "action":
		var index: int = state["actions"]
		state["actions"] = index + 1
		rt.push_meta({"index": index, "name": String(attrs.get("name", "")),
			"url": String(attrs.get("url", ""))})
		pushes += 1
		if index == int(state["hover"]):
			colour = String(inner.get("hovercolor", MARKUP_HOVER))
		var drawn: Array = rt.get_meta("action_colours", [])
		drawn.append(colour)
		rt.set_meta("action_colours", drawn)
	if colour != "" and _is_colour(colour):
		rt.push_color(_markup_ink(rt, parse_color(colour, Color.WHITE)))
		pushes += 1
	if String(style.get("size", "")).is_valid_int():
		rt.push_font_size(_markup_size(String(style["size"])))
		pushes += 1
	match String(style.get("font", "")):
		"mono":
			rt.push_mono()
			pushes += 1
		"normal":
			rt.push_font(rt.get_theme_font("normal_font"))
			pushes += 1
	if _is_yes(String(style.get("bold", ""))):
		rt.push_bold()
		pushes += 1
	if _is_yes(String(style.get("italic", ""))):
		rt.push_italics()
		pushes += 1
	if _is_yes(String(style.get("underline", ""))):
		rt.push_underline()
		pushes += 1
	stack.append({"pops": pushes, "style": inner})

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
	var r := _btn_geom(g)
	_add(b, _pos(v) + r.position, r.size)
	if kind.begins_with("button_url") and parts.size() >= 5:
		b.set_meta("url", fs_unescape(parts[4]))
	if kind == "button_key":
		_key_button(b, bname, label)
		return
	var content := _button_content(b, label, false)
	_wire_button(b, bname, label, exit)
	_style_button(b, bname, _style_states(bname), content)

# --- button_key (GUIButtonKey) ----------------------------------------------

# The button whose next key or mouse button is being captured, or null.
var key_capture: Button = null

# button_key[x,y;w,h;name;key]: the key is a key setting string, which the
# button shows by the key's name. Pressing it shows "Press Button" and takes
# the next key or mouse button as its value, which goes to the server as the
# element's field, a SYSTEM_SCANCODE_ or MOUSE_BUTTON_ string, as sendKey
# and acceptInput send it. Escape stops capturing and keeps the old key.
func _key_button(b: Button, bname: String, value: String) -> void:
	var sym := _key_sym_of(value)
	b.set_meta("key_value", sym)
	var content := _button_content(b, _key_name_of(sym), false)
	_register_named_control(bname, b)
	var sound := _style_sound(bname)
	b.pressed.connect(func() -> void:
		if key_capture == b:
			return
		key_capture = b
		var label: Label = content["label"]
		if label:
			label.text = "Press Button")
	b.set_meta("key_send", func() -> void:
		_play_sound(sound)
		submit({bname: String(b.get_meta("key_value"))}, false))
	_style_button(b, bname, _style_states(bname), content)

# Ends a capture, keeping `sym` when given, and sends the form if it took a
# new key.
func _end_key_capture(sym: String) -> void:
	var b := key_capture
	key_capture = null
	if b == null or not is_instance_valid(b):
		return
	if sym != "":
		b.set_meta("key_value", sym)
	var label: Label = b.get_meta("content", {}).get("label")
	if label:
		label.text = _key_name_of(String(b.get_meta("key_value")))
	if sym != "":
		(b.get_meta("key_send") as Callable).call()

# While a key button captures, every key and mouse button goes to it first,
# as the focused element gets events first in Irrlicht.
func _capture_key(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE or k.physical_keycode == KEY_ESCAPE:
			_end_key_capture("")
		else:
			_end_key_capture(_key_sym_of_event(k))
		return true
	if event is InputEventMouseButton and event.pressed:
		var sdl: int = MOUSE_TO_SDL.get((event as InputEventMouseButton).button_index, 0)
		if sdl == 0:
			return false
		_end_key_capture("MOUSE_BUTTON_%d" % sdl)
		return true
	return false

# Godot's mouse buttons as SDL numbers them.
const MOUSE_TO_SDL := {MOUSE_BUTTON_LEFT: 1, MOUSE_BUTTON_MIDDLE: 2, MOUSE_BUTTON_RIGHT: 3,
	MOUSE_BUTTON_XBUTTON1: 4, MOUSE_BUTTON_XBUTTON2: 5}
const SDL_MOUSE_NAMES := {1: "Left Click", 2: "Middle Click", 3: "Right Click", 4: "Mouse X1",
	5: "Mouse X2"}

# Keys as Luanti 5.17 knows them: [Godot physical key, SDL scancode (the USB
# HID usage), Irrlicht key name as older settings wrote it, key name shown].
static func _key_table() -> Array:
	var t: Array = []
	for i in 26:
		var ch := char(65 + i)
		t.append([KEY_A + i, 4 + i, "KEY_KEY_" + ch, ch])
	for i in 9:
		t.append([KEY_1 + i, 30 + i, "KEY_KEY_%d" % (i + 1), str(i + 1)])
	t.append([KEY_0, 39, "KEY_KEY_0", "0"])
	t.append_array([[KEY_ENTER, 40, "KEY_RETURN", "Return"], [KEY_ESCAPE, 41, "KEY_ESCAPE", "Escape"],
		[KEY_BACKSPACE, 42, "KEY_BACK", "Backspace"], [KEY_TAB, 43, "KEY_TAB", "Tab"],
		[KEY_SPACE, 44, "KEY_SPACE", "Space"], [KEY_MINUS, 45, "KEY_MINUS", "-"],
		[KEY_EQUAL, 46, "KEY_PLUS", "="], [KEY_BRACKETLEFT, 47, "KEY_OEM_4", "["],
		[KEY_BRACKETRIGHT, 48, "KEY_OEM_6", "]"], [KEY_BACKSLASH, 49, "KEY_OEM_5", "\\"],
		[KEY_SEMICOLON, 51, "KEY_OEM_1", ";"], [KEY_APOSTROPHE, 52, "KEY_OEM_7", "'"],
		[KEY_QUOTELEFT, 53, "KEY_OEM_3", "`"], [KEY_COMMA, 54, "KEY_COMMA", ","],
		[KEY_PERIOD, 55, "KEY_PERIOD", "."], [KEY_SLASH, 56, "KEY_OEM_2", "/"],
		[KEY_CAPSLOCK, 57, "KEY_CAPITAL", "Caps Lock"]])
	for i in 12:
		t.append([KEY_F1 + i, 58 + i, "KEY_F%d" % (i + 1), "F%d" % (i + 1)])
	t.append_array([[KEY_INSERT, 73, "KEY_INSERT", "Insert"], [KEY_HOME, 74, "KEY_HOME", "Home"],
		[KEY_PAGEUP, 75, "KEY_PRIOR", "Page Up"], [KEY_DELETE, 76, "KEY_DELETE", "Delete"],
		[KEY_END, 77, "KEY_END", "End"], [KEY_PAGEDOWN, 78, "KEY_NEXT", "Page Down"],
		[KEY_RIGHT, 79, "KEY_RIGHT", "Right"], [KEY_LEFT, 80, "KEY_LEFT", "Left"],
		[KEY_DOWN, 81, "KEY_DOWN", "Down"], [KEY_UP, 82, "KEY_UP", "Up"]])
	for i in 9:
		t.append([KEY_KP_1 + i, 89 + i, "KEY_NUMPAD%d" % (i + 1), "Keypad %d" % (i + 1)])
	t.append([KEY_KP_0, 98, "KEY_NUMPAD0", "Keypad 0"])
	# Modifiers: the right hand ones are told apart by location below.
	t.append_array([[KEY_CTRL, 224, "KEY_LCONTROL", "Left Control"],
		[KEY_SHIFT, 225, "KEY_LSHIFT", "Left Shift"], [KEY_ALT, 226, "KEY_LMENU", "Left Alt"],
		[-1, 228, "KEY_RCONTROL", "Right Control"], [-1, 229, "KEY_RSHIFT", "Right Shift"],
		[-1, 230, "KEY_RMENU", "Right Alt"]])
	return t

static func _key_sym_of_event(k: InputEventKey) -> String:
	var key := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
	var right := k.location == KEY_LOCATION_RIGHT
	for row in _key_table():
		if int(row[0]) == int(key):
			var code: int = row[1]
			if right and code >= 224 and code <= 226:
				code += 4
			return "SYSTEM_SCANCODE_%d" % code
	return ""

# A key setting string as KeyPress stores it: SYSTEM_SCANCODE_ and
# MOUSE_BUTTON_ strings as they are, an Irrlicht key name by its scancode.
static func _key_sym_of(value: String) -> String:
	var v := value.strip_edges()
	if v.begins_with("SYSTEM_SCANCODE_") or v.begins_with("MOUSE_BUTTON_"):
		return v
	for row in _key_table():
		if row[2] == v:
			return "SYSTEM_SCANCODE_%d" % int(row[1])
	return v

# KeyPress::name: the key's name, or "Scancode: n" for one Goanna does not
# know by name.
static func _key_name_of(sym: String) -> String:
	if sym.begins_with("SYSTEM_SCANCODE_"):
		var code := sym.substr(16).to_int()
		for row in _key_table():
			if int(row[1]) == code:
				return String(row[3])
		return "Scancode: %d" % code
	if sym.begins_with("MOUSE_BUTTON_"):
		var n := sym.substr(13).to_int()
		return String(SDL_MOUSE_NAMES.get(n, "Mouse Button %d" % n))
	return sym

# image_button[x,y;w,h;texture;name;label;noclip;drawborder;pressed texture]
#
# Built as parseImageButton builds it: the texture is the default state's
# fgimg and the pressed texture the pressed state's, set over whatever the
# theme said, and noclip and drawborder likewise override the theme for the
# default state. Six parts is an error upstream and draws nothing.
func _image_button(parts: PackedStringArray, exit: bool) -> void:
	if parts.size() < 5 or parts.size() == 6:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var b := Button.new()
	var bname := fs_unescape(parts[3])
	var label := fs_unescape(parts[4])
	_add(b, _pos(v), _geom(g))
	var states := _style_states(bname)
	var image := fs_unescape(parts[2])
	if image != "":
		states[0]["fgimg"] = image
	if parts.size() >= 8 and fs_unescape(parts[7]) != "":
		states[STATE_PRESSED]["fgimg"] = fs_unescape(parts[7])
	if parts.size() >= 7:
		states[0]["noclip"] = parts[5].strip_edges()
		states[0]["border"] = parts[6].strip_edges()
	var content := _button_content(b, label)
	_wire_button(b, bname, label, exit)
	_style_button(b, bname, states, content)

# item_image_button[x,y;w,h;item name;name;label]
#
# The item is drawn behind the label, filling the content area, and the
# button's tooltip is the item's description, which parseItemImageButton
# registers under the button's name before any tooltip[] can replace it.
func _item_image_button(parts: PackedStringArray) -> void:
	if parts.size() < 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var b := Button.new()
	var item := fs_unescape(parts[2])
	var bname := fs_unescape(parts[3])
	var label := fs_unescape(parts[4])
	_add(b, _pos(v), _geom(g))
	var content := _button_content(b, label)
	content["item"] = item_source.item_icon(item.get_slice(" ", 0)) if item_source else null
	if not tooltips.has(bname) and item_source and item_source.has_method("item_description"):
		var desc := String(item_source.item_description(item))
		if desc != "":
			tooltips[bname] = {"text": desc, "bg": listcolors["tooltip_bg"],
				"fg": listcolors["tooltip_fg"]}
	_wire_button(b, bname, label, false)
	_style_button(b, bname, _style_states(bname), content)

# The children a GUIButton keeps: its label, a StaticText centred in the
# content rectangle, and for GUIButtonImage and GUIButtonItemImage an image
# sent to the back of it. Godot draws a button's own text under its children
# and without Luanti's text shadow, so every button carries its label as a
# child Label instead, and leaves its own text empty.
func _button_content(b: Button, label: String, with_image := true) -> Dictionary:
	var rect: NinePatchRect = null
	if with_image:
		# A nine-patch with no margins stretches the whole texture over the
		# rectangle, which is how upstream scales it; fgimg_middle gives it
		# some.
		rect = NinePatchRect.new()
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(rect)
	var text: Label = null
	if label != "":
		text = Label.new()
		text.text = label
		text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		text.clip_text = true
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text.add_theme_font_size_override("font_size", _font_size())
		b.add_child(text)
	b.set_meta("label", label)
	return {"image": rect, "label": text}

func _wire_button(b: Button, bname: String, label: String, exit: bool) -> void:
	_register_named_control(bname, b)
	var sound := _style_sound(bname)
	b.pressed.connect(func() -> void:
		_play_sound(sound)
		if b.has_meta("url"):
			_offer_url(String(b.get_meta("url")))
		submit({bname: label}, exit))

# The sound style property, read when the element is built: upstream keeps
# it on the element's FieldSpec and plays it locally, not through the
# server, when a button is pressed, a checkbox or dropdown changes, a tab is
# chosen or a hypertext action is followed.
func _style_sound(ename: String) -> String:
	return String(_style_for(ename, "default").get("sound", ""))

func _play_sound(sound: String) -> void:
	if sound != "" and item_source and item_source.has_method("play_form_sound"):
		item_source.play_form_sound(sound)

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

# field[x,y;w,h;name;label;default], field[name;label;default],
# pwdfield[x,y;w,h;name;label] and textarea[x,y;w,h;name;label;default]
# (parseField, parsePwdField, parseTextArea). textarea shares parseField, so
# three or four parts make it an unpositioned single line field too.
func _field(parts: PackedStringArray, password: bool) -> void:
	if password:
		if parts.size() == 4:
			_text_field(parts, fs_unescape(parts[2]), fs_unescape_raw(parts[3]), "", false, true)
		return
	if parts.size() == 3 or parts.size() == 4:
		_simple_field(parts)
	elif parts.size() == 5:
		_text_field(parts, fs_unescape(parts[2]), fs_unescape_raw(parts[3]),
			fs_unescape(_resolve(parts[4])), false, false)

func _textarea(parts: PackedStringArray) -> void:
	if parts.size() == 3 or parts.size() == 4:
		_simple_field(parts)
	elif parts.size() == 5:
		_text_field(parts, fs_unescape(parts[2]), fs_unescape_raw(parts[3]),
			fs_unescape(_resolve(parts[4])), true, false)

# A positioned field, password field or textarea. In real coordinates the
# rectangle is the element's own. In the old system it starts without the
# form padding; a field is two button-heights tall, centred on y plus half
# its height in slots, and a textarea starts a button-height lower with its
# height in slots less one gap.
func _text_field(parts: PackedStringArray, fname: String, label: String, def: String,
		multiline: bool, password: bool) -> void:
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var rect: Rect2
	if real_coordinates:
		rect = Rect2(_pos(v), _geom(g))
	else:
		var btn_h := imgsize * 15.0 / 13.0 * 0.35
		var p := _pos(v) - padding
		var w := float(g[0]) * spacing.x - (spacing.x - imgsize)
		if multiline:
			rect = Rect2(p.x, p.y + btn_h, w,
				float(g[1]) * imgsize - (spacing.y - imgsize))
		else:
			rect = Rect2(p.x, p.y + float(g[1]) * imgsize / 2.0 - btn_h, w, btn_h * 2.0)
	_create_text_field(rect, fname, label, def, multiline, password)

# field[name;label;default]: one centred above another, three hundred pixels
# wide, sixty apart (parseSimpleField).
func _simple_field(parts: PackedStringArray) -> void:
	var rect := Rect2(root.size.x / 2.0 - 150.0, (simple_field_count + 2) * 60.0, 300.0,
		_button_height() * 2.0)
	simple_field_count += 1
	current_element = "field"
	_create_text_field(rect, fs_unescape(parts[0]), fs_unescape_raw(parts[1]),
		fs_unescape(_resolve(parts[2])), false, false)

# createTextField. A field with no name is only its label, drawn in the
# field's rectangle; a textarea with no name is read only, has no pane, and
# shows its label as its text when it has no default. Otherwise the edit box
# takes the field's style and its label sits above it, a line of text high,
# in the same style.
func _create_text_field(rect: Rect2, fname: String, label: String, def: String,
		multiline: bool, password: bool) -> void:
	var st := _style_for(fname, "default")
	var colour := parse_color(String(st.get("textcolor", "")), Color.WHITE)
	var size := _style_font_size(String(st.get("font_size", "")), _font_size())
	if fname == "" and not multiline and not password:
		var only := _rich_text(label, colour, size, st)
		only.clip_contents = true
		_add(only, rect.position, rect.size)
		return
	if fname == "" and multiline and def == "" and label != "":
		def = strip_enriched(label)
		label = ""
	if label != "":
		var font_h := get_theme_default_font().get_height(size)
		var above := _rich_text(label, colour, size, st)
		_add(above, rect.position - Vector2(0, font_h), Vector2(rect.size.x, font_h))
	if fname == "" and multiline:
		var reader := _rich_text(def, colour, size, st)
		reader.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		reader.scroll_active = true
		reader.horizontal_alignment = _style_halign(st)
		reader.vertical_alignment = _style_valign(st)
		_add(reader, rect.position, rect.size)
		return
	var e: Control
	if multiline:
		var te := TextEdit.new()
		te.text = def
		te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		e = te
	else:
		var le := LineEdit.new()
		le.secret = password
		le.text = def
		le.alignment = _style_halign(st)
		e = le
	e.add_theme_font_size_override("font_size", size)
	_edit_box_look(e, multiline)
	_add(e, rect.position, rect.size)
	fields[fname] = e
	_register_named_control(fname, e)
	_apply_style(e, fname)
	if e is LineEdit:
		(e as LineEdit).text_submitted.connect(func(_t: String) -> void:
			var quit: bool = field_close_on_enter.get(fname, true)
			submit({"key_enter": "true", "key_enter_field": fname}, quit))

# CGUIEditBox in Luanti's skin: a sunken pane in EGDC_EDITABLE grey that
# turns EGDC_FOCUSED_EDITABLE green while focused. A textarea's
# GUIEditBoxWithScrollBar fills with EGDC_WINDOW's translucent white instead,
# focused or not. Text is white until textcolor says otherwise, and a
# selection is EGDC_HIGH_LIGHT.
func _edit_box_look(e: Control, multiline: bool) -> void:
	if glass:
		# The glass Theme's edit box, on the form's root.
		return
	var fill := Color8(255, 255, 255, 101) if multiline else Color8(128, 128, 128)
	e.add_theme_stylebox_override("normal", _sunken_pane(fill))
	e.add_theme_stylebox_override("focus",
		StyleBoxEmpty.new() if multiline else _sunken_pane(Color8(96, 134, 49)))
	e.add_theme_color_override("font_color", Color.WHITE)
	e.add_theme_color_override("selection_color", Color8(70, 120, 50))

# draw3DSunkenPane with Luanti's skin colours, whose shadow and highlight are
# both near black: a filled rectangle inside a dark one pixel frame, with the
# text kept a few pixels off it.
static func _sunken_pane(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_border_width_all(1)
	sb.border_color = Color8(0, 0, 0)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb

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
	var sound := _style_sound(cname)
	c.toggled.connect(func(_on: bool) -> void:
		_play_sound(sound)
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
	o.set_meta("index_event", parts.size() >= 6 and _is_yes(parts[5]))
	o.add_theme_font_size_override("font_size", _font_size())
	# parseDropDown: a width alone means one imgsize high in real
	# coordinates; the old system ignores any height, measures the width in
	# vertical spacings, and is two button-heights high.
	var size: Vector2
	if real_coordinates:
		size = _geom(g) if g.size() >= 2 else Vector2(float(g[0]) * imgsize, imgsize)
	else:
		size = Vector2(float(g[0]) * spacing.y, imgsize * 15.0 / 13.0 * 0.35 * 2.0)
	_add(o, _pos(v), size)
	fields[dname] = o
	_register_named_control(dname, o)
	_apply_style(o, dname)
	var sound := _style_sound(dname)
	o.item_selected.connect(func(_i: int) -> void:
		_play_sound(sound)
		submit({dname: _dropdown_value(o)}, false, false))

# textlist[x,y;w,h;name;items;selected;transparent] (parseTextList and
# GUITable::setTextList). An item starting #RRGGBB is drawn in that colour;
# a leading ## is dropped and keeps what follows from being read as one. In
# the old system the size is in whole spacings.
func _textlist(parts: PackedStringArray) -> void:
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
		var colour: Variant = null
		if t.begins_with("##"):
			t = t.substr(2)
		elif t.begins_with("#") and t.length() >= 7 and _is_colour(t.substr(0, 7)):
			colour = parse_color(t.substr(0, 7), Color.WHITE)
			t = t.substr(7)
		var i := il.add_item(t)
		if colour != null:
			il.set_item_custom_fg_color(i, _ink(colour))
	if parts.size() >= 5 and int(parts[4]) > 0 and int(parts[4]) <= il.item_count:
		il.select(int(parts[4]) - 1)
	il.add_theme_font_size_override("font_size", _font_size())
	var transparent := parts.size() >= 6 and _is_yes(parts[5])
	if glass:
		_glass_table_look(il, {"transparent": transparent})
	else:
		_table_look(il, Color8(30, 30, 30, 0) if transparent else Color8(30, 30, 30),
			not transparent, Color.WHITE, Color8(70, 120, 50), Color.WHITE)
	_add(il, _pos(v), _list_geom(g))
	fields[lname] = il
	_register_named_control(lname, il)
	_apply_style(il, lname)
	il.item_selected.connect(func(i: int) -> void:
		submit({lname: "CHG:" + str(i + 1)}, false))
	il.item_activated.connect(func(i: int) -> void:
		submit({lname: "DCL:" + str(i + 1)}, false))

# textlist[] and table[] size: in the old system whole spacings, with no
# gap taken off as other elements take it.
func _list_geom(g: PackedStringArray) -> Vector2:
	if real_coordinates:
		return _geom(g)
	return Vector2(float(g[0]) * spacing.x, float(g[1]) * spacing.y)

# GUITable's look in Luanti's skin, which textlist[] and table[] share: a
# sunken pane in EGDC_3D_HIGH_LIGHT's near black, or no pane at all, white
# text, rows a line of text and four pixels high, and the selected row in
# EGDC_HIGH_LIGHT green with EGDC_HIGH_LIGHT_TEXT. Nothing marks the row
# under the pointer.
func _table_look(c: Control, background: Color, border: bool, text: Color, highlight: Color,
		highlight_text: Color) -> void:
	var pane: StyleBox
	if border:
		pane = _sunken_pane(background)
	elif background.a > 0.0:
		var flat := StyleBoxFlat.new()
		flat.bg_color = background
		pane = flat
	else:
		pane = StyleBoxEmpty.new()
	pane.content_margin_left = 1
	pane.content_margin_right = 1
	pane.content_margin_top = 1
	pane.content_margin_bottom = 1
	c.add_theme_stylebox_override("panel", pane)
	c.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var sel := StyleBoxFlat.new()
	sel.bg_color = highlight
	for key in ["selected", "selected_focus", "hovered_selected", "hovered_selected_focus"]:
		c.add_theme_stylebox_override(key, sel)
	for key in ["hovered", "cursor", "cursor_unfocused"]:
		c.add_theme_stylebox_override(key, StyleBoxEmpty.new())
	c.add_theme_color_override("font_color", text)
	c.add_theme_color_override("font_hovered_color", text)
	c.add_theme_color_override("font_selected_color", highlight_text)
	c.add_theme_color_override("font_hovered_selected_color", highlight_text)
	# GUITable draws no rule between rows.
	c.add_theme_color_override("guide_color", Color.TRANSPARENT)
	c.add_theme_constant_override("v_separation", 4)

# A textlist or table in dark glass: the glass Theme's pane and rows, with
# whatever the form itself chose on top. A form that gives its own background
# keeps its own text colours, which were chosen for it; otherwise they are
# made legible on the glass.
func _glass_table_look(c: Control, own: Dictionary) -> void:
	c.add_theme_constant_override("v_separation", 4)
	var has_bg := own.has("background")
	if has_bg:
		var flat := StyleBoxFlat.new()
		flat.bg_color = parse_color(String(own["background"]), Color.TRANSPARENT)
		flat.set_corner_radius_all(int(GlassStyle.RADIUS_SMALL))
		flat.set_content_margin_all(1)
		c.add_theme_stylebox_override("panel", flat)
	elif bool(own.get("transparent", false)) \
			or (own.has("border") and not _is_yes(String(own["border"]))):
		var none := StyleBoxEmpty.new()
		none.set_content_margin_all(1)
		c.add_theme_stylebox_override("panel", none)
	if own.has("highlight"):
		var sel := StyleBoxFlat.new()
		sel.bg_color = parse_color(String(own["highlight"]), GlassStyle.SELECTION)
		sel.set_corner_radius_all(4)
		for key in ["selected", "selected_focus", "hovered_selected", "hovered_selected_focus"]:
			c.add_theme_stylebox_override(key, sel)
	if own.has("color"):
		var text := parse_color(String(own["color"]), GlassStyle.TEXT)
		if not has_bg:
			text = _ink(text)
		c.add_theme_color_override("font_color", text)
		c.add_theme_color_override("font_hovered_color", text)
	if own.has("highlight_text"):
		var hl := parse_color(String(own["highlight_text"]), Color.WHITE)
		c.add_theme_color_override("font_selected_color", hl)
		c.add_theme_color_override("font_hovered_selected_color", hl)

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
			var own_bg := table_options.has("background")
			if has_pending:
				item.set_custom_color(ci, pending if own_bg else _ink(pending))
			elif table_options.has("color"):
				var cc := parse_color(String(table_options["color"]), Color.WHITE)
				item.set_custom_color(ci, cc if own_bg else _ink(cc))
			if String(icons[ci]) != "" and item_source:
				var tex: Texture2D = item_source.ui_texture(String(icons[ci]))
				if tex:
					item.set_icon(ci, tex)

	_add(t, _pos(v), _list_geom(g))
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

# GUITable::setTable's options over the skin's defaults: text colour,
# background, border, highlight and highlight text.
func _apply_table_options(t: Tree) -> void:
	if glass:
		var own := {}
		for key in ["background", "border", "color", "highlight", "highlight_text"]:
			if table_options.has(key):
				own[key] = table_options[key]
		_glass_table_look(t, own)
		return
	var border := true
	if table_options.has("border"):
		border = _is_yes(String(table_options["border"]))
	_table_look(t,
		parse_color(String(table_options.get("background", "")), Color8(30, 30, 30)), border,
		parse_color(String(table_options.get("color", "")), Color.WHITE),
		parse_color(String(table_options.get("highlight", "")), Color8(70, 120, 50)),
		parse_color(String(table_options.get("highlight_text", "")), Color.WHITE))

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

# tabheader[x,y;name;captions;current;transparent;draw_border], and in real
# coordinates tabheader[x,y;h;...] or tabheader[x,y;w,h;...] (parseTabHeader).
# The position is the header's bottom edge. It is two button-heights tall
# unless given a height, and as wide as the form unless given a width. In
# the old system the position is in spacings without the form padding.
func _tabheader(parts: PackedStringArray) -> void:
	if parts.size() < 4 or parts.size() > 7 or parts.size() == 5 \
			or (parts.size() == 7 and not real_coordinates):
		return
	var v := fs_split(parts[0], ",")
	if v.size() < 2:
		return
	var idx := 1
	var btn_h := imgsize * 15.0 / 13.0 * 0.35
	var size := Vector2(root.size.x, btn_h * 2.0)
	if parts.size() == 7:
		idx = 2
		var g := fs_split(parts[1], ",")
		if g.size() == 1:
			size.y = float(g[0]) * imgsize
		elif g.size() >= 2:
			size = Vector2(float(g[0]), float(g[1])) * imgsize
	var tname := fs_unescape(parts[idx])
	var tb := TabBar.new()
	for cap in fs_split(parts[idx + 1], ","):
		tb.add_tab(fs_unescape(cap))
	var cur := int(parts[idx + 2]) - 1
	if cur >= 0 and cur < tb.tab_count:
		tb.current_tab = cur
	tb.add_theme_font_size_override("font_size", _font_size())
	var p: Vector2
	if real_coordinates:
		p = _pos(v)
	else:
		p = (pos_offset + Vector2(float(v[0]), float(v[1]))) * spacing
	current_parent.add_child(tb)
	tb.position = Vector2(p.x, p.y - size.y).floor()
	tb.size = size.floor()
	fields[tname] = tb
	_register_named_control(tname, tb)
	_apply_style(tb, tname)
	var sound := _style_sound(tname)
	tb.tab_changed.connect(func(i: int) -> void:
		_play_sound(sound)
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
			s.set_meta("seq", build_seq)
			s.set_meta("list", build_seq)
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

# listcolors[slot_bg_normal;slot_bg_hover;slot_border;tooltip_bgcolor;tooltip_fontcolor]
#
# parseListColors: four parts is an error, a border colour that parses turns
# the slot borders on, and the tooltip colours become the default for every
# tooltip parsed after this and for every item tooltip.
func _listcolors(parts: PackedStringArray) -> void:
	if parts.size() < 2 or parts.size() == 4:
		return
	if glass:
		# Slot and tooltip colours are window chrome whoever sets them: in
		# dark glass every slot and tooltip is drawn in the glass look.
		return
	listcolors["slot_bg"] = parse_color(parts[0], listcolors["slot_bg"])
	listcolors["slot_bg_h"] = parse_color(parts[1], listcolors["slot_bg_h"])
	if parts.size() >= 3 and _is_colour(parts[2]):
		listcolors["slot_border"] = parse_color(parts[2], listcolors["slot_border"])
		listcolors["slot_border_on"] = true
	if parts.size() >= 5:
		listcolors["tooltip_bg"] = parse_color(parts[3], listcolors["tooltip_bg"])
		listcolors["tooltip_fg"] = parse_color(parts[4], listcolors["tooltip_fg"])

# Whether parseColorString would accept this.
static func _is_colour(s: String) -> bool:
	var probe := Color(0.123, 0.456, 0.789, 0.321)
	return parse_color(s, probe) != probe

# tooltip[element name;text;bgcolor;fontcolor] or
# tooltip[x,y;w,h;text;bgcolor;fontcolor]
#
# The named form was gathered by _build. The area form is a hover rectangle
# that takes no input, as upstream's hidden rect element takes none, with
# its size in whole spacings in the old coordinate system (parseTooltip).
func _tooltip(parts: PackedStringArray) -> void:
	if not parts[0].contains(","):
		return
	if parts.size() != 3 and parts.size() != 5:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var bg: Color = listcolors["tooltip_bg"]
	var fg: Color = listcolors["tooltip_fg"]
	if parts.size() == 5:
		if not (_is_colour(parts[3]) and _is_colour(parts[4])):
			return
		bg = parse_color(parts[3], bg)
		fg = parse_color(parts[4], fg)
	_add_tooltip_area(v, g, {"text": fs_unescape_raw(parts[2]), "bg": bg, "fg": fg})

func _add_tooltip_area(v: PackedStringArray, g: PackedStringArray, tip: Dictionary) -> void:
	var area := Control.new()
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var size := _geom(g)
	if not real_coordinates:
		size = Vector2(float(g[0]) * spacing.x, float(g[1]) * spacing.y)
	_add(area, _pos(v), size)
	tooltip_areas.append({"area": area, "tip": tip})

# hypertip[element name;staticPos;width;name;text] or
# hypertip[x,y;w,h;staticPos;width;name;text], formspec version 11.
#
# Hypertext markup in a tooltip (parseHyperTip): width is in ems of the form
# text, staticPos, when given, pins it to a spot in the form instead of the
# pointer, and style[] on the hypertip's own name sets its bgcolor, border
# and bgimg.
func _hypertip(parts: PackedStringArray) -> void:
	var area_mode := parts[0].contains(",")
	var at := 2 if area_mode else 1
	if parts.size() < at + 4:
		return
	var static_pos: Variant = null
	if parts[at].strip_edges() != "":
		var s := fs_split(parts[at], ",")
		if s.size() != 2:
			return
		static_pos = _pos(s)
	var tip := {"markup": fs_unescape_raw(_resolve(parts[at + 3])),
		"width": float(parts[at + 1]) * _font_size(), "static": static_pos,
		"name": fs_unescape(parts[at + 2])}
	if not area_mode:
		# Coloured and styled when first shown, from what is in force then,
		# as upstream builds the element on first hover.
		hypertips[fs_unescape(parts[0])] = tip
		return
	tip["style"] = _style_for(tip["name"], "default")
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	tip["bg"] = listcolors["tooltip_bg"]
	tip["fg"] = listcolors["tooltip_fg"]
	tip["parent"] = current_parent
	_add_tooltip_area(v, g, tip)

# --- the tooltip (GUIFormSpecMenu::drawMenu, showTooltip, showHyperTip) -----

# tooltip_show_delay's default: how long the pointer rests on an element
# before that element's own tooltip appears. Area and item tooltips do not
# wait.
const TOOLTIP_DELAY_MS := 400
# TextDrawer's default margin around hypertext.
const HYPERTEXT_MARGIN := 3.0

# The pointer as the last mouse event left it, in viewport coordinates:
# upstream's m_pointer, kept from events so that input pushed into the
# viewport moves it as a real mouse does.
var pointer := Vector2(-1.0e6, -1.0e6)

func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		pointer = (event as InputEventMouse).position
	if key_capture != null and is_visible_in_tree() and _capture_key(event):
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if root == null or not is_visible_in_tree():
		_hide_tooltip()
		return
	var vp := get_viewport()
	var point := pointer
	var hovered := vp.gui_get_hovered_control()
	var name := _named_under(hovered)
	var now := Time.get_ticks_msec()
	if name != hover_name:
		hover_name = name
		hover_since = now
	var tip := tooltip_at(point, hovered, now - hover_since)
	if tip.is_empty():
		_hide_tooltip()
	else:
		_show_tooltip(tip, point)

# The formspec element a Godot control belongs to: the control itself or the
# nearest parent registered under a name.
func _named_under(c: Control) -> String:
	while c != null and c != root and c != self:
		if c.has_meta("formspec_name"):
			return String(c.get_meta("formspec_name"))
		c = c.get_parent() as Control
	return ""

func _holding_stack() -> bool:
	return item_source != null and item_source.has_method("holding_stack") \
		and item_source.holding_stack()

# The tooltip standing at `point` (viewport coordinates) with `hovered` under
# the pointer for `rested_ms`, or {}. drawMenu's order, later rules winning:
# an area tooltip, an area hypertip, the stack in the slot under the pointer
# unless one is being carried, then, once the pointer has rested on it, the
# element's own tooltip or failing that its hypertip.
func tooltip_at(point: Vector2, hovered: Control, rested_ms: int) -> Dictionary:
	var tip := {}
	for kind in ["text", "markup"]:
		for entry in tooltip_areas:
			var area: Control = entry["area"]
			var t: Dictionary = entry["tip"]
			if t.has(kind) and String(t[kind]) != "" and is_instance_valid(area) \
					and area.is_visible_in_tree() and area.get_global_rect().has_point(point):
				tip = t
				break
	if hovered is FormspecSlot and not _holding_stack():
		var item: Dictionary = (hovered as FormspecSlot).item
		if String(item.get("name", "")) != "":
			var desc := String(item.get("description", ""))
			tip = {"text": desc if desc != "" else String(item["name"]),
				"bg": listcolors["tooltip_bg"], "fg": listcolors["tooltip_fg"]}
	var name := _named_under(hovered)
	if name != "" and rested_ms >= TOOLTIP_DELAY_MS:
		if tooltips.has(name) and String(tooltips[name]["text"]) != "":
			tip = tooltips[name]
		elif hypertips.has(name):
			var h: Dictionary = hypertips[name]
			if not h.has("bg"):
				h["bg"] = listcolors["tooltip_bg"]
				h["fg"] = listcolors["tooltip_fg"]
				h["parent"] = named_controls[name].get_parent() if named_controls.has(name) else root
				var element := current_element
				current_element = "hypertip"
				h["style"] = _style_for(String(h["name"]), "default")
				current_element = element
			tip = h
	return tip

func _hide_tooltip() -> void:
	if tooltip_box != null and is_instance_valid(tooltip_box):
		tooltip_box.visible = false

# showTooltip and showHyperTip: the box follows the pointer at m_btn_height
# below and to the right of it, or stands at a hypertip's static position,
# and is pulled back on screen when it would run off an edge.
func _show_tooltip(tip: Dictionary, point: Vector2) -> void:
	if tooltip_box == null or not is_instance_valid(tooltip_box) or tip != tooltip_shown:
		if tooltip_box != null and is_instance_valid(tooltip_box):
			tooltip_box.queue_free()
		tooltip_box = _build_tooltip_box(tip)
		tooltip_shown = tip
	tooltip_box.visible = true
	var size := tooltip_box.size
	var screen := screen_size
	var btn_h := imgsize * 15.0 / 13.0 * 0.35
	var pos := point + Vector2(btn_h, btn_h)
	if tip.has("markup"):
		if tip["static"] != null:
			pos = (tip["parent"] as Control).global_position + (tip["static"] as Vector2)
		pos.x = minf(pos.x, screen.x - size.x)
		pos.y = minf(pos.y, screen.y - size.y)
	else:
		var alt := screen - size - Vector2(btn_h, btn_h)
		if alt.x < pos.x and alt.y < pos.y:
			pos = Vector2(alt.x, screen.y - 2.0 * size.y - btn_h)
		elif alt.x < pos.x:
			pos.x = alt.x
		elif alt.y < pos.y:
			pos.y = alt.y
	tooltip_box.global_position = pos.floor()

# The box for one tooltip, added to the form so it draws over it. A plain
# tooltip is its text, colour escapes and all, centred, with m_btn_height of
# width and five pixels of height added and a black frame. A hypertip is its
# markup laid out at its width, on the tooltip colours or its own style.
func _build_tooltip_box(tip: Dictionary) -> Control:
	var box := Panel.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = false
	rt.scroll_active = false
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	rt.add_theme_font_size_override("normal_font_size", _font_size())
	rt.add_theme_color_override("default_color", _ink(tip["fg"]))
	box.add_child(rt)
	var frame := StyleBoxFlat.new()
	frame.bg_color = tip["bg"]
	frame.border_color = Color.BLACK
	var panel: StyleBox = frame
	# In dark glass a tooltip is a small pane of glass, unless it is a
	# hypertip the form styled with a colour or image of its own.
	var glass_tip := glass
	if tip.has("markup"):
		var own: Dictionary = tip["style"]
		if _has_style(own, "bgcolor") or _has_style(own, "bgimg"):
			glass_tip = false
	if tip.has("markup"):
		var st: Dictionary = tip["style"]
		frame.bg_color = parse_color(String(st.get("bgcolor", "")), tip["bg"])
		if not _has_style(st, "border") or _is_yes(String(st["border"])):
			frame.set_border_width_all(1)
		if _has_style(st, "bgimg") and item_source:
			var tex: Texture2D = item_source.ui_texture(String(st["bgimg"]))
			if tex:
				var sbt := StyleBoxTexture.new()
				sbt.texture = tex
				var m := _middle_margins(String(st.get("bgimg_middle", "")), tex)
				sbt.texture_margin_left = m.x
				sbt.texture_margin_top = m.y
				sbt.texture_margin_right = m.z
				sbt.texture_margin_bottom = m.w
				panel = sbt
		# The markup's own margin, three pixels unless <global margin=...>
		# says otherwise, lies inside the label's stylebox.
		var width := maxf(float(tip["width"]), HYPERTEXT_MARGIN * 2.0 + 1.0)
		rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rt.size = Vector2(width, 1)
		_render_markup(rt, String(tip["markup"]))
		var margin: float = rt.get_meta("markup_margin", HYPERTEXT_MARGIN)
		var height := float(rt.get_content_height()) + margin * 2.0
		rt.size = Vector2(width, height).ceil()
		box.size = rt.size
	else:
		frame.set_border_width_all(1)
		var font := get_theme_default_font()
		var fs := _font_size()
		var lines := strip_enriched(String(tip["text"])).split("\n")
		var text_w := 0.0
		for line in lines:
			text_w = maxf(text_w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		var text_h := font.get_height(fs) * lines.size()
		rt.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER)
		for run in parse_enriched_runs(String(tip["text"]), tip["fg"]):
			rt.push_color(_ink(run["color"]))
			rt.add_text(run["text"])
			rt.pop()
		rt.pop()
		var btn_h := imgsize * 15.0 / 13.0 * 0.35
		box.size = Vector2(text_w + btn_h, text_h + 5.0).ceil()
		if glass_tip:
			# A little more room than Luanti's box, for the rounded corners.
			box.size += Vector2(12, 6)
		rt.size = Vector2(ceilf(text_w) + 2.0, ceilf(text_h))
		rt.position = ((box.size - rt.size) / 2.0).floor()
	if glass_tip:
		panel = StyleBoxEmpty.new()
		# The screen is copied again under the tooltip, so its frost is the
		# form beneath it rather than the world behind the form.
		var copy := BackBufferCopy.new()
		copy.copy_mode = BackBufferCopy.COPY_MODE_RECT
		copy.rect = Rect2(Vector2.ONE * -GlassStyle.GlassSurface.MARGIN,
			box.size + Vector2.ONE * GlassStyle.GlassSurface.MARGIN * 2.0)
		box.add_child(copy)
		box.move_child(copy, 0)
		var pane := GlassStyle.surface()
		pane.size = box.size
		box.add_child(pane)
		box.move_child(pane, 1)
	box.add_theme_stylebox_override("panel", panel)
	return box

# model[x,y;w,h;name;mesh;textures;rotation;continuous;mouse control;frame
# loop range;animation speed]
#
# The mesh is a client media file, loaded by the extension with Luanti's own
# model loaders and handed over already textured and posed at the first frame
# of the loop. Everything after that is upstream's GUIScene: the model sits
# centred on its bounding box in a SubViewport of its own, and a camera with a
# 30 degree vertical field of view orbits it at the distance that just fits.
# The rotation turns the camera, not the model, which is why dragging and
# continuous rotation both come out as camera moves.
#
# If the mesh cannot be had, because the media has not arrived or there is no
# client behind item_source, the old placeholder is drawn instead: drawing
# nothing leaves the game's own dark panel showing as a black void, which
# reads as broken.
func _model(parts: PackedStringArray) -> void:
	if parts.size() < 4:
		return
	var v := fs_split(parts[0], ",")
	var g := fs_split(parts[1], ",")
	if v.size() < 2 or g.size() < 2:
		return
	var mname := fs_unescape(parts[2])
	var mesh := fs_unescape(parts[3])
	var textures := PackedStringArray()
	if parts.size() >= 5:
		for t in fs_split(parts[4], ","):
			textures.append(fs_unescape(t))
	# The frame loop defaults to 0 to infinity, as upstream's does. Luanti
	# 5.17's GUIScene does not clamp it to the model's length, so a model left
	# at the default plays through once and holds its last frame; the
	# extension does the same.
	var loop := Vector2(0.0, INF)
	if parts.size() >= 9:
		var f := fs_split(parts[8], ",")
		if f.size() == 2:
			loop = Vector2(float(f[0]), float(f[1]))
	var speed := float(parts[9]) if parts.size() >= 10 else 0.0
	var preview: Dictionary = {}
	if item_source and item_source.has_method("model_preview"):
		preview = item_source.model_preview(mesh, textures, loop, speed)
	if preview.is_empty() or preview.get("node") == null:
		_model_placeholder(mname, mesh, _pos(v), _geom(g))
		return
	var rotation_xy := Vector2.ZERO
	if parts.size() >= 6:
		var r := fs_split(parts[5], ",")
		if r.size() >= 2:
			rotation_xy = Vector2(float(r[0]), float(r[1]))
	var spin := parts.size() >= 7 and _is_yes(parts[6])
	# Mouse control defaults to true, including when the field is left empty.
	var mouse_control := parts.size() < 8 or parts[7].strip_edges() == "" \
		or _is_yes(parts[7])
	var c := FormspecModel.new()
	c.setup(preview["node"], preview.get("aabb", AABB()), rotation_xy, spin, mouse_control)
	# GUIScene::setStyles: bgcolor fills the element behind the model.
	var st := _style_for(mname, "default")
	if _has_style(st, "bgcolor"):
		var back := ColorRect.new()
		back.color = parse_color(String(st["bgcolor"]), Color.TRANSPARENT)
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		c.add_child(back)
		c.move_child(back, 0)
	_add(c, _pos(v), _geom(g))
	_register_named_control(mname, c)

# is_yes in upstream's string.h: a yes, a true, or a number that is not zero.
static func _is_yes(s: String) -> bool:
	var t := s.strip_edges().to_lower()
	return t == "y" or t == "yes" or t == "true" or (t.is_valid_float() and int(float(t)) != 0)

# What model[] draws when the mesh is not available: a muted panel labelled
# with the mesh name, so the element reads as a model that failed rather than
# as a hole in the form.
func _model_placeholder(mname: String, mesh: String, pos: Vector2, geom: Vector2) -> void:
	var panel := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.17, 0.19, 0.85)
	sb.set_corner_radius_all(int(imgsize * 0.06))
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_add(panel, pos, geom)
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
	_register_named_control(mname, panel)

func _font_size() -> int:
	return maxi(int(imgsize * 0.32), 10)

# Called by a slot; forwarded to the owner.
# --- styles (style[] and style_type[]) --------------------------------------

# The type each builder asks the theme for, and the one parent type it falls
# back to, exactly as the parse functions in guiFormSpecMenu.cpp call
# getStyleForElement. image_button_exit is built by parseImageButton as a
# plain image_button, and item_image_button takes image_button's styles, which
# is how a game's style_type[image_button] also dresses its item buttons.
const STYLE_LOOKUP := {
	"button_exit": ["button_exit", "button"],
	"button_url": ["button_url", "button"],
	"button_url_exit": ["button_url_exit", "button"],
	"button_key": ["button_key", "button"],
	"image_button_exit": ["image_button", ""],
	"item_image_button": ["item_image_button", "image_button"],
	"animated_image": ["animated_image", "image"],
	"pwdfield": ["pwdfield", "field"],
	"vertlabel": ["vertlabel", "label"],
}

# The style properties that belong to the game's window art. When the theme
# sets them, dark glass drops them; when a form sets them for one of its own
# elements, they are kept.
const CHROME_STYLE_PROPS := ["bgcolor", "bgcolor_hovered", "bgcolor_pressed", "bgimg",
	"bgimg_hovered", "bgimg_pressed", "bgimg_middle", "border", "textcolor", "padding",
	"colors", "bordercolors", "borderwidths"]

# StyleSpec::State. A selector's states are OR'd into one mask.
const STATE_FOCUSED := 1
const STATE_HOVERED := 2
const STATE_PRESSED := 4
const STATE_BITS := {"default": 0, "focused": STATE_FOCUSED, "hovered": STATE_HOVERED,
	"pressed": STATE_PRESSED}
# The mask each named look reads. A pressed button is under the pointer, so
# upstream's pressed look is hovered and pressed together.
const STYLE_STATES := {
	"default": 0,
	"hovered": STATE_HOVERED,
	"pressed": STATE_HOVERED | STATE_PRESSED,
	"focused": STATE_FOCUSED,
}

# style[selector 1,selector 2,...;prop=value;...], and style_type[] with the
# same shape (GUIFormSpecMenu::parseStyle). A selector is a name or type,
# optionally followed by a colon and a +-separated list of states. A property
# without an = discards the whole element, and an unknown state discards that
# selector, as upstream does. The deprecated _hovered and _pressed properties
# become entries of their own for that state, pushed straight after the one
# they came from.
func _style(parts: PackedStringArray, by_type: bool) -> void:
	if parts.size() < 2:
		return
	var props := {}
	for i in range(1, parts.size()):
		var p := parts[i]
		var eq := p.find("=")
		if eq < 0:
			return
		props[p.substr(0, eq).strip_edges().to_lower()] = fs_unescape(p.substr(eq + 1)).strip_edges()
	if _chrome():
		# The theme's styles lose what only paints the window (panes, tints,
		# borders, the text colour chosen to suit them) and keep what sets
		# size, spacing, font, sound and alignment.
		for key in CHROME_STYLE_PROPS:
			props.erase(key)
		if props.is_empty():
			return
	var hover := {}
	var press := {}
	for key in ["bgcolor", "bgimg", "fgimg"]:
		if props.has(key + "_hovered"):
			hover[key] = props[key + "_hovered"]
		if props.has(key + "_pressed"):
			press[key] = props[key + "_pressed"]
	var target := style_by_type if by_type else style_by_name
	for raw in fs_split(parts[0], ","):
		var sel := raw.strip_edges()
		var mask := 0
		var colon := sel.find(":")
		if colon >= 0:
			var names := sel.substr(colon + 1)
			sel = sel.substr(0, colon)
			if names == "":
				continue
			var valid := true
			for st in names.split("+"):
				if not STATE_BITS.has(st):
					valid = false
					break
				mask |= int(STATE_BITS[st])
			if not valid:
				continue
		if not target.has(sel):
			target[sel] = []
		target[sel].append({"mask": mask, "props": props})
		if not hover.is_empty():
			target[sel].append({"mask": STATE_HOVERED, "props": hover})
		if not press.is_empty():
			target[sel].append({"mask": STATE_PRESSED, "props": press})

# GUIFormSpecMenu::getStyleForElement: one property set per state mask, each
# built from `*` types, `*` names, the parent type, the type and then the
# name, with a later declaration beating an earlier one.
func _style_states(ename: String) -> Array:
	var ret: Array = []
	for i in 8:
		ret.append({})
	if style_by_name.is_empty() and style_by_type.is_empty():
		return ret
	var lookup: Array = STYLE_LOOKUP.get(current_element, [current_element, ""])
	var sources: Array = [style_by_type.get("*", []), style_by_name.get("*", [])]
	if String(lookup[1]) != "":
		sources.append(style_by_type.get(lookup[1], []))
	sources.append(style_by_type.get(lookup[0], []))
	sources.append(style_by_name.get(ename, []))
	for entries in sources:
		for e in entries:
			var d: Dictionary = ret[int(e["mask"])]
			for k in e["props"]:
				d[k] = e["props"][k]
	return ret

# StyleSpec::getStyleFromStatePropagation: the default state, then every mask
# up to this one that shares a bit with it. That is upstream's rule, and it
# is looser than "every state in the selector is active".
static func _style_at(states: Array, state: int) -> Dictionary:
	var out: Dictionary = (states[0] as Dictionary).duplicate()
	for i in range(1, state + 1):
		if (state & i) != 0:
			var d: Dictionary = states[i]
			for k in d:
				out[k] = d[k]
	return out

# The properties in force for one element in one named look.
func _style_for(ename: String, state: String) -> Dictionary:
	return _style_at(_style_states(ename), int(STYLE_STATES.get(state, 0)))

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

# The looks Godot draws a button in, and the state mask each one reads.
const BUTTON_LOOKS := [["normal", 0], ["hover", STATE_HOVERED],
	["pressed", STATE_HOVERED | STATE_PRESSED]]
# The colour factors GUIButton applies to a bgcolor that only the default
# state set (COLOR_HOVERED_MOD and COLOR_PRESSED_MOD in guiButton.cpp).
const BUTTON_HOVER_MOD := 1.25
const BUTTON_PRESS_MOD := 0.85

# GUIButton::setFromStyle for one button. `states` is the per-mask property
# set from _style_states, already carrying anything the element itself set;
# `content` is the label, and for an image button the image, that
# _button_content put inside it.
#
# What carries over, in upstream's terms: bgcolor tints the bgimg (and the
# pane when there is no image); border=false drops the pane but never the
# bgimg; bgimg_middle nine-slices the bgimg and, with padding, insets the
# content; content_offset moves the content, which otherwise moves one pixel
# down and right while pressed; textcolor colours the label, white by
# default. A button its form does not style at all keeps Godot's own panel,
# as upstream keeps the skin's bevelled pane.
func _style_button(b: Button, _ename: String, states: Array, content: Dictionary) -> void:
	b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var styled := false
	for d in states:
		if not (d as Dictionary).is_empty():
			styled = true
			break
	var base: Dictionary = _style_at(states, 0)
	if _has_style(base, "font_size") and content["label"] != null:
		(content["label"] as Label).add_theme_font_size_override("font_size",
			_style_font_size(String(base["font_size"]), _font_size()))
	if _has_style(base, "font") and content["label"] != null:
		var f := _style_font(String(base["font"]))
		if f != null:
			(content["label"] as Label).add_theme_font_override("font", f)
	b.set_meta("looks", _button_looks(b, states, 0, styled))
	b.set_meta("content", content)
	b.draw.connect(func() -> void: _sync_button_content(b))
	_sync_button_content(b)
	# A focused state only exists upstream if the form asks for one; Godot
	# draws focus as an overlay instead, so a styled button swaps its looks
	# on focus and draws no overlay of its own.
	if styled:
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var uses_focus := false
		for mask in 8:
			if (mask & STATE_FOCUSED) != 0 and not (states[mask] as Dictionary).is_empty():
				uses_focus = true
		if uses_focus:
			b.focus_entered.connect(func() -> void:
				b.set_meta("looks", _button_looks(b, states, STATE_FOCUSED, true))
				b.queue_redraw())
			b.focus_exited.connect(func() -> void:
				b.set_meta("looks", _button_looks(b, states, 0, true))
				b.queue_redraw())

# The three looks of one button, for one focus bit: the panel each look
# draws, set on the button's theme when the form styles it, and the content
# rectangle, foreground image and text colour _sync_button_content places.
func _button_looks(b: Button, states: Array, focus: int, styled: bool) -> Array:
	var looks: Array = []
	for look in BUTTON_LOOKS:
		var mask: int = int(look[1]) | focus
		var st := _style_at(states, mask)
		var own: Dictionary = states[mask]
		var tint := Color.WHITE
		var tinted := _has_style(st, "bgcolor")
		if tinted:
			tint = parse_color(String(st["bgcolor"]), Color.WHITE)
			if not _has_style(own, "bgcolor"):
				if (mask & STATE_PRESSED) != 0:
					tint = _scale_rgb(tint, BUTTON_PRESS_MOD)
				elif (mask & STATE_HOVERED) != 0:
					tint = _scale_rgb(tint, BUTTON_HOVER_MOD)
		var border := _is_yes(String(st["border"])) if _has_style(st, "border") else true
		var middle := String(st.get("bgimg_middle", ""))
		var box: StyleBox = null
		var bg: Texture2D = null
		if _has_style(st, "bgimg") and item_source:
			bg = item_source.ui_texture(String(st["bgimg"]))
		if bg != null and glass and bool(_window_art(bg)["art"]):
			# A form's own button art that is plain window art, such as
			# Mineclonia's creative inventory tabs: the button becomes a
			# glass pane, and _mark_selected_art tells a lighter tab among
			# its peers, which is how the art showed which tab is chosen.
			b.set_meta("window_art_lum", float(_window_art(bg)["lum"]))
			bg = null
			box = GlassStyle.theme().get_stylebox(look[0], "Button")
			middle = ""
		elif bg != null:
			var sbt := StyleBoxTexture.new()
			sbt.texture = bg
			sbt.modulate_color = tint
			if middle != "":
				var m := _middle_margins(middle, bg)
				sbt.texture_margin_left = m.x
				sbt.texture_margin_top = m.y
				sbt.texture_margin_right = m.z
				sbt.texture_margin_bottom = m.w
			box = sbt
		elif not border:
			box = StyleBoxEmpty.new()
		elif tinted and glass:
			# The form's own colour, as a tinted glass button.
			box = _glass_tinted_button(tint)
		elif tinted:
			var sbf := StyleBoxFlat.new()
			sbf.bg_color = tint
			box = sbf
		if styled and box != null:
			b.add_theme_stylebox_override(look[0], box)
			if look[0] == "pressed":
				b.add_theme_stylebox_override("hover_pressed", box)
		# "Child padding and offset": the rectangle the label and image fill.
		var pad := _style_rect(String(st.get("padding", "")))
		var mid := _style_rect(middle)
		var off := Vector2.ZERO
		if _has_style(st, "content_offset"):
			off = _style_vec2(String(st["content_offset"])).floor()
		elif (mask & STATE_PRESSED) != 0:
			off = Vector2(1, 1)
		var tl := Vector2(pad[0] + mid[0], pad[1] + mid[1]) + off
		var br := b.size + Vector2(pad[2] + mid[2], pad[3] + mid[3]) + off
		var fg: Texture2D = null
		if _has_style(st, "fgimg") and item_source:
			fg = item_source.ui_texture(String(st["fgimg"]))
		var colour := parse_color(String(st.get("textcolor", "")), Color.WHITE)
		if glass and bg == null:
			# On glass, not on the game's own button art, whose text colour
			# was chosen for that art.
			var under := GlassStyle.control_worst()
			if box is StyleBoxFlat:
				under = GlassStyle.worst_under((box as StyleBoxFlat).bg_color)
			colour = _ink(colour, under)
		looks.append({"rect": Rect2(tl, br - tl), "fg": fg,
			"fg_middle": String(st.get("fgimg_middle", "")),
			"colour": colour})
	return looks

# A button a form coloured with bgcolor[] of its own, in dark glass: the
# colour kept, as a translucent pane with the glass button's shape and rim.
static func _glass_tinted_button(tint: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(tint, tint.a * 0.7)
	sb.border_color = Color(tint.lightened(0.35), 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(GlassStyle.RADIUS_SMALL))
	return sb

# Places a button's label, and image if it has one, for the look Godot is
# drawing. Connected to the button's draw signal, which fires on every change
# of hover, press and focus.
func _sync_button_content(b: Button) -> void:
	var looks: Array = b.get_meta("looks", [])
	var content: Dictionary = b.get_meta("content", {})
	if looks.size() < 3 or content.is_empty():
		return
	var i := 0
	match b.get_draw_mode():
		BaseButton.DRAW_HOVER:
			i = 1
		BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED:
			i = 2
	var look: Dictionary = looks[i]
	var rect: Rect2 = look["rect"]
	var image: NinePatchRect = content["image"]
	if image != null:
		var tex: Texture2D = content.get("item")
		var margins := Vector4.ZERO
		if tex == null:
			tex = look["fg"]
			if tex != null:
				margins = _middle_margins(String(look["fg_middle"]), tex)
		image.texture = tex
		image.patch_margin_left = int(margins.x)
		image.patch_margin_top = int(margins.y)
		image.patch_margin_right = int(margins.z)
		image.patch_margin_bottom = int(margins.w)
		image.position = rect.position
		image.size = rect.size
	var label: Label = content["label"]
	if label != null:
		label.size = rect.size
		# A Label cannot be shorter than a line of its text, and grows down
		# from where it is put; GUIButton centres its text on the button
		# whatever the button's size, so a button smaller than a line (the
		# quarter-slot "X" revert buttons of Mineclonia's player settings)
		# keeps its text centred on it rather than hanging below.
		label.position = rect.position + ((rect.size - label.size) / 2.0).floor()
		label.add_theme_color_override("font_color", look["colour"])

# StyleSpec::parseRect: one value insets every side, two inset the sides and
# the top and bottom, and four are the corners, the second pair counting from
# the far edges. Returned as [left, top, right, bottom] with upstream's signs.
static func _style_rect(value: String) -> Array:
	var v := value.strip_edges()
	if v == "":
		return [0, 0, 0, 0]
	var p := v.split(",")
	match p.size():
		1:
			var x := int(float(p[0]))
			return [x, x, -x, -x]
		2:
			var x := int(float(p[0]))
			var y := int(float(p[1]))
			return [x, y, -x, -y]
		4:
			return [int(float(p[0])), int(float(p[1])), int(float(p[2])), int(float(p[3]))]
	return [0, 0, 0, 0]

# StyleSpec::parseVector2f: "x,y", or one number for both.
static func _style_vec2(value: String) -> Vector2:
	var p := value.strip_edges().split(",")
	if p.size() == 1:
		return Vector2(float(p[0]), float(p[0]))
	if p.size() == 2:
		return Vector2(float(p[0]), float(p[1]))
	return Vector2.ZERO

# multiplyColorValue in guiButton.cpp: the colour channels scaled and clamped,
# alpha untouched.
static func _scale_rgb(c: Color, f: float) -> Color:
	return Color(minf(c.r * f, 1.0), minf(c.g * f, 1.0), minf(c.b * f, 1.0), c.a)

# Applies whatever style[] and style_type[] asked for to a built control. The
# element type comes from current_element, so this stays a single call at the
# end of each builder. Buttons have their own, _style_button.
func _apply_style(c: Control, ename: String) -> void:
	if style_by_name.is_empty() and style_by_type.is_empty():
		return
	var base := _style_for(ename, "default")
	if base.is_empty():
		return
	var base_font := _font_size()
	if _has_style(base, "font_size"):
		c.add_theme_font_size_override(
			"normal_font_size" if c is RichTextLabel else "font_size",
			_style_font_size(String(base["font_size"]), base_font))
	if _has_style(base, "font") and (c is LineEdit or c is TextEdit or c is ItemList or c is Tree):
		var f := _style_font(String(base["font"]))
		if f != null:
			c.add_theme_font_override("font", f)
	if _has_style(base, "textcolor"):
		var col := _ink(parse_color(String(base["textcolor"]), Color.WHITE))
		if c is LineEdit or c is TextEdit or c is Label:
			c.add_theme_color_override("font_color", col)
		elif c is CheckBox:
			for key in ["font_color", "font_hover_color", "font_pressed_color",
					"font_hover_pressed_color", "font_focus_color"]:
				c.add_theme_color_override(key, col)
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

# The pointer reached another slot with a button held down.
func _slot_dragged(loc: String, lname: String, index: int, button: int) -> void:
	slot_dragged.emit(loc, lname, index, button)

# Mouse released: completes a drag started on another slot. An empty listname
# means the pointer was not over a slot when the button came up.
func _slot_released(loc: String, lname: String, index: int, button: int) -> void:
	slot_released.emit(loc, lname, index, button)

func _slot_double_clicked(loc: String, lname: String, index: int) -> void:
	slot_double_clicked.emit(loc, lname, index)

# The slot under a point in viewport coordinates, or null. Godot hands motion
# and release events to whichever Control took the press, wherever the pointer
# has got to since, so a drag across slots has to ask where the pointer
# actually is; GUIFormSpecMenu does the same with getItemAtPos().
func slot_at(global_pos: Vector2) -> Control:
	for s in slots:
		if is_instance_valid(s) and s.is_visible_in_tree() \
				and s.get_global_rect().has_point(global_pos):
			return s
	return null

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


# The 3D preview behind a model[] element. The mesh arrives from the client
# already textured; this owns the SubViewport it is drawn in and the camera
# that orbits it. The camera maths is guiScene.cpp's: 30 degrees of vertical
# field of view, the distance that just fits the larger of the model's width
# and depth (pushed back by half of it so a turn cannot clip), the pitch held
# inside 60 degrees, and one degree of turn per pixel dragged.
class FormspecModel extends Control:
	const FOV_DEGREES := 30.0
	const PITCH_LIMIT := 60.0
	const SPIN_DEGREES_PER_SECOND := 30.0

	var viewport: SubViewport
	var camera: Camera3D
	var model: Node3D
	var max_width := 1.0 # the wider of the model's width and depth
	var height := 1.0
	var distance := 1.0
	var pitch := 0.0
	var yaw := 0.0
	var spinning := false
	var mouse_control := true
	var dragging := false

	func setup(node: Node3D, bounds: AABB, rotation_xy: Vector2, spin: bool,
			mouse: bool) -> void:
		model = node
		spinning = spin
		mouse_control = mouse
		mouse_filter = Control.MOUSE_FILTER_STOP if mouse else Control.MOUSE_FILTER_IGNORE
		clip_contents = true
		pitch = clampf(rotation_xy.x, -PITCH_LIMIT, PITCH_LIMIT)
		yaw = rotation_xy.y
		max_width = maxf(maxf(bounds.size.x, bounds.size.z), 0.001)
		height = maxf(bounds.size.y, 0.001)
		model.position = -bounds.get_center()
		viewport = SubViewport.new()
		# Its own world, or the SubViewport would draw the game world it is
		# sitting in front of, and its own transparency, so the form's
		# background stays visible around the model.
		viewport.own_world_3d = true
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		camera = Camera3D.new()
		camera.fov = FOV_DEGREES
		viewport.add_child(camera)
		viewport.add_child(model)
		var holder := SubViewportContainer.new()
		holder.stretch = true
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		holder.add_child(viewport)
		add_child(holder)
		resized.connect(_frame_model)
		set_process(spinning)

	func _ready() -> void:
		_frame_model()

	# calcOptimalDistance: fit whichever of the two axes the element's pixel
	# shape makes the tighter one.
	func _frame_model() -> void:
		if camera == null or size.x <= 0.0 or size.y <= 0.0:
			return
		var tan_v := tan(deg_to_rad(FOV_DEGREES) * 0.5)
		var tan_h := tan_v * (size.x / size.y)
		if size.x / max_width < size.y / height:
			distance = max_width / (2.0 * tan_h) + 0.5 * max_width
		else:
			distance = height / (2.0 * tan_v) + 0.5 * max_width
		camera.near = maxf(distance * 0.01, 0.01)
		camera.far = distance * 4.0 + max_width + height
		_place_camera()

	# The camera orbits the centred model. Upstream keeps its scene left
	# handed and starts the orbit half a turn round, which is why the yaw here
	# is negated in x and the model's own z is already mirrored.
	func _place_camera() -> void:
		if camera == null:
			return
		var p := deg_to_rad(pitch)
		var y := deg_to_rad(yaw)
		var eye := Vector3(-distance * cos(p) * sin(y), -distance * sin(p),
			distance * cos(p) * cos(y))
		camera.transform = Transform3D(Basis.looking_at(-eye, Vector3.UP), eye)

	func _process(delta: float) -> void:
		if not spinning:
			return
		yaw -= SPIN_DEGREES_PER_SECOND * delta
		_place_camera()

	func _gui_input(event: InputEvent) -> void:
		if not mouse_control:
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
			accept_event()
		elif event is InputEventMouseMotion and dragging:
			pitch = clampf(pitch - event.relative.y, -PITCH_LIMIT, PITCH_LIMIT)
			yaw += event.relative.x
			_place_camera()
			accept_event()


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
	# Dark glass only: the game framed this slot's list with slot art of its
	# own, or put a picture behind this slot that the form keeps
	# (formspec.gd, _replace_slot_frames).
	var framed := false
	var over_art := false

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

	# The form draws the item's tooltip itself (tooltip_at), from `item`.
	func refresh() -> void:
		item = form.item_source.get_list_item(location, listname, index) if form.item_source else {}
		icon = form.item_source.item_icon(item.get("icon_item", item.get("name", ""))) if (form.item_source and item.get("name", "") != "") else null
		queue_redraw()

	# GUIInventoryList::draw and drawItemStack: the slot colour, a border
	# only once listcolors[] has named one, a pixel outside the slot; the
	# item filling the slot; a tool's wear bar; the count in the corner.
	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if form.glass:
			GlassStyle.draw_slot(self, r, hovered, framed, over_art)
		else:
			draw_rect(r, colors["slot_bg_h"] if hovered else colors["slot_bg"])
			if colors.get("slot_border_on", false):
				draw_rect(Rect2(Vector2(-0.5, -0.5), size + Vector2(1, 1)), colors["slot_border"],
					false, 1.0)
		if icon:
			draw_texture_rect(icon, r, false)
		var wear: int = item.get("wear", 0)
		if wear > 0 and int(item.get("type", ITEM_TOOL)) == ITEM_TOOL:
			_draw_wear(wear / 65535.0)
		var count: int = item.get("count", 0)
		if count >= 2:
			var f := get_theme_default_font()
			var fs: int = form._font_size()
			var txt := str(count)
			var at := Vector2(size.x - f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x,
				size.y - f.get_descent(fs))
			draw_string(f, at + Vector2(1, 1), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Color(0, 0, 0, 127.0 / 255.0))
			draw_string(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)

	# ItemType::ITEM_TOOL: only tools draw a wear bar.
	const ITEM_TOOL := 3

	# A sixteenth of the slot high, a sixteenth in from the sides and bottom,
	# green through yellow to red as wear rises, black where it is used up.
	func _draw_wear(w: float) -> void:
		var h := size.y / 16.0
		var pad := size / 16.0
		var bar := Rect2(pad.x, size.y - pad.y - h, size.x - pad.x * 2.0, h)
		var mid := w * bar.position.x + (1.0 - w) * bar.end.x
		var level := mini(mini(floori(w * 600.0), 511) + 10, 511)
		var colour := Color8(level, 255, 0) if level <= 255 else Color8(255, 511 - level, 0)
		draw_rect(Rect2(bar.position, Vector2(mid - bar.position.x, h)), colour)
		draw_rect(Rect2(Vector2(mid, bar.position.y), Vector2(bar.end.x - mid, h)), Color.BLACK)

	# Which single button a motion event says is held. Left wins over right
	# and right over middle, the order GUIFormSpecMenu tests them in.
	static func held_button(mask: int) -> int:
		if mask & MOUSE_BUTTON_MASK_LEFT:
			return MOUSE_BUTTON_LEFT
		if mask & MOUSE_BUTTON_MASK_RIGHT:
			return MOUSE_BUTTON_RIGHT
		if mask & MOUSE_BUTTON_MASK_MIDDLE:
			return MOUSE_BUTTON_MIDDLE
		return 0

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton \
				and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if event.pressed:
				form.drag_over_slot = self
				form._slot_clicked(location, listname, index, event.button_index, event.shift_pressed)
				if event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
					# Godot flags the second press rather than sending an event
					# of its own; Irrlicht sends EMIE_LMOUSE_DOUBLE_CLICK after
					# the press, and GUIFormSpecMenu wants both in that order.
					form._slot_double_clicked(location, listname, index)
			else:
				# Godot delivers the release to whichever Control took the
				# press, so the slot the player let go over has to be looked
				# up by position rather than assumed to be this one.
				var over: Control = form.slot_at(event.global_position)
				form.drag_over_slot = null
				if over:
					form._slot_released(over.location, over.listname, over.index,
						event.button_index)
				else:
					form._slot_released("", "", -1, event.button_index)
			accept_event()
		elif event is InputEventMouseMotion:
			# Only the pressed slot sees motion while a button is down, so it
			# is the one that reports crossing into another slot. One report
			# per slot entered, which is what upstream's m_old_pointer test
			# amounts to.
			var button := held_button(event.button_mask)
			if button == 0:
				return
			var over: Control = form.slot_at(event.global_position)
			if over and over != form.drag_over_slot:
				form.drag_over_slot = over
				form._slot_dragged(over.location, over.listname, over.index, button)
