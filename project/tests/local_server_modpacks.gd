# SPDX-License-Identifier: LGPL-2.1-or-later
# Modpack choices must expand into Luanti leaf mod names.
extends SceneTree
const Server = preload("res://local_server.gd")
var failures = 0
func check(ok, label):
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func put(path, text):
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string(text)
func _initialize():
	var base = "user://modpack-activation-test"
	put(base+"/mods/pack/modpack.conf", "name = collection\n")
	put(base+"/mods/pack/first/mod.conf", "name = labour_test\n")
	put(base+"/mods/pack/nest/modpack.txt", "")
	put(base+"/mods/pack/nest/second/mod.conf", "name = calendar_test\n")
	put(base+"/mods/renamed/mod.conf", "name = actual_name\n")
	var world = base+"/worlds/check"
	DirAccess.make_dir_recursive_absolute(world)
	var server = Server.new()
	check(server._write_world_options(world, {"gameid":"mineclonia","mods":["pack", "renamed"],"pbr_materials":false}) == "", "writes selected modpack")
	var saved = FileAccess.get_file_as_string(world+"/world.mt")
	check(saved.contains("load_mod_labour_test = true") and saved.contains("load_mod_calendar_test = true"), "nested leaf mods enabled")
	check(not saved.contains("load_mod_pack =") and saved.contains("load_mod_actual_name = true"), "writes declared mod names")
	var options = Server.world_options(base,"check")
	check(options.mods.has("pack") and options.mods.has("renamed"), "menu restores selected packs and renamed mods")
	server._write_world_options(world, {"gameid":"mineclonia","mods":[],"pbr_materials":false})
	saved=FileAccess.get_file_as_string(world+"/world.mt")
	check(not saved.contains("load_mod_labour_test") and not saved.contains("load_mod_calendar_test"),"deselecting pack removes its leaf settings")
	print("Modpack activation: ", failures, " failures")
	quit(1 if failures else 0)
