# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends SceneTree

const Grade := preload("res://look_grade.gd")

func _initialize() -> void:
	# Every established twilight hue must bypass the new correction, including
	# sunset behind terrain: weights use astronomical elevation, not the ridge.
	for i in 741:
		var elevation := -0.42 + float(i) * 0.001
		assert(Grade.weights(elevation, 1.0).length() < 0.000001)
	for elevation in [-1.0, -0.6, 0.0, 0.5, 1.0]:
		assert(Grade.weights(elevation, 0.0) == Vector2.ZERO)
	# No correction at night, even with Natural look at full strength.
	var grade := Grade.new()
	for i in 1421:
		var elevation := -1.0 + float(i) * 0.001
		if elevation <= 0.32:
			assert(grade.correction(Grade.weights(elevation, 1.0).x) == null)
	# The daylight curve preserves black and white without gradient reversals.
	for strength in [0.0, 0.3, 0.7, 1.0]:
		assert(is_zero_approx(Grade.curve(0, strength)))
		assert(is_equal_approx(Grade.curve(1, strength), 1.0))
		var previous := 0.0
		for i in 1025:
			var x := float(i) / 1024.0
			var value := Grade.curve(x, strength)
			assert(value >= previous and value <= 1.0)
			if strength == 0.0:
				assert(is_equal_approx(value, x))
			previous = value
	var texture := grade.correction(0.7)
	assert(texture != null and texture.width == 1024)
	assert(grade.correction(0.7) == texture)
	assert(grade.correction(0) == null)
	assert(grade.correction(0.7) == texture)
	print("look grade: night/twilight bypass, black/white endpoints, monotonicity and cache passed")
	quit()
