# SPDX-License-Identifier: LGPL-2.1-or-later
## Draws server formspecs saved as files through Goanna's formspec renderer
## in dark glass, at the window's size, and saves one PNG each. A scene, not
## a --script test, because it renders. FORMSPEC_DIR holds <name>.formspec
## files (DorfCraft's mods/kindred/settlement/overseer/tests/screens3_live
## writes its workshop ledger pages there); FORMSPEC_OUT receives
## <name>.png. Run through tools/goanna-headless fixture. The backdrop is a
## flat colour, not a game view.
extends Node
const Formspec := preload("res://ui/formspec.gd")
const GlassStyle := preload("res://ui/glass_style.gd")

func _ready() -> void:
	var dir := OS.get_environment("FORMSPEC_DIR")
	var out := OS.get_environment("FORMSPEC_OUT")
	if out.is_empty(): out = dir
	var layer := CanvasLayer.new()
	add_child(layer)
	var back := ColorRect.new()
	back.color = Color(0.36, 0.45, 0.52)
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(back)
	var names := []
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".formspec"): names.append(file)
	names.sort()
	var done := []
	for file: String in names:
		var spec := FileAccess.get_file_as_string(dir.path_join(file))
		var form := Formspec.new()
		form.style = GlassStyle.GLASS
		form.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layer.add_child(form)
		form.show_formspec(spec, "kindred:tomes_book", get_viewport().get_visible_rect().size, "")
		for i in 6: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var name: String = file.trim_suffix(".formspec")
		get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))
		done.append({"name": name, "skipped": form.skipped})
		layer.remove_child(form)
		form.queue_free()
	var f := FileAccess.open(out.path_join("formspec-shots.json"), FileAccess.WRITE)
	if f != null: f.store_string(JSON.stringify(done, "  "))
	get_tree().quit(0)
