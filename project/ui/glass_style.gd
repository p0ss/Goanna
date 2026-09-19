# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The interface style: "glass", dark frosted glass over the world, which is
# the default, or "game", where server forms keep the game's own window art
# (formspec.gd's parity rendering) and Goanna's own screens keep the look they
# had before the glass existed. This file owns the choice, the palette, the
# Godot Theme every glass screen shares, and the contrast arithmetic that
# keeps text on glass legible. docs/interface-style.md explains the numbers
# and the rule for what in a form is chrome and what is content.
#
# The style is presentation only. Nothing here changes what a form sends,
# and nothing here shows a player anything the game did not.
extends RefCounted

const GlassSurface := preload("res://ui/glass_surface.gd")

const CFG_PATH := "user://goanna.cfg"
const KEY := "interface_style"
const GLASS := "glass"
const GAME := "game"
# The setting's choices as the settings screens list them, stored value first.
const CHOICES := [[GLASS, "Dark glass"], [GAME, "Game theme"]]
# Anything that wants to hear about a change joins this group and has
# interface_style_changed() called on it.
const GROUP := "goanna_interface_style"

static var _mode := ""
static var _theme: Theme
static var _form_theme: Theme

static func mode() -> String:
	if _mode == "":
		var cfg := ConfigFile.new()
		cfg.load(CFG_PATH)  # absent on a first run, which means the default
		var stored := str(cfg.get_value("settings", KEY, GLASS))
		_mode = GAME if stored == GAME else GLASS
	return _mode

static func is_glass() -> bool:
	return mode() == GLASS

# Saves the choice and tells every screen that asked to be told, so the change
# shows without a restart.
static func set_mode(value: String) -> void:
	value = GAME if value == GAME else GLASS
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)  # keep every other section and key
	cfg.set_value("settings", KEY, value)
	cfg.save(CFG_PATH)
	if value == _mode:
		return
	_mode = value
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.call_group(GROUP, "interface_style_changed")

# --- palette -----------------------------------------------------------------

# Text. TEXT_DIM is the quietest colour any text is drawn in on glass; both
# clear 4.5:1 against the brightest the glass can get (see below).
const TEXT := Color8(243, 245, 249)
const TEXT_DIM := Color8(200, 206, 216)
const TEXT_DISABLED := Color(0.953, 0.961, 0.976, 0.42)
# Focus rings, the selected tab, a checked box, a highlighted slot.
const ACCENT := Color8(142, 197, 255)
const ACCENT_FILL := Color8(58, 122, 206)
# Controls sit on the glass as a whisper of white; fields and lists as a
# sunken shade of black.
const CONTROL_FILL := Color(1, 1, 1, 0.075)
const CONTROL_HOVER := Color(1, 1, 1, 0.12)
const CONTROL_PRESSED := Color(0, 0, 0, 0.24)
const CONTROL_DISABLED := Color(1, 1, 1, 0.03)
const CONTROL_BORDER := Color(1, 1, 1, 0.14)
const CONTROL_BORDER_HOVER := Color(1, 1, 1, 0.24)
const FIELD_FILL := Color(0, 0, 0, 0.30)
const FIELD_BORDER := Color(1, 1, 1, 0.12)
const SELECTION := Color(ACCENT_FILL, 0.55)
# Inventory slots are mid grey tiles, nearly opaque, rather than a tint of
# the glass: on glass that follows a night sky down to black, a dark item
# (coal, obsidian, black wool) vanished into a dark slot. The tile sits
# between the darkest and lightest items (about 0.17 relative luminance,
# against Mineclonia's 0.34), so a black item and a white one both stand out
# from it over any world, and a slot's white count stays above 4.5:1. A slot
# the game framed with its own slot art is a little lighter than one it left
# plain, so a row the game set apart (Minetest Game's hotbar row) stays
# apart. The slot under the pointer turns blue and takes the accent ring,
# without getting lighter, so its count stays as legible.
const SLOT_FILL := Color(0.43, 0.44, 0.47, 0.90)
const SLOT_FILL_FRAMED := Color(0.47, 0.48, 0.51, 0.90)
const SLOT_HOVER := Color(0.38, 0.45, 0.56, 0.92)
const SLOT_BORDER := Color(1, 1, 1, 0.10)
const SLOT_BORDER_HOVER := Color(ACCENT, 0.9)
const SLOT_OVER_ART := Color(1, 1, 1, 0.04)
const SLOT_HOVER_OVER_ART := Color(1, 1, 1, 0.14)
# Menus that open over everything (a dropdown's list, a dialogue) are not
# glass: they are drawn nearly opaque, because Godot gives a popup no screen
# behind it to read.
const POPUP_FILL := Color8(20, 24, 31, 247)
const POPUP_BORDER := Color(1, 1, 1, 0.14)
# What the whole screen is dimmed by behind a form, in place of a game's own
# full screen colour: enough to set the form apart, little enough that the
# world still shows through the glass.
const BACKDROP := Color(0, 0, 0, 0.16)

const RADIUS := 14.0          # panels
const RADIUS_SMALL := 8.0     # tooltips, controls
const RADIUS_SLOT := 4

# --- contrast ------------------------------------------------------------------

# The shader's luminance ceiling and top sheen (ui_glass.gdshader, `ceiling`
# and `sheen`): the glass is never brighter than their sum, in relative
# luminance, whatever the world behind it is. Keep these in step with the
# shader's defaults.
const GLASS_CEILING := 0.05
const GLASS_SHEEN := 0.02
const PANEL_WORST := GLASS_CEILING + GLASS_SHEEN
# WCAG 2's figure for body text.
const MIN_CONTRAST := 4.5

static func srgb_to_linear(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

static func linear_to_srgb(v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	return v * 12.92 if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055

# Relative luminance, as WCAG defines it.
static func luminance(c: Color) -> float:
	return 0.2126 * srgb_to_linear(c.r) + 0.7152 * srgb_to_linear(c.g) \
		+ 0.0722 * srgb_to_linear(c.b)

static func contrast(a: float, b: float) -> float:
	return (maxf(a, b) + 0.05) / (minf(a, b) + 0.05)

# The worst (brightest) luminance of a fill drawn over the glass. Godot blends
# 2D in sRGB, so the fill is mixed there, over the glass at its brightest.
static func worst_under(fill: Color) -> float:
	var g := linear_to_srgb(PANEL_WORST)
	var bright := luminance(fill)  # the fill's own colour at full strength
	var fill_srgb := linear_to_srgb(bright)
	var mixed := g * (1.0 - fill.a) + fill_srgb * fill.a
	return srgb_to_linear(mixed)

# The surfaces text is drawn on, as their brightest possible luminance.
static func panel_worst() -> float:
	return PANEL_WORST

static func control_worst() -> float:
	return worst_under(CONTROL_HOVER)

# A text colour made legible on glass: returned unchanged when it already
# reaches MIN_CONTRAST against `surface` (a luminance), otherwise lifted
# towards white in linear light, just far enough. The hue survives, so red
# text is still red text, only lighter; alpha is kept.
static func ink(c: Color, surface := PANEL_WORST) -> Color:
	var need := MIN_CONTRAST * (surface + 0.05) - 0.05 + 0.002
	if luminance(c) >= need:
		return c
	var lin := Vector3(srgb_to_linear(c.r), srgb_to_linear(c.g), srgb_to_linear(c.b))
	var lo := 0.0
	var hi := 1.0
	for _i in 16:
		var t := (lo + hi) * 0.5
		var m := lin.lerp(Vector3.ONE, t)
		if 0.2126 * m.x + 0.7152 * m.y + 0.0722 * m.z >= need:
			hi = t
		else:
			lo = t
	var out := lin.lerp(Vector3.ONE, hi)
	return Color(linear_to_srgb(out.x), linear_to_srgb(out.y), linear_to_srgb(out.z), c.a)

# Colours a label, the way Goanna's screens used to with `modulate`: in the
# game theme it is exactly that. On glass a faded white becomes TEXT or
# TEXT_DIM and a coloured one is made legible with ink(), because text that
# is merely translucent loses contrast whenever the world behind is bright.
static func tint_text(c: Control, colour: Color) -> void:
	if not is_glass():
		c.modulate = colour
		return
	c.modulate = Color.WHITE
	var rgb := Color(colour.r, colour.g, colour.b)
	var out := ink(rgb)
	if rgb.is_equal_approx(Color.WHITE):
		out = TEXT if colour.a >= 0.8 else TEXT_DIM
	if c is RichTextLabel:
		c.add_theme_color_override("default_color", out)
	else:
		c.add_theme_color_override("font_color", out)

# --- surfaces ------------------------------------------------------------------

static func surface(radius := RADIUS, opaque := 0.0, shadow := 1.0) -> Control:
	var s := GlassSurface.new()
	s.radius = radius
	s.opaque = opaque
	s.shadow = shadow
	return s

# Puts a glass pane behind everything in `parent`, filling it.
static func back(parent: Control, radius := RADIUS, opaque := 0.0) -> Control:
	var s := surface(radius, opaque)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(s)
	parent.move_child(s, 0)
	if parent is Container:
		# A container fits its children inside its own margins; the pane is
		# put back over the whole of it each time the container has sorted.
		(parent as Container).sort_children.connect(func() -> void:
			s.position = Vector2.ZERO
			s.size = parent.size)
	return s

# One inventory slot on glass: the fill, and a rim that turns to the accent
# under the pointer. Drawn by formspec.gd's slots and the hotbar.
static var _slot_boxes: Array = []

# `over_art` is a slot drawn over a picture the form keeps: a see-through
# tile, so the picture shows through it as it does in the game's theme.
static func draw_slot(ci: CanvasItem, rect: Rect2, hovered: bool, framed: bool,
		over_art := false) -> void:
	if _slot_boxes.is_empty():
		for look in [[SLOT_FILL, SLOT_BORDER, 1], [SLOT_FILL_FRAMED, SLOT_BORDER, 1],
				[SLOT_HOVER, SLOT_BORDER_HOVER, 2], [SLOT_OVER_ART, SLOT_BORDER, 1],
				[SLOT_HOVER_OVER_ART, SLOT_BORDER_HOVER, 2]]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = look[0]
			sb.border_color = look[1]
			sb.set_border_width_all(look[2])
			sb.set_corner_radius_all(RADIUS_SLOT)
			sb.anti_aliasing = true
			_slot_boxes.append(sb)
	var look := 0
	if over_art:
		look = 4 if hovered else 3
	elif hovered:
		look = 2
	elif framed:
		look = 1
	(_slot_boxes[look] as StyleBoxFlat).draw(ci.get_canvas_item(), rect)

# --- the Theme -----------------------------------------------------------------

static func _box(fill: Color, radius: float, border := Color.TRANSPARENT, width := 0,
		margins := Vector4(10, 6, 10, 6)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(int(radius))
	if width > 0:
		sb.set_border_width_all(width)
		sb.border_color = border
	sb.content_margin_left = margins.x
	sb.content_margin_top = margins.y
	sb.content_margin_right = margins.z
	sb.content_margin_bottom = margins.w
	sb.anti_aliasing = true
	return sb

# A focus ring drawn over a control, as Godot draws focus.
static func _ring(radius: float) -> StyleBoxFlat:
	var sb := _box(Color.TRANSPARENT, radius, Color(ACCENT, 0.95), 2)
	sb.draw_center = false
	sb.expand_margin_left = 1
	sb.expand_margin_right = 1
	sb.expand_margin_top = 1
	sb.expand_margin_bottom = 1
	return sb

static func _svg(src: String, scale := 1.0) -> Texture2D:
	var img := Image.new()
	if img.load_svg_from_string(src, scale) != OK:
		return null
	return ImageTexture.create_from_image(img)

static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)

static func _check_icon(checked: bool, disabled: bool, round: bool) -> Texture2D:
	var alpha := 0.45 if disabled else 1.0
	var shape := "<circle cx='9' cy='9' r='7.25'" if round \
		else "<rect x='1.75' y='1.75' width='14.5' height='14.5' rx='4.5'"
	var body := ""
	if checked:
		body = shape + " fill='%s' fill-opacity='%.2f' stroke='%s' stroke-opacity='%.2f' stroke-width='1.5'/>" \
			% [_hex(ACCENT_FILL), alpha, _hex(ACCENT), alpha]
		if round:
			body += "<circle cx='9' cy='9' r='3.2' fill='#ffffff' fill-opacity='%.2f'/>" % alpha
		else:
			body += "<path d='M5 9.4 L7.8 12 L13 6.2' fill='none' stroke='#ffffff' stroke-opacity='%.2f' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/>" % alpha
	else:
		body = shape + " fill='#000000' fill-opacity='%.2f' stroke='#ffffff' stroke-opacity='%.2f' stroke-width='1.5'/>" \
			% [0.25 * alpha, 0.6 * alpha]
	return _svg("<svg xmlns='http://www.w3.org/2000/svg' width='18' height='18'>" + body + "</svg>")

static func _switch_icon(on: bool, disabled: bool) -> Texture2D:
	var alpha := 0.45 if disabled else 1.0
	var track := "<rect x='1' y='2' width='36' height='20' rx='10' fill='%s' fill-opacity='%.2f' stroke='#ffffff' stroke-opacity='%.2f' stroke-width='1'/>" \
		% [_hex(ACCENT_FILL) if on else "#000000", (0.95 if on else 0.3) * alpha, (0.35 if on else 0.3) * alpha]
	var knob := "<circle cx='%d' cy='12' r='7.5' fill='#ffffff' fill-opacity='%.2f'/>" \
		% [27 if on else 11, (0.98 if on else 0.8) * alpha]
	return _svg("<svg xmlns='http://www.w3.org/2000/svg' width='38' height='24'>" + track + knob + "</svg>")

static func _chevron(down: bool) -> Texture2D:
	var d := "M3 5 L8 10 L13 5" if down else "M5 3 L10 8 L5 13"
	return _svg("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><path d='%s' fill='none' stroke='%s' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/></svg>"
		% [d, _hex(TEXT_DIM)])

static func _knob(highlight: bool) -> Texture2D:
	return _svg("<svg xmlns='http://www.w3.org/2000/svg' width='18' height='18'><circle cx='9' cy='9' r='7' fill='#ffffff' stroke='%s' stroke-width='%s'/></svg>"
		% [_hex(ACCENT) if highlight else "#000000", "2" if highlight else "0.6"])

# The Theme for Goanna's own screens and for the controls of a glass form.
# Built once. It sets no font, so text measures exactly as it does in the
# game theme and nothing moves when the style changes.
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	var empty := StyleBoxEmpty.new()

	for type in ["Label"]:
		t.set_color("font_color", type, TEXT)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_stylebox("normal", "RichTextLabel", empty)
	t.set_stylebox("focus", "RichTextLabel", empty)
	for type in ["Panel", "PanelContainer"]:
		t.set_stylebox("panel", type, empty)

	# Buttons, and everything built on BaseButton's looks.
	var normal := _box(CONTROL_FILL, RADIUS_SMALL, CONTROL_BORDER, 1)
	var hover := _box(CONTROL_HOVER, RADIUS_SMALL, CONTROL_BORDER_HOVER, 1)
	var pressed := _box(CONTROL_PRESSED, RADIUS_SMALL, CONTROL_BORDER, 1)
	var disabled := _box(CONTROL_DISABLED, RADIUS_SMALL, Color(1, 1, 1, 0.06), 1)
	for type in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", type, normal)
		t.set_stylebox("hover", type, hover)
		t.set_stylebox("pressed", type, pressed)
		t.set_stylebox("hover_pressed", type, pressed)
		t.set_stylebox("disabled", type, disabled)
		t.set_stylebox("focus", type, _ring(RADIUS_SMALL))
	for type in ["Button", "OptionButton", "MenuButton", "CheckBox", "CheckButton"]:
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, Color.WHITE)
		t.set_color("font_pressed_color", type, Color.WHITE)
		t.set_color("font_hover_pressed_color", type, Color.WHITE)
		t.set_color("font_focus_color", type, Color.WHITE)
		t.set_color("font_disabled_color", type, TEXT_DISABLED)
	t.set_icon("arrow", "OptionButton", _chevron(true))
	t.set_constant("arrow_margin", "OptionButton", 8)

	# Check boxes and switches keep a plain background and carry their state
	# in the icon, which is drawn large enough to read at a glance.
	var check_hover := _box(Color(1, 1, 1, 0.06), RADIUS_SMALL, Color.TRANSPARENT, 0, Vector4(4, 3, 4, 3))
	var check_plain := _box(Color.TRANSPARENT, RADIUS_SMALL, Color.TRANSPARENT, 0, Vector4(4, 3, 4, 3))
	for type in ["CheckBox", "CheckButton"]:
		for key in ["normal", "pressed", "disabled"]:
			t.set_stylebox(key, type, check_plain)
		t.set_stylebox("hover", type, check_hover)
		t.set_stylebox("hover_pressed", type, check_hover)
		t.set_stylebox("focus", type, _ring(RADIUS_SMALL))
		t.set_constant("h_separation", type, 8)
	t.set_icon("checked", "CheckBox", _check_icon(true, false, false))
	t.set_icon("unchecked", "CheckBox", _check_icon(false, false, false))
	t.set_icon("checked_disabled", "CheckBox", _check_icon(true, true, false))
	t.set_icon("unchecked_disabled", "CheckBox", _check_icon(false, true, false))
	t.set_icon("radio_checked", "CheckBox", _check_icon(true, false, true))
	t.set_icon("radio_unchecked", "CheckBox", _check_icon(false, false, true))
	t.set_icon("radio_checked_disabled", "CheckBox", _check_icon(true, true, true))
	t.set_icon("radio_unchecked_disabled", "CheckBox", _check_icon(false, true, true))
	for key in ["checked", "checked_mirrored"]:
		t.set_icon(key, "CheckButton", _switch_icon(true, false))
	for key in ["unchecked", "unchecked_mirrored"]:
		t.set_icon(key, "CheckButton", _switch_icon(false, false))
	for key in ["checked_disabled", "checked_disabled_mirrored"]:
		t.set_icon(key, "CheckButton", _switch_icon(true, true))
	for key in ["unchecked_disabled", "unchecked_disabled_mirrored"]:
		t.set_icon(key, "CheckButton", _switch_icon(false, true))

	# Text entry: a sunken shade with a ring when focused.
	var field := _box(FIELD_FILL, RADIUS_SMALL, FIELD_BORDER, 1, Vector4(8, 4, 8, 4))
	var field_ro := _box(Color(0, 0, 0, 0.18), RADIUS_SMALL, Color(1, 1, 1, 0.06), 1, Vector4(8, 4, 8, 4))
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, field)
		t.set_stylebox("focus", type, _ring(RADIUS_SMALL))
		t.set_stylebox("read_only", type, field_ro)
		t.set_color("font_color", type, TEXT)
		t.set_color("font_selected_color", type, Color.WHITE)
		t.set_color("selection_color", type, SELECTION)
		t.set_color("caret_color", type, ACCENT)
		t.set_color("font_placeholder_color", type, Color(TEXT_DIM, 0.7))
		t.set_color("font_uneditable_color", type, TEXT_DIM)
		t.set_color("font_readonly_color", type, TEXT_DIM)
	t.set_color("background_color", "TextEdit", Color.TRANSPARENT)
	t.set_color("current_line_color", "TextEdit", Color(1, 1, 1, 0.04))

	# Tabs: the selected one lit and underlined in the accent.
	var tab_sel := _box(Color(1, 1, 1, 0.13), RADIUS_SMALL, Color.TRANSPARENT, 0, Vector4(14, 7, 14, 7))
	tab_sel.border_width_bottom = 2
	tab_sel.border_color = ACCENT
	tab_sel.corner_radius_bottom_left = 0
	tab_sel.corner_radius_bottom_right = 0
	var tab_off := _box(Color.TRANSPARENT, RADIUS_SMALL, Color.TRANSPARENT, 0, Vector4(14, 7, 14, 7))
	var tab_hover := _box(Color(1, 1, 1, 0.07), RADIUS_SMALL, Color.TRANSPARENT, 0, Vector4(14, 7, 14, 7))
	tab_hover.corner_radius_bottom_left = 0
	tab_hover.corner_radius_bottom_right = 0
	for type in ["TabContainer", "TabBar"]:
		t.set_stylebox("tab_selected", type, tab_sel)
		t.set_stylebox("tab_unselected", type, tab_off)
		t.set_stylebox("tab_hovered", type, tab_hover)
		t.set_stylebox("tab_disabled", type, tab_off)
		t.set_stylebox("tab_focus", type, _ring(RADIUS_SMALL))
		t.set_color("font_selected_color", type, Color.WHITE)
		t.set_color("font_unselected_color", type, TEXT_DIM)
		t.set_color("font_hovered_color", type, TEXT)
		t.set_color("font_disabled_color", type, TEXT_DISABLED)
	var tab_panel := _box(Color(0, 0, 0, 0.16), RADIUS_SMALL, Color(1, 1, 1, 0.08), 1, Vector4(0, 0, 0, 0))
	tab_panel.corner_radius_top_left = 0
	t.set_stylebox("panel", "TabContainer", tab_panel)
	var tab_line := StyleBoxFlat.new()
	tab_line.bg_color = Color.TRANSPARENT
	tab_line.border_width_bottom = 1
	tab_line.border_color = Color(1, 1, 1, 0.08)
	t.set_stylebox("tabbar_background", "TabContainer", tab_line)

	# Sliders.
	var track := _box(Color(0, 0, 0, 0.38), 3, Color(1, 1, 1, 0.10), 1, Vector4(0, 3, 0, 3))
	var track_fill := _box(Color(ACCENT_FILL, 0.95), 3, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3))
	var track_fill_hi := _box(ACCENT_FILL.lightened(0.15), 3, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3))
	for type in ["HSlider", "VSlider"]:
		t.set_stylebox("slider", type, track)
		t.set_stylebox("grabber_area", type, track_fill)
		t.set_stylebox("grabber_area_highlight", type, track_fill_hi)
		t.set_icon("grabber", type, _knob(false))
		t.set_icon("grabber_highlight", type, _knob(true))
		t.set_icon("grabber_disabled", type, _knob(false))

	# Scroll bars: a slim rounded thumb on a faint track.
	var bar := _box(Color(0, 0, 0, 0.18), 5, Color.TRANSPARENT, 0, Vector4(5, 5, 5, 5))
	var thumb := _box(Color(1, 1, 1, 0.30), 5, Color.TRANSPARENT, 0, Vector4(5, 5, 5, 5))
	var thumb_hi := _box(Color(1, 1, 1, 0.45), 5, Color.TRANSPARENT, 0, Vector4(5, 5, 5, 5))
	var thumb_down := _box(Color(ACCENT, 0.75), 5, Color.TRANSPARENT, 0, Vector4(5, 5, 5, 5))
	for type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", type, bar)
		t.set_stylebox("scroll_focus", type, bar)
		t.set_stylebox("grabber", type, thumb)
		t.set_stylebox("grabber_highlight", type, thumb_hi)
		t.set_stylebox("grabber_pressed", type, thumb_down)

	# Lists and tables: a sunken pane, a lit row under the pointer and an
	# accent row for the selection.
	var list_panel := _box(Color(0, 0, 0, 0.26), RADIUS_SMALL, Color(1, 1, 1, 0.08), 1, Vector4(4, 4, 4, 4))
	var row_sel := _box(SELECTION, 4, Color(ACCENT, 0.7), 1, Vector4(4, 2, 4, 2))
	var row_hover := _box(Color(1, 1, 1, 0.07), 4, Color.TRANSPARENT, 0, Vector4(4, 2, 4, 2))
	for type in ["ItemList", "Tree"]:
		t.set_stylebox("panel", type, list_panel)
		t.set_stylebox("focus", type, empty)
		for key in ["selected", "selected_focus", "hovered_selected", "hovered_selected_focus"]:
			t.set_stylebox(key, type, row_sel)
		t.set_stylebox("hovered", type, row_hover)
		t.set_stylebox("cursor", type, empty)
		t.set_stylebox("cursor_unfocused", type, empty)
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hovered_color", type, Color.WHITE)
		t.set_color("font_selected_color", type, Color.WHITE)
		t.set_color("font_hovered_selected_color", type, Color.WHITE)
		t.set_color("guide_color", type, Color.TRANSPARENT)
	t.set_icon("arrow", "Tree", _chevron(true))
	t.set_icon("arrow_collapsed", "Tree", _chevron(false))
	t.set_color("relationship_line_color", "Tree", Color(1, 1, 1, 0.12))

	# Popups, dialogs and Godot's own tooltips have no screen to read, so
	# they are nearly opaque rather than frosted.
	var popup := _box(POPUP_FILL, RADIUS_SMALL, POPUP_BORDER, 1, Vector4(6, 6, 6, 6))
	popup.shadow_color = Color(0, 0, 0, 0.35)
	popup.shadow_size = 10
	popup.shadow_offset = Vector2(0, 4)
	t.set_stylebox("panel", "PopupMenu", popup)
	t.set_stylebox("hover", "PopupMenu", _box(Color(1, 1, 1, 0.10), 5, Color.TRANSPARENT, 0))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_color("font_disabled_color", "PopupMenu", TEXT_DISABLED)
	t.set_icon("radio_checked", "PopupMenu", _check_icon(true, false, true))
	t.set_icon("radio_unchecked", "PopupMenu", _check_icon(false, false, true))
	t.set_icon("checked", "PopupMenu", _check_icon(true, false, false))
	t.set_icon("unchecked", "PopupMenu", _check_icon(false, false, false))
	t.set_stylebox("panel", "TooltipPanel", popup)
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_stylebox("panel", "AcceptDialog", _box(POPUP_FILL, 0, Color.TRANSPARENT, 0, Vector4(12, 12, 12, 12)))

	var line := StyleBoxLine.new()
	line.color = Color(1, 1, 1, 0.10)
	line.thickness = 1
	t.set_stylebox("separator", "HSeparator", line)
	t.set_stylebox("background", "ProgressBar", _box(Color(0, 0, 0, 0.3), 4, Color(1, 1, 1, 0.08), 1))
	t.set_stylebox("fill", "ProgressBar", _box(ACCENT_FILL, 4, Color.TRANSPARENT, 0))
	_theme = t
	return t

# The Theme a glass form is built with: the shared one, with the one pixel
# half alpha text shadow Luanti draws under all form text, and the monospace
# face hypertext and the font style property ask for.
static func form_theme(mono: Font) -> Theme:
	if _form_theme != null:
		return _form_theme
	var t := theme().duplicate() as Theme
	for type in ["Label", "RichTextLabel"]:
		t.set_color("font_shadow_color", type, Color(0, 0, 0, 127.0 / 255.0))
		t.set_constant("shadow_offset_x", type, 1)
		t.set_constant("shadow_offset_y", type, 1)
	t.set_font("mono_font", "RichTextLabel", mono)
	_form_theme = t
	return t
