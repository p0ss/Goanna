# SPDX-License-Identifier: LGPL-2.1-or-later
## Live regression probe for material warming and regional tangent uploads.
## Run after a terrain fixture settles, through the development channel:
## return await load("res://tests/material_warm.gd").run(client)
extends RefCounted

static func wait_for_warm(client: GoannaClient) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		if client.render_stats().get("material_warm_complete", false):
			return true
		await client.get_tree().process_frame
	return false

static func run(client: GoannaClient) -> Dictionary:
	var failures: Array[String] = []
	if not await wait_for_warm(client):
		failures.append("Initial material warming did not finish")
	var before := client.render_stats()
	if before.get("near_regions", 0) == 0:
		failures.append("Fixture has no published near regions")
	var surfaces := 0
	var vertices := 0
	for node in client.get_children():
		if not node is MeshInstance3D or not node.mesh:
			continue
		for i in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(i)
			if arrays[Mesh.ARRAY_TANGENT] == null:
				continue
			surfaces += 1
			vertices += arrays[Mesh.ARRAY_VERTEX].size()
			if arrays[Mesh.ARRAY_TANGENT].size() != 4 * arrays[Mesh.ARRAY_VERTEX].size():
				failures.append("Tangent count differs from vertex count")
			for value in arrays[Mesh.ARRAY_TANGENT]:
				if not is_finite(value):
					failures.append("Non-finite tangent component")
	if surfaces == 0:
		failures.append("Fixture has no surfaces with tangents")
	var old := client.solid_ice()
	client.set_solid_ice(not old)
	if client.render_stats().get("material_warm_complete", true):
		failures.append("Material invalidation did not reset warming")
	if not await wait_for_warm(client):
		failures.append("Material warming did not finish after invalidation")
	var rebuilt := client.material_count()
	if rebuilt == 0:
		failures.append("Material cache stayed empty")
	client.set_solid_ice(old)
	if not await wait_for_warm(client):
		failures.append("Material warming did not finish after restoring settings")
	return {"failures": failures, "surfaces": surfaces, "vertices": vertices,
		"materials_before": before.get("materials", 0), "materials_rebuilt": rebuilt}
