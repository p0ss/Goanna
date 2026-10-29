# SPDX-License-Identifier: LGPL-2.1-or-later
## Shared server rune media on the overseer's section and tool buttons.
## Headless, without a renderer or server:
## godot --headless --path project --script res://tests/overseer_runes.gd
extends SceneTree
const Unit := preload("res://tests/overseer.gd")
const Overseer := preload("res://game/overseer.gd")
var failures := 0
var checks := 0

class RuneClient extends Unit.TestClient:
	var requested: Array[String] = []
	var mark: Texture2D
	func _init() -> void:
		var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		image.fill(Color.WHITE)
		mark = ImageTexture.create_from_image(image)
	func texture(name: String) -> Texture2D:
		requested.append(name)
		return mark

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", text)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var main := Unit.TestMain.new(); root.add_child(main)
	var client := RuneClient.new(); main.add_child(client)
	var view := Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	var ui = view.ui
	ui.update_capabilities({"section_runes": {"Zones": "zone", "Plans": "tasks", "Defence": "shield"}})
	var sections := 0
	for child in ui.rail.get_children():
		if child is Button and child.has_meta("family"):
			var name := str(child.get_meta("family"))
			if name in ["Zones", "Plans", "Defence"]:
				sections += 1
				check(child.icon == client.mark and child.text == name,
					"section keeps its readable label beside the server rune: " + name)
				check(child.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
					"section rune keeps its pixel edges: " + name)
	check(sections == 3, "all advertised section runes are displayed")
	var tool := Button.new()
	ui.set_icon(tool, "build_workshop", false, "anvil")
	check(tool.icon == client.mark and client.requested[-1] == "dorfcraft_runes_anvil_ink.png",
		"workshop uses the shared game anvil rather than separate client artwork")
	var before := client.requested.size()
	check(ui.rune_for("../outside") == null and client.requested.size() == before,
		"a malformed symbol never becomes a media lookup")
	ui.update_capabilities({"summary": "Older server"})
	for child in ui.rail.get_children():
		if child is Button and child.has_meta("family"):
			check(child.icon == null and not child.text.is_empty(),
				"older server retains text without a stale rune: " + child.text)
	check(client.sent.filter(func(message: Dictionary) -> bool: return message.get("t") == "order").is_empty(), "drawing runes sends no work orders")
	tool.free()
	view._close(); view.queue_free(); main.queue_free()
	await process_frame
	print("Overseer runes: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
