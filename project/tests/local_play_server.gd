# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
# Run by tools/test-local-play.py against its disposable Luanti server.
extends SceneTree

const Shell := preload("res://local_play.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func _run() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "material_updates", false)
	cfg.save("user://goanna.cfg")
	var shell := Shell.new()
	shell.automatic_launch = false
	shell.capture_mouse = false
	root.add_child(shell)
	var count := maxi(2, int(OS.get_environment("GOANNA_TEST_PLAYERS")))
	for i in count:
		shell.add_player({"name": "local_test_%d" % (i + 1), "password": "",
			"host": "127.0.0.1", "port": int(OS.get_environment("GOANNA_TEST_PORT")), "device": i})
	var deadline := Time.get_ticks_msec() + 45000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		ready = true
		for i in shell.slots.size():
			var client: Node = shell.slots[i].game.client
			var inventory: Array = client.inventory_state().get("lists", {}).get("main", [])
			if client.status().get("state") != "ready" or inventory.is_empty() or int(inventory[0].get("count", 0)) != i + 1:
				ready = false
		if ready: break
		await create_timer(0.1).timeout
	check(ready, "%d independent connections receive their own inventory" % count)
	if ready:
		var first: Node = shell.slots[0].game
		var second: Node = shell.slots[1].game
		first.ui._open_inventory()
		check(first.ui.blocks_input() and not second.ui.blocks_input(), "A live player's inventory blocks only that player")
		first.client.inventory_action("Move 1 current_player main 0 current_player main 1")
		deadline = Time.get_ticks_msec() + 5000
		var moved := false
		while Time.get_ticks_msec() < deadline:
			var inventory: Array = first.client.inventory_state().get("lists", {}).get("main", [])
			if inventory.size() > 1 and int(inventory[1].get("count", 0)) == 1:
				moved = true
				break
			await create_timer(0.1).timeout
		check(moved, "The server accepts an ordinary inventory move from player 1")
		check(int(second.client.inventory_state()["lists"]["main"][0]["count"]) == 2,
			"Player 2's inventory is unaffected by player 1's move")
		shell.remove_player(shell.slots[0])
		await create_timer(0.3).timeout
		for slot in shell.slots:
			check(slot.game.client.status().get("state") == "ready", "Remaining connections survive a player leaving")
	shell.free()
	await process_frame
	print("local play server: %d failures" % failures)
	quit(1 if failures else 0)
