# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The Shader pack row of the Shader packs settings, shared by the
## main menu (menu/menu.gd) and the in-game panel (ui/game_ui.gd) for the
## "shaderpack" kind of their shared SETTINGS table: a picker of None and
## the packs in the shader pack folder, the folder's path with a button to
## open it, how the pack did at the last join, and the selected pack's
## options. build_tab puts it beside Mods on Start Game; build_join_picker
## is a compact version for Join Game. Everything is saved to goanna.cfg
## through game/shader_packs.gd and applies at the next join, when main.gd
## loads the pack; nothing here touches a running world. Static only.
extends RefCounted

const ShaderPacks := preload("res://game/shader_packs.gd")
const PanelFit := preload("res://ui/panel_fit.gd")
const GlassStyle := preload("res://ui/glass_style.gd")

const NOTE := "Saved. Applies the next time you join a world."
## The first entry of every pack picker: no pack, Goanna's own renderer.
const NONE_LABEL := "None (Goanna's own look)"
const FOLDER_HINT := "Put a pack's zip, as downloaded, or its folder in the shader pack folder, then press Look again."
## The short introduction shared by the full pack tabs.
const DESCRIPTION := "Choose Goanna's own look or an Iris or OptiFine shader pack. Pack support is incomplete. Changes apply the next time you join a world."
## The (i) beside Shaders on Join Game.
const JOIN_INFO := "Choose how the world looks. Add packs and change their options in Settings, Shader packs. Changes apply when you join."

## Fills `row` (from PanelFit.row) under the setting's name. `description`
## is the SETTINGS entry's text.
static func build(row: VBoxContainer, description: String) -> OptionButton:
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(picker)
	var note := _small(row, NOTE, Color(1, 0.85, 0.4))
	note.visible = false
	var status := _small(row, "", Color(1, 1, 1, 0.8))
	_compact_status(status)
	PanelFit.describe(row, description + " " + FOLDER_HINT, 0.5)
	# The folder, as selectable text and a button: on a desktop the button
	# opens a file manager, and where nothing answers it (a console session)
	# the path is still there to read or copy.
	var where := HBoxContainer.new()
	where.add_theme_constant_override("separation", 8)
	var path := LineEdit.new()
	path.text = ShaderPacks.folder()
	path.editable = false
	path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path.tooltip_text = "Put shader pack zips or folders here"
	where.add_child(path)
	row.add_child(where)
	var options := VBoxContainer.new()
	options.add_theme_constant_override("separation", 10)
	row.add_child(options)

	var fill := func() -> void:
		var current := fill_picker(picker)
		show_status(status, current)
		_build_options(options, current, note)
	fill.call()
	folder_buttons(where, fill)
	picker.item_selected.connect(func(i: int) -> void:
		var name := str(picker.get_item_metadata(i))
		ShaderPacks.set_chosen(name)
		note.visible = true
		show_status(status, name)
		_build_options(options, name, note))
	return picker

## The full picker and pack options on a tab beside the world's Mods tab.
static func build_tab(tabs: TabContainer) -> OptionButton:
	var scroll := ScrollContainer.new()
	scroll.name = "Shader packs"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var pad := PanelFit.page_padding()
	scroll.add_child(pad)
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(page)
	var shell := PanelFit.row(page, "Shader pack")
	return build(shell[0], DESCRIPTION)

## The compact Join Game form under Materials: the picker, the folder's
## two buttons and the last join's line,
## with no pack options. Saved to the same setting as the Settings row, at
## once, so the join that follows loads it. With `beside` (the line holding
## the row's label), an (i) there explains it. Returns the picker.
static func build_join_picker(parent: Control, beside: Container = null) -> OptionButton:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	box.add_child(line)
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.tooltip_text = "An Iris or OptiFine shader pack from the shader pack folder"
	line.add_child(picker)
	var status := _small(box, "", Color(1, 1, 1, 0.8))
	_compact_status(status)
	parent.add_child(box)
	var fill := func() -> void:
		show_status(status, fill_picker(picker))
	fill.call()
	folder_buttons(line, fill)
	if OS.get_environment("GOANNA_SHADERPACK") != "":
		_small(box, "GOANNA_SHADERPACK is set, so a join loads that pack instead.",
				Color(1, 0.85, 0.4))
	if beside != null:
		PanelFit.info(box, beside, JOIN_INFO, box)
	picker.item_selected.connect(func(i: int) -> void:
		var name := str(picker.get_item_metadata(i))
		ShaderPacks.set_chosen(name)
		show_status(status, name))
	return picker

## Lists None and every pack in the folder in `picker`, selects the saved
## choice and returns it. The metadata of each item is the name saved.
static func fill_picker(picker: OptionButton) -> String:
	picker.clear()
	picker.add_item(NONE_LABEL)
	picker.set_item_metadata(0, "")
	var current := ShaderPacks.chosen()
	var shown := {}
	for p in ShaderPacks.scan():
		var label := ShaderPacks.display_name(str(p["name"]))
		if shown.has(label):
			label = str(p["name"])
		shown[label] = true
		picker.add_item(label)
		picker.set_item_metadata(picker.item_count - 1, str(p["name"]))
	var selected := 0
	for i in picker.item_count:
		if str(picker.get_item_metadata(i)) == current:
			selected = i
	if current != "" and selected == 0:
		# Saved, but gone from the folder: say so rather than show None,
		# which would claim the next join runs without one.
		picker.add_item("%s (not in the folder)" % current)
		picker.set_item_metadata(picker.item_count - 1, current)
		selected = picker.item_count - 1
	picker.select(selected)
	return current

## Open folder and Look again, added to `box`; Look again calls `rescan`.
static func folder_buttons(box: Container, rescan: Callable) -> void:
	var folder := ShaderPacks.folder()
	var open_button := Button.new()
	open_button.text = "Open folder"
	open_button.tooltip_text = folder
	open_button.pressed.connect(func() -> void: OS.shell_open(folder))
	box.add_child(open_button)
	var again := Button.new()
	again.text = "Look again"
	again.tooltip_text = "List the shader pack folder again, after adding a pack"
	again.pressed.connect(rescan)
	box.add_child(again)

static func _small(row: VBoxContainer, text: String, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 13)
	GlassStyle.tint_text(l, colour)
	row.add_child(l)
	return l

## How the pack did at the last join that loaded it from this setting, in
## `status`, hidden when there is nothing to say about pack `name`.
static func show_status(status: Label, name: String) -> void:
	var last := ShaderPacks.last_status()
	if name == "" or last.is_empty() or str(last.get("pack", "")) != name:
		status.text = ""
		status.tooltip_text = ""
		status.visible = false
		return
	status.text = "Last join: %s" % str(last["text"])
	status.tooltip_text = status.text
	status.visible = true

static func _compact_status(status: Label) -> void:
	status.max_lines_visible = 2
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

# The selected pack's options, folded away and read only when opened: a
# zipped pack is unpacked to read them, and a large pack has hundreds.
static func _build_options(box: VBoxContainer, name: String, note: Label) -> void:
	for c in box.get_children():
		c.queue_free()
	if name == "":
		return
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	var header := Button.new()
	header.toggle_mode = true
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.custom_minimum_size = Vector2(0, 40)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.text = "▸  Pack options"
	bar.add_child(header)
	var reset := Button.new()
	reset.text = "Pack defaults"
	reset.tooltip_text = "Forget the options changed for this pack"
	bar.add_child(reset)
	box.add_child(bar)
	PanelFit.info(bar, bar, "Switches and lists only: options that are numbers set in the pack's "
			+ "own code (const lines) and option profiles are not offered.", box, 1, 0.5)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 12)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.visible = false
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(body)
	box.add_child(pad)
	var populate := func() -> void:
		for c in body.get_children():
			c.queue_free()
		_fill_options(body, name, note)
	header.toggled.connect(func(on: bool) -> void:
		header.text = ("▾" if on else "▸") + "  Pack options"
		pad.visible = on
		if on and body.get_child_count() == 0:
			populate.call())
	reset.pressed.connect(func() -> void:
		ShaderPacks.clear_options(name)
		note.visible = true
		if pad.visible:
			populate.call())

static func _fill_options(body: VBoxContainer, name: String, note: Label) -> void:
	var r := ShaderPacks.resolve(name)
	if r.has("error"):
		_small(body, "Cannot read this pack: %s" % str(r["error"]), Color(1, 0.6, 0.5))
		return
	var read := ShaderPacks.read_options(str(r["path"]))
	var opts: Dictionary = read["options"]
	var layout: Array = read["layout"]
	if layout.is_empty():
		_small(body, "This pack has no options Goanna can set.", Color(1, 1, 1, 0.6))
		return
	var saved := ShaderPacks.saved_options(name)
	for item in layout:
		if item.has("heading"):
			PanelFit.heading(body, str(item["heading"]))
			continue
		var opt := str(item["option"])
		var o: Dictionary = opts[opt]
		var default := str(o["default"])
		var value := str(saved.get(opt, default))
		var shell: Array = PanelFit.row(body, str(o["label"]))
		var orow: VBoxContainer = shell[0]
		var head: HBoxContainer = shell[1]
		if o["kind"] == "bool":
			var check := CheckButton.new()
			check.button_pressed = value == "true"
			check.toggled.connect(func(on: bool) -> void:
				ShaderPacks.save_option(name, opt, "true" if on else "false", default)
				note.visible = true)
			head.add_child(check)
		else:
			var pick := OptionButton.new()
			pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var labels: Dictionary = o["value_labels"]
			for v in o["values"]:
				var shown := str(labels.get(v, v))
				if v == default:
					shown += "  (pack default)"
				pick.add_item(shown)
				pick.set_item_metadata(pick.item_count - 1, str(v))
				if str(v) == value:
					pick.select(pick.item_count - 1)
			pick.item_selected.connect(func(i: int) -> void:
				ShaderPacks.save_option(name, opt, str(pick.get_item_metadata(i)), default)
				note.visible = true)
			orow.add_child(pick)
		var comment := str(o["comment"])
		PanelFit.describe(orow, opt if comment == "" else "%s  (%s)" % [comment, opt], 0.45)
