# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Export the ordinary Godot mip chain on the CPU, without a game or GPU.
extends SceneTree


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var img := Image.load_from_file(args[0])
	if img == null or img.is_empty():
		quit(1)
		return
	img.convert(Image.FORMAT_RGBA8)
	if img.generate_mipmaps() != OK:
		quit(1)
		return
	var data := img.get_data()
	for level in range(mini(int(args[2]), img.get_mipmap_count()) + 1):
		var w := maxi(img.get_width() >> level, 1)
		var h := maxi(img.get_height() >> level, 1)
		var offset := img.get_mipmap_offset(level)
		var mip := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8,
				data.slice(offset, offset + w * h * 4))
		if mip.save_png(args[1].path_join("mip-%d.png" % level)) != OK:
			quit(1)
			return
	quit()
