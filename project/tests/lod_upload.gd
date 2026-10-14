# SPDX-License-Identifier: LGPL-2.1-or-later
## Run against a settled mixed stone/liquid far-terrain fixture:
## return await load("res://tests/lod_upload.gd").run(client)
extends RefCounted

static func settle(client: GoannaClient) -> bool:
	var deadline := Time.get_ticks_msec() + 60000
	var quiet := 0
	while Time.get_ticks_msec() < deadline:
		await client.get_tree().process_frame
		var stats := client.render_stats()
		var busy := false
		for key in ["blocks_queued", "near_ready", "near_regions_dirty",
			"near_regions_building", "lod_regions_dirty", "lod_building",
			"lod_uploading", "mesh_queued", "mesh_running", "mesh_ready",
			"lod_storage_pending", "lod_storage_queued", "lod_storage_active"]:
			busy = busy or stats.get(key, 0) > 0
		quiet = 0 if busy else quiet + 1
		if quiet >= 30:
			return true
	return false

static func visible_meshes(client: GoannaClient) -> Dictionary:
	var meshes := {}
	for node in client.get_children():
		if node is MeshInstance3D and node.mesh:
			meshes[node.get_instance_id()] = node.mesh.get_instance_id()
	return meshes

static func run(client: GoannaClient) -> Dictionary:
	var failures: Array[String] = []
	if not await load("res://tests/material_warm.gd").wait_for_warm(client):
		failures.append("Material warming did not finish")
	var old_distance := client.lod_distance()
	var old_threads := client.mesh_threads()
	client.set_lod_distance(1)
	if not await settle(client):
		failures.append("Initial far terrain did not settle")
	var before := client.render_stats()
	if before.get("lod_surfaces", 0) == 0:
		failures.append("Fixture has no far surfaces")
	var original := visible_meshes(client)
	client.set_mesh_threads(2 if old_threads == 1 else 1)
	var staged := 0
	var retained := 0
	var cancelled := false
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not cancelled:
		await client.get_tree().process_frame
		var visible := visible_meshes(client)
		for upload in client.lod_uploads():
			if upload.kind != "region":
				continue
			staged += 1
			if upload.surface <= 0 or upload.surface >= upload.total:
				failures.append("Unexpected partial upload cursor")
			if upload.staged_mesh in visible.values():
				failures.append("Partly uploaded replacement entered the scene")
			if original.has(upload.visible_node):
				retained += 1
				if original[upload.visible_node] != upload.visible_mesh:
					failures.append("Old mesh changed before replacement was complete")
		if staged > 0:
			client.set_mesh_threads(old_threads)
			cancelled = true
			if not client.lod_uploads().is_empty():
				failures.append("Worker restart left a staged upload behind")
	if staged == 0 or retained == 0:
		failures.append("Did not observe an upload retaining its old mesh")
	if not await settle(client):
		failures.append("Far terrain did not drain after cancelling uploads")
	var after := client.render_stats()
	if after.get("lod_material_cold_builds", -1) != before.get("lod_material_cold_builds", -2):
		failures.append("Publication created a far material after warming completed")
	client.set_mesh_threads(old_threads)
	client.set_lod_distance(old_distance)
	return {"failures": failures, "staged": staged, "retained": retained,
		"cancelled": cancelled, "before": before, "after": after}
