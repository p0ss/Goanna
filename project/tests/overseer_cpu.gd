# SPDX-License-Identifier: LGPL-2.1-or-later
## Synthetic bounded-layer CPU benchmark; no renderer, server or native mesher.
## godot --headless --path project --script res://tests/overseer_cpu.gd
extends SceneTree
const Unit = preload("res://tests/overseer.gd")
const Overseer = preload("res://game/overseer.gd")
func _initialize():
	call_deferred("run")
func measured(label: String, action: Callable):
	var samples := []
	for n in 5:
		var started := Time.get_ticks_usec()
		action.call()
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
	print("PROFILE ",label," ms ",samples)
func run():
	var main = Unit.TestMain.new();root.add_child(main)
	var client = Unit.TestClient.new();main.add_child(client)
	var view = Overseer.new();view.main=main;view.client=client;main.add_child(view)
	var start = Time.get_ticks_usec();view._open();print("PROFILE open ms ",(Time.get_ticks_usec()-start)/1000.0)
	var bounds = {"min":{"x":-64,"y":-32,"z":-64},"max":{"x":64,"y":32,"z":64}}
	view._receive({"v":1,"t":"hello","claim":bounds,"y":0,"body":{"x":0,"y":0,"z":0},"tools":[{"id":"inspect","title":"Inspect"}]})
	var r = {"x0":-31,"x1":31,"z0":-31,"z1":31}
	view.requested=r
	var cells=[];var dates=[];var states=[];var solid=[]
	cells.resize(3969);cells.fill(1);dates.resize(3969);dates.fill(1);states.resize(3969);states.fill(2);solid.resize(3969);solid.fill(2)
	var layer = {"v":1,"t":"layer","seq":view.sequence,"rev":1,"y":0,"rect":r,"cells":cells,"floors":cells,"dates":dates,"states":states,"palette":[{"name":"mcl_core:stone"}],"orders":[],"below":[],"overlays":{}}
	for d in 8: layer.below.append({"cells":solid if d==7 else cells,"states":states})
	view.snapshot=layer
	measured("valid63x63depth8", func(): Overseer.valid_layer(layer,view.sequence,0,r,bounds))
	measured("queue63x63depth8", view._queue_geometry)
	measured("concealment63x63depth8", view._draw_concealment)
	measured("draw63x63depth8", view._draw_layer)
	layer.overlays.areas=[]
	for i in 32: layer.overlays.areas.append({"rect":r,"reachability":"partial"})
	measured("overlay32overlaps63x63",view._draw_overlays)
	measured("inspect32overlaps63x63",func(): Overseer.overlay_notes(layer,{"x":0,"y":0,"z":0}))
	view._close();main.queue_free()
	await process_frame
	quit()
