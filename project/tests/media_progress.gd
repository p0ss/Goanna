# SPDX-License-Identifier: LGPL-2.1-or-later
## Offline join label checks, run with Godot --headless --script.
extends SceneTree

const Progress := preload("res://game/media_progress.gd")

func _initialize() -> void:
	var cases := [
		[{"media_announced": 10, "media_cached": 3}, "Loading cached media", 0.3],
		[{"media_announced": 10, "media_received": 7, "media_cached": 5,
			"media_downloaded": 2, "media_cache_checked": true}, "Downloading media", 0.4],
		[{"media_announced": 10, "media_received": 10, "media_cached": 10,
			"media_cache_checked": true}, "Preparing world", 1.0],
		[{"media_announced": 10, "media_received": 10, "media_downloaded": 10,
			"media_cache_checked": true}, "Preparing world", 1.0],
		[{"media_cache_checked": true}, "Preparing world", 1.0],
	]
	for row in cases:
		var result := Progress.describe(row[0])
		if result.title != row[1] or not is_equal_approx(result.progress, row[2]):
			printerr("Media progress: FAIL: ", result)
			quit(1)
			return
	print("Media progress: PASS")
	quit()
