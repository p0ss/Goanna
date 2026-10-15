# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The (i) info icon (ui/info_icon.gd, made by PanelFit.info and describe):
## the text is hidden until the pointer is on the icon, a click or tap pins
## it and the next unpins it, keyboard or controller focus on what it
## explains shows it, the icon never takes focus, and read aloud speaks the
## text when the focus comes to the row. Then that the menu's screens and
## the in-game settings panel use it rather than paragraphs, keeping state
## and warnings in view. Headless, no server or GPU. It writes
## user://goanna.cfg, so it refuses to run without a scratch XDG_DATA_HOME:
## XDG_DATA_HOME=$(mktemp -d) godot --headless --path project --script res://tests/info_icon.gd
extends SceneTree

const PanelFit := preload("res://ui/panel_fit.gd")
const InfoIcon := preload("res://ui/info_icon.gd")
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

class FakeVoice extends RefCounted:
	var said: Array = []
	func available() -> bool: return true
	func speaking() -> bool: return false
	func speak(text: String, interrupt: bool) -> void:
		said.append({"text": text, "interrupt": interrupt})
	func stop() -> void: pass

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func _icons(node: Node) -> Array:
	var out: Array = []
	for c in node.find_children("*", "Button", true, false):
		if c.get_script() == InfoIcon:
			out.append(c)
	return out

func _visible_texts(node: Node) -> Array:
	var out: Array = []
	for l in node.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree():
			out.append((l as Label).text)
	return out

func _run() -> void:
	await _unit()
	await _menu()
	await _in_game()
	print("info icon: %d checks, %s" % [checks, "FAIL (%d)" % failures if failures else "PASS"])
	quit(1 if failures else 0)

func _unit() -> void:
	print("the icon")
	var page := VBoxContainer.new()
	page.size = Vector2(800, 600)
	root.add_child(page)
	var shell: Array = PanelFit.row(page, "Field of view")
	var row: VBoxContainer = shell[0]
	var head: HBoxContainer = shell[1]
	var toggle := CheckButton.new()
	head.add_child(toggle)
	var icon: Button = PanelFit.describe(row, "The camera's field of view, in degrees.")
	var other := Button.new()
	other.text = "Elsewhere"
	page.add_child(other)
	await process_frame
	check(icon.get_script() == InfoIcon, "describe() makes an (i) for a settings row")
	check(icon.get_parent() == head and icon.get_index() == 1, "beside the setting's name")
	check(icon.focus_mode == Control.FOCUS_NONE, "which never takes focus, so the D-pad does not stop on it")
	check(not icon.revealed(), "the text starts hidden")
	check(not _visible_texts(page).has("The camera's field of view, in degrees."), "and is not on screen")
	icon.mouse_entered.emit()
	check(icon.revealed(), "pointer on the icon shows it")
	icon.mouse_exited.emit()
	check(not icon.revealed(), "pointer off hides it")
	icon.mouse_entered.emit()
	icon.button_pressed = true
	icon.mouse_exited.emit()
	check(icon.revealed(), "a click or tap pins it, so it stays when the pointer leaves")
	icon.mouse_entered.emit()
	icon.button_pressed = false
	check(not icon.revealed(), "the next click or tap unpins it, though the (emulated) pointer is still there")
	icon.mouse_exited.emit()
	toggle.grab_focus()
	await process_frame
	check(icon.revealed(), "keyboard or controller focus on the row's switch shows it")
	other.grab_focus()
	await process_frame
	check(not icon.revealed(), "and focus elsewhere hides it")

	print("read aloud")
	var narrator: Node = Narrator.new()
	var voice := FakeVoice.new()
	narrator.voice = voice
	root.add_child(narrator)
	narrator.enabled = true
	narrator.screen_root = page
	toggle.grab_focus()
	narrator._process(0.1)
	var said: Array = []
	for u in voice.said:
		said.append(str(u["text"]))
	check(said.size() >= 2 and said[0] == "Field of view, switch, off",
			"the focused switch is read first (%s)" % str(said))
	check(said.has("The camera's field of view, in degrees."), "then its hidden text")
	voice.said.clear()
	toggle.button_pressed = true
	narrator._process(0.1)
	check(voice.said.size() == 1, "a change of state is read without the text again")
	other.grab_focus()
	narrator._process(0.1)
	toggle.grab_focus()
	narrator._process(0.1)
	var again := false
	for u in voice.said:
		again = again or str(u["text"]) == "The camera's field of view, in degrees."
	check(again, "coming back to the row reads it again")
	narrator.queue_free()
	page.queue_free()
	await process_frame

func _menu() -> void:
	print("the menu")
	OS.set_environment("GOANNA_MENU", "1")
	OS.set_environment("GOANNA_NO_SHOWCASE", "1")
	var menu := preload("res://menu/menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	menu._show_settings()
	await process_frame
	check(menu.screen_info != null and not menu.screen_info.revealed(),
			"Settings explains itself behind an (i) beside its title")
	var texts := _visible_texts(menu)
	check(not texts.has("Applied when you next join a world. The pause menu has the same settings, and changes there take effect immediately."),
			"rather than a paragraph")
	check(_icons(menu.screen).size() > 20, "every setting has an (i) (%d)" % _icons(menu.screen).size())
	var described := false
	for t in texts:
		described = described or str(t).begins_with("How much world to ask the server for")
	check(not described, "and no setting's description is on screen")
	check(texts.has(menu.NOT_RECORDED), "but a value not recorded yet still says so")
	menu._show_join()
	await process_frame
	check(not str(menu.status_label.text).contains("registered with this password"),
			"Join Game's status line no longer explains registration")
	var pass_icon: InfoIcon = null
	for icon in _icons(menu.screen):
		if (icon as InfoIcon).owner_control == menu.pass_edit:
			pass_icon = icon
	check(pass_icon != null, "an (i) beside Password does instead")
	if pass_icon != null:
		menu.pass_edit.grab_focus()
		await process_frame
		check(pass_icon.revealed(), "and shows when the password field has the focus")
	menu._show_new_game()
	await process_frame
	if menu.generator_info != null and is_instance_valid(menu.generator_info):
		check(not menu.generator_info.revealed()
				and str(menu.generator_info.label.text).begins_with("Terrain Diffusion uses"),
				"Start Game's biome note is behind World generator's (i)")
		check(not _visible_texts(menu).has(menu.TERRAIN_SUPPORT), "not on screen")
	else:
		print("  skip Start Game: no Luanti install with a game here")
	menu.free()
	await process_frame

func _in_game() -> void:
	print("the in-game panel")
	OS.set_environment("GOANNA_NO_POINTER_CAPTURE", "1")
	OS.set_environment("GOANNA_NO_STORE", "1")
	var game := preload("res://game/main.tscn").instantiate()
	game.connect_automatically = false
	root.add_child(game)
	await process_frame
	await process_frame
	var panel: Control = game.ui._build_settings()
	panel.visible = true
	await process_frame
	check(_icons(panel).size() > 20, "the in-game settings rows have (i) icons (%d)" % _icons(panel).size())
	var texts := _visible_texts(panel)
	var described := false
	for t in texts:
		described = described or str(t).begins_with("How much world to ask the server for")
	check(not described, "and no description is on screen")
	var pack_picker: OptionButton = null
	for p in panel.find_children("*", "OptionButton", true, false):
		if (p as OptionButton).item_count > 0 \
				and (p as OptionButton).get_item_text(0) == preload("res://ui/shader_pack_row.gd").NONE_LABEL:
			pack_picker = p
	check(pack_picker != null and pack_picker.is_visible_in_tree(),
			"the shader pack picker is in view on the Graphics tab, not folded away")
	panel.queue_free()
	game.queue_free()
	await process_frame
