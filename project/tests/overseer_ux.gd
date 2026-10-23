# SPDX-License-Identifier: LGPL-2.1-or-later
## Checks the overseer's draft lifecycle and accessible input, with the
## stand ins from tests/overseer.gd. No renderer, server or GPU:
## godot --headless --path project --script res://tests/overseer_ux.gd
extends SceneTree
const Unit := preload("res://tests/overseer.gd")
const Overseer := preload("res://game/overseer.gd")
var failures := 0
var checks := 0
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", text)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var main := Unit.TestMain.new(); root.add_child(main)
	var client := Unit.TestClient.new(); main.add_child(client)
	var view := Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	var tools := [{"id":"inspect", "title":"Inspect", "family":"Select"},
		{"id":"dig", "title":"Dig", "family":"Terrain", "height":2},
		{"id":"harvest", "title":"Harvest", "family":"Gather", "disabled":true, "reason":"No gathering authority"},
		{"id":"wall", "title":"Wall", "family":"Build", "material":"block"},
		{"id":"workshop", "title":"Set up workshop", "family":"Build", "material":"station", "width":3, "depth":3, "help":"Visit the ledger"}]
	view._receive({"v":1,"t":"hello","claim":{"min":{"x":-32,"y":-32,"z":-32},"max":{"x":32,"y":32,"z":32}},
		"y":0,"body":{"x":0,"y":0,"z":0},"tools":tools})
	view.ui.choose_family("Terrain"); view.choose_tool("dig")
	var before := client.sent.size()
	view.select_cell({"x":1,"y":0,"z":1});view.select_cell({"x":3,"y":0,"z":2})
	check(client.sent.size()==before, "two corners never dispatch work")
	check("12 cells" in view.draft_summary(), "dig review counts two-high volume")
	check(view.can_submit(), "complete draft can submit")
	view.change_level(1)
	check(view.first_corner.y==0 and not view.can_submit(), "level change preserves draft and prevents retargeted submission")
	view.return_to_draft()
	check(view.level==0 and view.can_submit(), "return to draft restores edit level")
	view._clear_layer();view.refresh_draft()
	check(view.last_corner.x==3, "camera refresh cannot erase draft intent")
	view.submit_draft()
	var request: Dictionary = client.sent[-1].duplicate(true)
	check(request.t=="order" and request.a.y==0 and request.b.x==3, "explicit submit sends reviewed footprint")
	view.submit_draft()
	check(client.sent[-1]==request, "retry preserves request ID and payload")
	view._receive({"v":1,"t":"reply","req":"unrelated","ok":true})
	check(not view.pending.is_empty(), "unrelated reply cannot complete draft")
	view._receive({"v":1,"t":"reply","req":request.req,"ok":false,"reason":"No access"})
	check(view.pending.is_empty() and view.last_corner!=null, "server refusal retains editable draft")
	view.submit_draft();request=client.sent[-1].duplicate(true)
	view._receive({"v":1,"t":"reply","req":request.req,"ok":true,"reason":"Queued"})
	check(view.first_corner==null and view.pending.is_empty(), "acknowledged submission clears draft")
	view.ui.choose_family("Gather"); view.choose_tool("harvest")
	check(view.tool=="inspect" and view.inspector.text=="No gathering authority", "unavailable action explains server reason")
	view.ui.choose_family("Terrain");view.choose_tool("dig")
	view.select_cell({"x":0,"y":0,"z":0});view.select_cell({"x":1,"y":0,"z":0})
	tools[1].disabled=true
	view.ui.update_capabilities({"tools":tools,"summary":"Changed permissions"})
	check(not view.can_submit() and view.first_corner!=null, "revoked capability disables submit without losing draft")
	view.go_back()
	check(view.active and view.first_corner==null, "Back discards draft before leaving mode")
	view.ui.choose_family("Build");view.choose_tool("wall")
	view._update_materials([{"name":"stone","title":"Stone","kind":"block"}])
	view.select_cell({"x":0,"y":0,"z":0});view.select_cell({"x":0,"y":0,"z":0})
	view._update_materials([{"name":"wood","title":"Wood","kind":"block"}])
	check(not view.can_submit() and view.build_materials[view.build_material.selected].name=="stone", "stock change cannot silently substitute another material")
	view.discard_draft()
	view.choose_tool("workshop")
	check(view.inspector.text == "Visit the ledger", "workshop selection explains the physical ledger")
	view._update_materials([])
	view.select_cell({"x":0,"y":0,"z":0});view.select_cell({"x":2,"y":0,"z":2})
	check(not view.can_submit(), "workshop needs a station selection")
	view._update_materials([{"name":"still","title":"Brewing - Still","kind":"station"}, {"name":"table","title":"Woodworking - Crafting table","kind":"station"}])
	check(view.build_material.selected == -1 and not view.can_submit(), "workshop never defaults to the first stocked station")
	view.build_material.select(1);view.refresh_draft()
	check(view.draft_summary().contains("Woodworking - Crafting table"), "review explicitly names the selected workshop")
	view._update_materials(view.material_catalog)
	check(view.build_materials[view.build_material.selected].name == "table", "catalogue refresh preserves the selected workshop")
	check(view.can_submit(), "workshop accepts a 3 by 3 site and station")
	view.last_corner={"x":3,"y":0,"z":2}
	check(not view.can_submit(), "workshop rejects a wrongly sized footprint")
	view.discard_draft()
	view.ui.choose_family("Plans")
	view.ui.update_plans([{"id":"o1","kind":"dig","state":"Queued","by":"A","total":2,"done":0,"can_cancel":true,"pos":{"x":4,"y":3,"z":5}}])
	view.ui.plans.select(0);view.ui.select_plan(0);view.ui.locate_plan()
	check(view.level==3 and view.centre==Vector2(4,5), "Locate uses the recorded plan position")
	view.ui.cancel_plan()
	check(client.sent[-1].t=="cancel" and client.sent[-1].id=="o1", "plan cancellation uses server request")
	view.pending = {}
	view.ui.update_plans([{"id":"station:*","kind":"station","title":"Guard station","state":"Designated","total":1,"done":0,"reason":"Patrol access unknown","can_cancel":true}])
	view.ui.plans.select(0);view.ui.select_plan(0)
	check(view.ui.plan_detail.text.contains("Issued by Fortress") and view.ui.plan_detail.text.contains("Patrol access unknown"),
		"Plans selects a designation without an issuer and retains its reason")
	view.pending={};view.ui.focus_map()
	var key := InputEventKey.new(); key.keycode=KEY_RIGHT;key.pressed=true
	view._input(key)
	check(view.cursor.x==5, "keyboard map focus nudges a cell")
	var pad := InputEventJoypadButton.new();pad.button_index=JOY_BUTTON_DPAD_LEFT;pad.pressed=true
	view._input(pad)
	check(view.cursor.x==4, "controller map focus nudges a cell")
	view.pending = {}
	view.discard_draft()
	view.tools.append_array([
		{"id":"farm:wheat","title":"Wheat farm","family":"Zones","group":"Farm","option":"Wheat","group_property":"Crop"},
		{"id":"farm:carrot","title":"Carrot farm","family":"Zones","group":"Farm","option":"Carrot","group_property":"Crop"},
		{"id":"stockpile_area","title":"Stockpile","family":"Zones","group":"Storage","option":"General","group_property":"Storage type"}])
	view.ui.choose_family("Zones")
	check(view.ui.actions.get_child_count() == 2, "Zones collapses crops into Farm and Storage groups")
	view.ui.choose_group("Farm")
	check(view.tool == "farm:wheat" and view.ui.zone_property.text == "Crop" and view.ui.zone_options.item_count == 2,
		"Farm exposes crop as a property with the original tool IDs")
	view.ui.zone_options.item_selected.emit(1)
	check(view.tool == "farm:carrot", "crop selection changes the submitted farm tool")
	view.ui.choose_family("People")
	check(client.sent[-1].t == "overview" and view.ui.overview_text.visible and not view.inspector.visible,
		"People requests the server overview and opens its own panel")
	view._receive({"v":1,"t":"overview","people":[{"name":"Ada","assignment":"Farmer","activity":"Walking","observed":"8 seconds ago","reason":"Last seen activity"}],
		"people_note":"Observed workers only","supplies":[{"name":"axe","title":"Iron axe","count":2}],"supplies_note":"Original embark manifest, not current stock"})
	check(view.ui.overview_text.text.contains("Ada") and view.ui.overview_text.text.contains("8 seconds ago")
		and view.ui.overview_text.text.contains("Last seen activity"), "People retains observation age and uncertainty")
	view.ui.choose_family("Supplies")
	check(view.ui.overview_text.text.contains("Iron axe: 2") and view.ui.overview_text.text.contains("not current stock"),
		"Supplies presents the server manifest and its accounting limit")
	view._receive({"v":1,"t":"overview","people":null,"supplies":null,"supplies_note":"Manifest unavailable"})
	check(view.ui.overview_text.text == "Manifest unavailable", "legacy manifest absence displays its reason without inventing totals")
	view.ui.choose_family("Build")
	view.choose_tool("workshop")
	view._update_materials([{"name":"forge","title":"Forge","kind":"station","missing":true,"reason":"No anvil available","requirements":"Needs an anvil"}])
	view.build_material.select(0)
	view.select_cell({"x":0,"y":view.level,"z":0});view.select_cell({"x":2,"y":view.level,"z":2})
	check(not view.can_submit() and view.ui.requirements.text.contains("No anvil available")
		and view.ui.requirements.text.contains("Needs an anvil"), "unavailable workshop remains inspectable with requirements and cannot submit")
	view.discard_draft()
	view.body = Vector3(2, 5, -4)
	view.level = 3
	view.ui.refresh()
	check(view.ui.player_location.text.contains("2 above"), "navigation indicates the player's different level")
	view.recentre()
	check(view.level == 5 and view.centre == Vector2(2, 4) and view.ui.player_location.text.contains("(here)"), "Find you returns to the player's position and level")
	view._clear_children(view.overlay)
	view._draw_player_marker()
	check(view.overlay.get_child_count() == 4 and view.overlay.get_child(3) is Label3D
		and view.overlay.get_child(3).text == "You", "player marker has three outline layers and an explicit You caption")
	view._clear_children(view.overlay)
	view.level = 4
	view._draw_player_marker()
	check(view.overlay.get_child_count() == 0, "player marker never pretends to be on another level")
	root.size = Vector2i(1280,720)
	view.root_control.theme.default_font_size = 36
	for i in 5: await process_frame
	check(view.ui.footer.get_global_rect().end.y <= 720, "large-text footer stays inside viewport")
	check(view.ui.panel.get_global_rect().position.y >= view.ui.top.get_global_rect().end.y, "large-text panel clears header")
	view._close();main.queue_free()
	print("Overseer UX: %d checks, %d failures" % [checks,failures])
	quit(1 if failures else 0)
