# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The shader pack picker on Join a game and on Settings, Advanced graphics
## (ui/shader_pack_row.gd): it lists the packs in a scratch
## user://shaderpacks, writes the same saved setting from both, each shows
## what the other wrote, a join loads it, and the last join's line shows.
## Also that New world no longer carries a shader pack tab of its own.
## Headless, no server or GPU. It writes user://goanna.cfg and
## user://shaderpacks, so it refuses to run without a scratch XDG_DATA_HOME:
## XDG_DATA_HOME=$(mktemp -d) godot --headless --path project --script res://tests/menu_shader_pack.gd
extends SceneTree

const ShaderPacks := preload("res://game/shader_packs.gd")
const ShaderPackRow := preload("res://ui/shader_pack_row.gd")
const Narrator := preload("res://ui/narrator.gd")

var failures := 0
var checks := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if ok:
		print("  ok   ", what)
	else:
		failures += 1
		printerr("  FAIL ", what)

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func _make_packs() -> void:
	var dir := ProjectSettings.globalize_path(ShaderPacks.DIR)
	DirAccess.make_dir_recursive_absolute(dir.path_join("Alpha").path_join("shaders"))
	var z := ZIPPacker.new()
	z.open(dir.path_join("Beta.zip"))
	z.start_file("Beta/shaders/final.fsh")
	z.write_file("void main() {}".to_utf8_buffer())
	z.close_file()
	z.close()
	# Not a pack: no shaders/ inside.
	DirAccess.make_dir_recursive_absolute(dir.path_join("notes"))

func _items(picker: OptionButton) -> Array:
	var out: Array = []
	for i in picker.item_count:
		out.append(picker.get_item_text(i))
	return out

func _select(picker: OptionButton, text: String) -> bool:
	for i in picker.item_count:
		if picker.get_item_text(i) == text:
			picker.select(i)
			picker.item_selected.emit(i)
			return true
	return false

# The Settings row's picker: the OptionButton whose first item is None.
func _settings_picker(root: Node) -> OptionButton:
	for p in root.find_children("*", "OptionButton", true, false):
		if (p as OptionButton).item_count > 0 \
				and (p as OptionButton).get_item_text(0) == ShaderPackRow.NONE_LABEL:
			return p
	return null

func _status_text(picker: OptionButton) -> String:
	# build_join_picker: the picker's line, then the status label below it.
	var box := picker.get_parent().get_parent()
	for c in box.get_children():
		if c is Label and (c as Label).is_visible_in_tree():
			return (c as Label).text
	return ""

func _run() -> void:
	OS.set_environment("GOANNA_MENU", "1")
	OS.set_environment("GOANNA_NO_SHOWCASE", "1")
	OS.set_environment("GOANNA_SHADERPACK", "")
	_make_packs()
	var menu := preload("res://menu/menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame

	print("join a game")
	menu._join_folds["Materials and shaders"] = true
	menu._show_join()
	await process_frame
	var join: OptionButton = menu.join_shader_option
	check(join != null and join.is_visible_in_tree(), "Join a game has a Shaders picker, under Materials and shaders")
	check(_items(join) == [ShaderPackRow.NONE_LABEL, "Alpha", "Beta"],
			"it lists None and the two packs, not the folder without shaders/ (got %s)" % str(_items(join)))
	check(join.selected == 0, "nothing saved selects None")
	var labels: Array = []
	for l in menu.screen.find_children("*", "Label", true, false):
		labels.append((l as Label).text)
	check(labels.has("Materials") and labels.has("Shaders") and not labels.has("Graphics"),
			"the material row is labelled Materials, the new one Shaders")
	check(Narrator.describe(join).begins_with("Shaders, None"), "read aloud names the row: %s" % Narrator.describe(join))
	check(_select(join, "Beta"), "Beta can be chosen")
	check(ShaderPacks.chosen() == "Beta.zip", "choosing it saves the setting Settings uses (got %s)" % ShaderPacks.chosen())

	print("settings")
	menu._show_settings()
	await process_frame
	check(_settings_picker(menu.screen) == null, "the Settings front page has no shader pack picker")
	menu._show_settings_page("Advanced")
	await process_frame
	var settings_picker := _settings_picker(menu.screen)
	check(settings_picker != null, "Settings, Advanced graphics has the shader pack picker")
	if settings_picker != null:
		check(settings_picker.is_visible_in_tree(), "and it is in view")
		check(settings_picker.get_item_text(settings_picker.selected) == "Beta",
				"and shows what Join a game chose")
		check(_select(settings_picker, "Alpha"), "Alpha can be chosen in Settings")
	check(ShaderPacks.chosen() == "Alpha", "Settings writes the same setting")

	print("new world and the join")
	ShaderPacks.save_status("Alpha", "Not loaded: no programs (*.fsh) in Alpha")
	menu._show_join()
	await process_frame
	join = menu.join_shader_option
	check(join.get_item_text(join.selected) == "Alpha", "Join a game shows what Settings chose")
	check(_status_text(join) == "Last join: Not loaded: no programs (*.fsh) in Alpha",
			"and the last join's line for it, so a failed pack is visible (got %s)" % _status_text(join))
	menu._show_new_game()
	await process_frame
	if menu._screen_title == "New world":
		check(_settings_picker(menu.screen) == null,
				"New world has no shader pack picker: it is a setting, not a world option")
	else:
		print("  skip New world: no Luanti install with a game here")
	var j := ShaderPacks.prepare_join()
	check(str(j.get("path", "")) == ProjectSettings.globalize_path(ShaderPacks.DIR).path_join("Alpha"),
			"the join that follows loads the chosen pack (got %s)" % str(j))

	var status := Label.new()
	ShaderPackRow._compact_status(status)
	ShaderPackRow.show_status(status, "Alpha")
	check(status.max_lines_visible == 2 and status.tooltip_text == status.text,
			"last-load text stays compact while the tooltip retains the full status")
	status.free()

	menu.free()
	await process_frame
	print("menu shader pack: %d checks, %s" % [checks, "FAIL (%d)" % failures if failures else "PASS"])
	quit(1 if failures else 0)
