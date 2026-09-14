#!/usr/bin/env python3
"""Repeatable close-up GPU timings, including full-strength actor bending."""
import argparse
import json
from pathlib import Path
import socket

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('label')
p.add_argument('--port', type=int, default=30867)
p.add_argument('--views', nargs='+', default=['inside', 'roots', 'above', 'distant'])
p.add_argument('--modes', nargs='+', default=['off', 'natural', 'bent'])
args = p.parse_args()
out = (Path('build/grass-review/close') / args.label).resolve()
out.mkdir(parents=True, exist_ok=True)

def call(cmd, **params):
    with socket.create_connection(('127.0.0.1', args.port), timeout=5) as s:
        s.settimeout(180)
        s.sendall((json.dumps(dict(id=1, cmd=cmd, args=params))+'\n').encode())
        reply = json.loads(s.makefile().readline())
    if not reply.get('ok'):
        raise RuntimeError(reply)
    return reply['result']

call('run', src='client.set_show_body(false)\nmain.set_procedural_grass(true)\nreturn true')
call('pose', x=6, y=80.1, z=0, pitch=0, yaw=0)
call('wait', frames=30)
src = '''var m=client.get_meta("goanna_grass_material")
var was_main=main.is_processing()
var was_client=client.is_processing()
main.set_process(false)
client.set_process(false)
var centres=m.get_shader_parameter("interaction_centres")
var actor_count=m.get_shader_parameter("interaction_count")
main.get_window().content_scale_size=Vector2i(1280,720)
main.get_window().content_scale_mode=Window.CONTENT_SCALE_MODE_VIEWPORT
main.get_window().content_scale_aspect=Window.CONTENT_SCALE_ASPECT_KEEP
DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
Engine.max_fps=0
var viewport=main.get_viewport().get_viewport_rid()
RenderingServer.viewport_set_measure_render_time(viewport,true)
cam.fov=70.0
m.set_shader_parameter("clock_override",4.0)
var results={}
for view in VIEWS:
	cam.position=Vector3(6,80.1,0)
	cam.rotation_degrees=Vector3(0,0,0)
	if view=="roots": cam.position.y=79.65
	if view=="above":
		cam.position.y=82
		cam.rotation_degrees.x=-35
	if view=="distant":
		cam.position=Vector3(6,116,26)
		cam.rotation_degrees.x=-32
	for mode in MODES:
		m.set_shader_parameter("enabled",mode!="off")
		m.set_shader_parameter("interaction_enabled",mode!="unbent")
		var actors=PackedVector4Array([Vector4(6,79.5,0,0.7)])
		actors.resize(8)
		m.set_shader_parameter("interaction_centres",actors if mode=="bent" else centres)
		m.set_shader_parameter("interaction_count",1 if mode=="bent" else actor_count)
		for i in 45: await RenderingServer.frame_post_draw
		var samples=[]
		for i in 60:
			await RenderingServer.frame_post_draw
			samples.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
		samples.sort()
		var key=view+"-"+mode
		results[key]={"gpu_ms":samples[30],"gpu_p95_ms":samples[57],"samples":samples}
		main.get_viewport().get_texture().get_image().save_png(OUT.path_join(key+".png"))
m.set_shader_parameter("enabled",true)
m.set_shader_parameter("interaction_enabled",true)
m.set_shader_parameter("clock_override",-1.0)
m.set_shader_parameter("interaction_centres",centres)
m.set_shader_parameter("interaction_count",actor_count)
cam.position=Vector3(6,82,0)
cam.rotation_degrees=Vector3(-8,0,0)
main.pitch=-8
main.yaw=0
main.set_process(was_main)
client.set_process(was_client)
return results
'''.replace('OUT', json.dumps(str(out))).replace('VIEWS', json.dumps(args.views)).replace('MODES', json.dumps(args.modes))
result = call('run', src=src)['value']
(out/'results.json').write_text(json.dumps(result, indent=2))
for name, row in result.items():
    print(f'{name}: {row["gpu_ms"]:.2f} ms', flush=True)
