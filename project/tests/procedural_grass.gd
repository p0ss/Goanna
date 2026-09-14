# SPDX-License-Identifier: LGPL-2.1-or-later
# Headless regression: toggle existing near/LOD meshes without duplicating
# surfaces, changing base terrain, or leaving grass-owned AA enabled.
extends SceneTree

class TestMain extends "res://main.gd":
	func _ready() -> void:
		pass
	func _process(_delta: float) -> void:
		pass

var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1

func terrain(lod: bool) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	var offset := 0.0 if lod else -0.5
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(offset,0,offset), Vector3(offset+1,0,offset),
		Vector3(offset+1,0,offset+1), Vector3(offset,0,offset+1)])
	a[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP])
	a[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO])
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0,2,1,0,3,2])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,a)
	var material := ShaderMaterial.new()
	material.set_meta("goanna_grass_layers", {0:Color(0.3,0.6,0.1)})
	mesh.surface_set_material(0,material)
	mesh.set_meta("goanna_grass_lod",lod)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	return instance

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var menu = load("res://menu.gd").new()
	check(menu._settings_default(["Video","procedural_grass","toggle"])==0.0,
		"The main menu must show grass off before the first game")
	menu.free()
	OS.unset_environment("GOANNA_GRASS")
	var main := TestMain.new()
	root.add_child(main)
	main.client = GoannaClient.new()
	main.add_child(main.client)
	check(not main.client.procedural_grass(), "Grass must default off without the environment override")
	var near := terrain(false)
	var lod := terrain(true)
	main.client.add_child(near)
	main.client.add_child(lod)
	var original = near.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	root.msaa_3d = Viewport.MSAA_2X
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	for cycle in 3:
		main.set_procedural_grass(true)
		main.set_procedural_grass(true)
		check(near.mesh.get_surface_count()==2, "Near terrain must have exactly one grass surface")
		check(lod.mesh.get_surface_count()==2, "LOD terrain must have exactly one grass surface")
		check(root.msaa_3d==Viewport.MSAA_4X, "Grass must enable coverage multisampling")
		check(root.screen_space_aa==Viewport.SCREEN_SPACE_AA_FXAA, "Grass must enable edge smoothing")
		main.set_procedural_grass(false)
		check(near.mesh.get_surface_count()==1 and lod.mesh.get_surface_count()==1,
			"Disabling grass must remove its draw surfaces")
		check(near.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]==original,
			"Toggling grass must preserve the terrain vertices")
		check(root.msaa_3d==Viewport.MSAA_2X and root.screen_space_aa==Viewport.SCREEN_SPACE_AA_DISABLED,
			"Disabling grass must restore the preceding AA settings")
	root.msaa_3d = Viewport.MSAA_8X
	main.set_procedural_grass(true)
	check(root.msaa_3d==Viewport.MSAA_8X, "Enabling grass must preserve stronger existing AA")
	main.set_procedural_grass(false)
	root.msaa_3d = Viewport.MSAA_2X
	main.set_procedural_grass(true)
	main.free()
	check(root.msaa_3d==Viewport.MSAA_2X and root.screen_space_aa==Viewport.SCREEN_SPACE_AA_DISABLED,
		"Leaving the game must release its AA before the next scene loads")
	print("Procedural grass toggle: %d failures" % failures)
	quit(1 if failures else 0)
