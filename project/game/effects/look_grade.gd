# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The Appearance tab's colour grade: how much daytime contrast curve to apply
## for a sun elevation, and the 1D correction texture that carries it. One
## instance per game scene, made by game/main.gd, which feeds correction() to
## the Environment's adjustment_color_correction. Vividness, the player's
## vibrance, needs to see all three channels at once, so with it the curve
## goes into a 3D texture instead. Checked by tests/look_grade.gd.
extends RefCounted

# The established twilight recipe owns -0.42..0.32 solar elevation.
# Noon gets less flat fill and mild contrast. Night has no correction LUT;
# its original black level and separation between light sources are retained.
# Returns (daylight, deep night) weights, each 0 to 1 scaled by the player's
# strength: x drives the daytime curve, y lets main.gd hold back its night
# corrections.
static func weights(elevation: float, strength: float) -> Vector2:
	return Vector2(smoothstep(0.32, 0.75, elevation),
			smoothstep(-0.42, -0.72, elevation)) * clampf(strength, 0.0, 1.0)

# A gentle S curve about mid grey that leaves 0 and 1 where they are, so the
# grade adds contrast without clipping or lifting black.
static func curve(x: float, daylight: float) -> float:
	var daylight_shape := 0.18 * x * (1.0 - x) * (2.0 * x - 1.0)
	return x + daylight * daylight_shape

# Vibrance: lifts a colour's saturation by `amount` scaled by how muted it
# already is, so greys and soft colours gain most and a strong colour hardly
# moves, which is what keeps it from clipping where Saturation would. Grey
# itself has nothing to lift and stays grey.
static func vivid(c: Color, amount: float) -> Color:
	var high := maxf(c.r, maxf(c.g, c.b))
	var low := minf(c.r, minf(c.g, c.b))
	var luma := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	var k := 1.0 + amount * (1.0 - (high - low))
	return Color(clampf(luma + (c.r - luma) * k, 0.0, 1.0),
			clampf(luma + (c.g - luma) * k, 0.0, 1.0),
			clampf(luma + (c.b - luma) * k, 0.0, 1.0), 1.0)

# Texels per side of the 3D texture. Godot interpolates between them, and 33
# is the size colour grading tools export.
const LUT_SIZE := 33

var _key := -1
var _texture: GradientTexture1D
var _lut_key := Vector2i(-1, -1)
var _lut: ImageTexture3D

func correction(daylight: float, vividness := 0.0) -> Texture:
	# Rebuild only when the curve visibly changes, not for every sky update.
	var key := roundi(clampf(daylight, 0.0, 1.0) * 128.0)
	var vivid_key := roundi(clampf(vividness, 0.0, 1.0) * 100.0)
	if vivid_key > 0:
		return _vivid_lut(key, vivid_key)
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

# The same daylight curve per channel, then vibrance, as a 3D texture.
func _vivid_lut(key: int, vivid_key: int) -> ImageTexture3D:
	var wanted := Vector2i(key, vivid_key)
	if wanted == _lut_key:
		return _lut
	_lut_key = wanted
	var daylight := float(key) / 128.0
	var amount := float(vivid_key) / 100.0
	var shaped := PackedFloat32Array()
	for i in LUT_SIZE:
		shaped.append(curve(float(i) / float(LUT_SIZE - 1), daylight))
	var layers: Array[Image] = []
	for b in LUT_SIZE:
		var data := PackedByteArray()
		data.resize(LUT_SIZE * LUT_SIZE * 8)
		var at := 0
		for g in LUT_SIZE:
			for r in LUT_SIZE:
				var c := vivid(Color(shaped[r], shaped[g], shaped[b]), amount)
				data.encode_half(at, c.r)
				data.encode_half(at + 2, c.g)
				data.encode_half(at + 4, c.b)
				data.encode_half(at + 6, 1.0)
				at += 8
		layers.append(Image.create_from_data(LUT_SIZE, LUT_SIZE, false, Image.FORMAT_RGBAH, data))
	if _lut == null:
		_lut = ImageTexture3D.new()
		_lut.create(Image.FORMAT_RGBAH, LUT_SIZE, LUT_SIZE, LUT_SIZE, false, layers)
	else:
		_lut.update(layers)
	return _lut
