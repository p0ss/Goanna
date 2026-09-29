# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared world-space bounds for sky clouds and nearby participating media.
extends RefCounted


# Each entry is (base, depth, coverage, optical density multiplier).
# No camera height: flying can pass through and above every layer. The
# regional ground reference is held while terrain queries have no answer.
static func build(height: float, thickness: float, coverage: float,
		storm: float, ground: float, style: int, count: int = 3) -> PackedVector4Array:
	var cover := clampf(coverage, 0.0, 0.95)
	var wet := smoothstep(0.35, 0.8, maxf(storm, cover))
	var depth := maxf(thickness * 3.0, 170.0) if style == 2 \
			else maxf(thickness * 2.0, 96.0)
	# The upper block cells are wider. Retain their rounded proportions;
	# thinning them like the volume turns the squares into flat roof tiles.
	var middle_depth := depth * (0.8 if style == 2 else 1.5)
	var high_depth := depth * (0.55 if style == 2 else 1.7)
	var middle := maxf(height + depth * 1.75 + middle_depth * 0.75 + 180.0,
			ground + 480.0)
	var high := maxf(middle + middle_depth * 1.75 + high_depth * 0.75 + 280.0,
			ground + 1100.0)
	var layers := PackedVector4Array([
		Vector4(height, depth, cover, 1.0),
		Vector4(middle, middle_depth, cover * lerpf(0.60, 1.0, wet), 0.75),
		Vector4(high, high_depth, cover * lerpf(0.85, 0.65, wet), 0.40),
	])
	# Reduced budgets prioritise clouds above the regional terrain. Keep the
	# original slots and seeds, so switching counts does not move any deck.
	count = clampi(count, 1, 3)
	var first := 0
	while first < 2 and layers[first].x + layers[first].y < ground:
		first += 1
	first = mini(first, 3 - count)
	for i in layers.size():
		if i < first or i >= first + count:
			layers[i].z = 0.0
	return layers


# Keep upper banks broad enough to read from the ground. Scale by the fixed
# layer slot, never the eye position or the number of enabled layers.
static func horizontal_scale(layer: int) -> float:
	return float((layer + 1) * (layer + 1))
