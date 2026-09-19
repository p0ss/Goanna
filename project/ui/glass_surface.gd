# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# One pane of dark glass: the backing of a form, a menu, a tooltip, the chat
# history or the hotbar in the dark glass interface style. It draws nothing
# but its own rectangle, grown by the shader's margin for the drop shadow,
# through one of two materials every pane shares: frosted, which blurs the
# screen behind it (ui_glass.gdshader), or clear, which does not read the
# screen and costs nothing more than drawing it (ui_glass_clear.gdshader).
# The pane's own settings travel in the vertex colour, which is why there is
# no material per pane. It takes no input, so whatever sits on it is what the
# pointer reaches.
extends Control

const FROST_SHADER := preload("res://ui/ui_glass.gdshader")
const CLEAR_SHADER := preload("res://ui/ui_glass_clear.gdshader")
# Must match the shaders' `margin` uniform, which the materials leave at its
# default.
const MARGIN := 24.0

static var _frost_material: ShaderMaterial
static var _clear_material: ShaderMaterial

# Corner radius in pixels, up to 64.
var radius := 14.0:
	set(v):
		radius = v
		queue_redraw()
# How opaque the tint is: 0 for an ordinary pane, towards 1 for a pane that
# must stay dark whatever is behind it, such as a tooltip over a form.
var opaque := 0.0:
	set(v):
		opaque = v
		queue_redraw()
# Strength of the drop shadow, 0 for none.
var shadow := 1.0:
	set(v):
		shadow = v
		queue_redraw()
# Whether the pane blurs what is behind it. Only surfaces that are up while
# a window is open should: the screen copy the blur needs is the style's
# whole cost.
var frost := true:
	set(v):
		frost = v
		material = shared_material(v)

static func shared_material(frosted := true) -> ShaderMaterial:
	if frosted:
		if _frost_material == null:
			_frost_material = ShaderMaterial.new()
			_frost_material.shader = FROST_SHADER
		return _frost_material
	if _clear_material == null:
		_clear_material = ShaderMaterial.new()
		_clear_material.shader = CLEAR_SHADER
	return _clear_material

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	material = shared_material(true)
	set_meta("glass_surface", true)

func _draw() -> void:
	var colour := Color(clampf(radius / 64.0, 0.0, 1.0), clampf(opaque, 0.0, 1.0),
		clampf(shadow, 0.0, 1.0), 1.0)
	draw_rect(Rect2(-MARGIN, -MARGIN, size.x + MARGIN * 2.0, size.y + MARGIN * 2.0), colour)
