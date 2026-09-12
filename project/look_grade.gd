# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends RefCounted

# The established twilight recipe owns -0.42..0.32 solar elevation.
# Noon gets less flat fill and mild contrast. Night has no correction LUT;
# its original black level and separation between light sources are retained.
static func weights(elevation: float, strength: float) -> Vector2:
	return Vector2(smoothstep(0.32, 0.75, elevation),
			smoothstep(-0.42, -0.72, elevation)) * clampf(strength, 0.0, 1.0)

static func curve(x: float, daylight: float) -> float:
	var daylight_shape := 0.18 * x * (1.0 - x) * (2.0 * x - 1.0)
	return x + daylight * daylight_shape

var _key := -1
var _texture: GradientTexture1D

func correction(daylight: float) -> Texture2D:
	# Rebuild only when the curve visibly changes, not for every sky update.
	var key := roundi(clampf(daylight, 0.0, 1.0) * 128.0)
	if key == 0:
		return null
	if key != _key:
		_key = key
		var offsets := PackedFloat32Array()
		var colors := PackedColorArray()
		for i in 65:
			var x := float(i) / 64.0
			var y := curve(x, float(key) / 128.0)
			offsets.append(x)
			colors.append(Color(y, y, y, 1.0))
		var gradient := Gradient.new()
		gradient.offsets = offsets
		gradient.colors = colors
		if _texture == null:
			_texture = GradientTexture1D.new()
			_texture.width = 1024
			_texture.use_hdr = true
		_texture.gradient = gradient
	return _texture
