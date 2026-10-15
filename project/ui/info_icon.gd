# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## A small (i) beside a setting, a picker or a screen's title, which shows
## the explanation that used to sit under it as a paragraph. Made by
## PanelFit.info (ui/panel_fit.gd) for the main menu (menu/menu.gd), the
## in-game panel (ui/game_ui.gd) and the shader pack row; read aloud by
## ui/narrator.gd through the META its owner carries.
#
# The text is a label placed where the paragraph was, hidden until asked
# for, rather than a floating bubble: it lays out like everything else at
# any interface scale, never covers the control it explains, and the
# narrator can find it. It shows:
#   - with the mouse, while the pointer is on the icon, and click pins it
#     open (the icon stays lit) until the next click;
#   - by touch, where there is no hover, a tap pins it and another unpins
#     it (touch arrives as emulated mouse events, so this is the same path,
#     with hover ignored after an unpinning tap until the pointer leaves);
#   - with the keyboard or a controller, while the focus is on the control
#     it explains (its owner, or anything inside it). The icon itself never
#     takes focus, so D-pad and Tab move from control to control as before
#     instead of stopping on an icon after each one.
extends Button

## Set on the owner, holding the text, for the narrator: when the focus is
## on the owner or inside it, the narrator reads the text after the control.
const META := "goanna_info"
const GlassStyle := preload("res://ui/glass_style.gd")
const SIZE := 24.0

## The explanation, hidden until asked for.
var label: Label
## The control the text explains. Its focus shows the text.
var owner_control: Control

var _hover := false
var _hover_off := false   # hover ignored until the pointer leaves
var _focused := false

func _init() -> void:
	text = "i"
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(SIZE, SIZE)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	mouse_default_cursor_shape = Control.CURSOR_HELP
	# What the narrator calls it when the pointer is on it; the text follows.
	set_meta("label", "More information")
	add_theme_font_size_override("font_size", 14)
	var ring := func(fill: Color, border: Color) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = fill
		sb.border_color = border
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(int(SIZE / 2.0))
		sb.set_content_margin_all(0)
		sb.anti_aliasing = true
		return sb
	add_theme_stylebox_override("normal", ring.call(Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.38)))
	add_theme_stylebox_override("hover", ring.call(Color(1, 1, 1, 0.14), GlassStyle.ACCENT))
	add_theme_stylebox_override("pressed", ring.call(Color(GlassStyle.ACCENT_FILL, 0.85), GlassStyle.ACCENT))
	add_theme_stylebox_override("hover_pressed", ring.call(Color(GlassStyle.ACCENT_FILL, 0.95), GlassStyle.ACCENT))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		add_theme_color_override(c, GlassStyle.TEXT)
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)
	toggled.connect(_on_toggled)

func _enter_tree() -> void:
	if not get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.connect(_on_focus_changed)
	_on_focus_changed(get_viewport().gui_get_focus_owner())

func _exit_tree() -> void:
	if get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.disconnect(_on_focus_changed)

## Replaces the explanation, for text that follows a selection (the graphics
## profile's blurb, the chosen terrain world's description).
func set_info(t: String) -> void:
	label.text = t
	if owner_control != null and is_instance_valid(owner_control):
		owner_control.set_meta(META, t)
	_update()

## Whether the text is showing now.
func revealed() -> bool:
	return label != null and label.visible

func _on_enter() -> void:
	_hover = true
	_update()

func _on_exit() -> void:
	_hover = false
	_hover_off = false
	_update()

func _on_toggled(on: bool) -> void:
	if not on:
		_hover_off = true
	_update()

## The control explained for a focus on `c`: the nearest of `c` and its
## ancestors with an explanation, or null. Nearest, so a pack option's own
## row inside the shader pack row is explained, not the shader pack row.
## The narrator asks the same.
static func explained(c: Node) -> Control:
	while c != null:
		if c is Control and c.has_meta(META):
			return c
		c = c.get_parent()
	return null

func _on_focus_changed(c: Control) -> void:
	var inside := c != null and owner_control != null and explained(c) == owner_control
	# A click focuses what it lands on as well; then the text follows the
	# pointer and the icon, not the focus, or every click on a slider would
	# open its paragraph. The controller's own cursor clicks the same way.
	_focused = inside and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	_update()

func _update() -> void:
	if label == null or not is_instance_valid(label):
		return
	label.visible = label.text != "" and (button_pressed or (_hover and not _hover_off) or _focused)
