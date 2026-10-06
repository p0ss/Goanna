# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercise the vanilla formspec route without joining the overseer channel.
extends SceneTree
var client: GoannaClient
var forms: Array = []
var failures := 0
var phase := "connect"
func _initialize() -> void:
	call_deferred("run")
func _process(_delta: float) -> bool:
	if client != null:
		client.poll_blocks(0)
		forms.append_array(client.take_shown_formspecs())
	return false
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func until(predicate: Callable, seconds := 15.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		if predicate.call(): return true
		await create_timer(0.1).timeout
	print("Timeout: ", phase)
	return false
func plan_text() -> String:
	for i in range(forms.size()-1,-1,-1):
		var f: Dictionary = forms[i]
		if f.get("formname") == "overseer:plan" and not str(f.get("formspec", "")).is_empty(): return f.formspec
	return ""
func run() -> void:
	client = GoannaClient.new()
	root.add_child(client)
	client.connect_to("127.0.0.1", 30561, "overseertest", "")
	if not await until(func() -> bool: return client.status().get("state") == "ready", 90.0):
		print(client.status()); client.disconnect_from_server(); quit(1); return
	client.send_chat("/overseer_fixture")
	await create_timer(1.0).timeout
	client.send_chat("/overseer")
	phase = "fallback form"
	check(await until(func() -> bool: return not plan_text().is_empty()), "no native handshake opens the vanilla plan")
	check("cell_256" in plan_text(), "plan displays a bounded 16 by 16 grid")
	check("level 0" in plan_text(), "fallback opens at body level")
	forms.clear()
	client.send_inventory_fields("overseer:plan", {"down": "true"})
	phase = "form level change"
	check(await until(func() -> bool: return "level -1" in plan_text()), "form changes level through the server")
	forms.clear()
	client.send_inventory_fields("overseer:plan", {"up": "true"})
	await until(func() -> bool: return "level 0" in plan_text())
	# Grid starts at -8,-8; cell 137 is the known origin.
	forms.clear()
	client.send_inventory_fields("overseer:plan", {"cell_137": "true"})
	phase = "material inspection"
	check(await until(func() -> bool: return "observed day" in plan_text()), "form exposes material and date")
	forms.clear()
	client.send_inventory_fields("overseer:plan", {"family_2": "true"})
	await create_timer(0.3).timeout
	client.send_inventory_fields("overseer:plan", {"cell_141": "true"})
	await until(func() -> bool: return "First corner selected" in plan_text())
	forms.clear()
	client.send_inventory_fields("overseer:plan", {"cell_142": "true"})
	phase = "form review"
	check(await until(func() -> bool: return "No work has been issued" in plan_text()), "second corner creates a draft without submitting")
	forms.clear()
	client.send_inventory_fields("overseer:plan", {"submit": "true"})
	phase = "form dig"
	check(await until(func() -> bool: return "Excavation planned" in plan_text()), "form submits excavation through the shared handler")
	client.send_inventory_fields("overseer:plan", {"quit": "true"})
	await create_timer(0.5).timeout
	var grants := 0
	for h in client.hud_state().get("elements", []):
		if h.get("name") == "dorfcraft:overseer": grants += 1
	check(grants == 0, "closing fallback removes session HUD")
	# Leaving an open session by disconnect must restore on rejoin.
	client.send_chat("/overseer")
	await create_timer(1.5).timeout
	client.disconnect_from_server()
	client.queue_free()
	client = null
	await create_timer(0.5).timeout
	client = GoannaClient.new()
	root.add_child(client)
	client.connect_to("127.0.0.1", 30561, "overseertest", "")
	phase = "reconnect"
	check(await until(func() -> bool: return client.status().get("state") == "ready", 90.0), "reconnect after leaving an open view")
	grants = 0
	for h in client.hud_state().get("elements", []):
		if h.get("name") == "dorfcraft:overseer": grants += 1
	check(grants == 0, "reconnect has no stale session capability")
	var movement: Dictionary = client.step_player(0.1, {}, 0.0, 0.0)
	print("Reconnect movement state: ", movement)
	client.disconnect_from_server()
	print("Overseer fallback failures: ", failures)
	quit(1 if failures else 0)
