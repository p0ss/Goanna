# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The size of a menu or settings panel, and the layout of one settings row,
# shared by the main menu (menu.gd) and the in-game settings (ui/game_ui.gd).
#
# Both used to give their panels fixed minimum sizes: the menu's settings
# tabs were 560 by 360 inside a panel that grew with its content, so on a
# large screen most of a long page sat behind a small scroll window, and on
# a small one the panel ran off the bottom and Back could not be reached
# (reported 2026-10-01). Now a wide panel takes most of the window, up to a
# comfortable reading size, and its body scrolls inside it while the title
# and the buttons stay put.
extends RefCounted

const GlassStyle := preload("res://ui/glass_style.gd")
const MAX_WIDE := Vector2(980, 860)
const MAX_COMPACT_WIDTH := 520.0

# The space round the panel: a little on a small window, more on a large one.
static func outer_margin(window: Vector2) -> float:
	return clampf(minf(window.x, window.y) * 0.04, 12.0, 40.0)

# The panel's size in `window`. A wide panel fills the height it is given; a
# compact one (the main menu's list of buttons) is as tall as its content,
# so its height is 0 here.
static func size_for(window: Vector2, wide: bool) -> Vector2:
	var m := outer_margin(window)
	var avail := window - Vector2(m, m) * 2.0
	if wide:
		return Vector2(minf(avail.x, MAX_WIDE.x), minf(avail.y, MAX_WIDE.y))
	return Vector2(minf(avail.x, MAX_COMPACT_WIDTH), 0.0)

# A settings page: padding all round, more on the right so the scroll bar
# never sits on a control.
static func page_padding() -> MarginContainer:
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_right", 22)
	pad.add_theme_constant_override("margin_bottom", 16)
	return pad

# One settings row on `page`: the setting's name on the left of `head`, where
# a switch or a slider's value goes on the right, and anything wider (a
# slider, a picker, a path) below it in the returned row. Returns
# [row, head]. Rows after the first are separated by a faint rule.
static func row(page: VBoxContainer, title: String) -> Array:
	if page.get_child_count() > 0:
		var sep := HSeparator.new()
		sep.modulate = Color(1, 1, 1, 0.12)
		page.add_child(sep)
	var r := VBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(r)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	r.add_child(head)
	var name_label := Label.new()
	name_label.text = title
	name_label.add_theme_font_size_override("font_size", 17)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(name_label)
	return [r, head]

# The explanation under a row, dimmer and smaller than its name.
static func describe(r: VBoxContainer, text: String, alpha := 0.55) -> Label:
	var desc := Label.new()
	desc.text = text
	desc.add_theme_font_size_override("font_size", 13)
	GlassStyle.tint_text(desc, Color(1, 1, 1, alpha))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.add_child(desc)
	return desc
