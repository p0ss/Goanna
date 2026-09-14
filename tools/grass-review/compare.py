#!/usr/bin/env python3
"""Compare reference and optimized grass at identical camera/wind/actor poses."""
import argparse
import json
from pathlib import Path
import socket

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('reference', type=Path)
p.add_argument('--out', type=Path, default=Path('build/grass-review/close/validation'))
args = p.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)

def call(cmd, **params):
    with socket.create_connection(('127.0.0.1', 30867), timeout=5) as s:
        s.settimeout(180)
        s.sendall((json.dumps(dict(id=1, cmd=cmd, args=params))+'\n').encode())
        reply = json.loads(s.makefile().readline())
    if not reply.get('ok'):
        raise RuntimeError(reply)
    return reply['result']

call('run', src='client.set_show_body(false)\nreturn true')
call('pose', x=6, y=80.1, z=0, pitch=0, yaw=0)
call('wait', frames=30)
src = '''var m=client.get_meta("goanna_grass_material")
var optimized=m.shader.code
var reference=REFERENCE
var centres=m.get_shader_parameter("interaction_centres")
var actor_count=m.get_shader_parameter("interaction_count")
var was_main=main.is_processing()
var was_client=client.is_processing()
main.set_process(false)
client.set_process(false)
cam.fov=70.0
var viewport=main.get_viewport().get_viewport_rid()
RenderingServer.viewport_set_measure_render_time(viewport,true)
var results={}
for pose in 6:
	cam.position=Vector3(6+float(pose)*0.027,80.1,0)
	cam.rotation_degrees=Vector3(0,float(pose)*12.0,0)
	if pose>=3: cam.position.y=79.65
	var actors=PackedVector4Array([Vector4(6.1+float(pose)*0.06,79.5,0,0.7)])
	actors.resize(8)
	m.set_shader_parameter("interaction_centres",actors)
	m.set_shader_parameter("interaction_count",1)
	m.set_shader_parameter("clock_override",4.0+float(pose)*0.15)
	for bending in [false,true]:
		m.set_shader_parameter("interaction_enabled",bending)
		for variant in ["before","after"]:
			m.shader.code=reference if variant=="before" else optimized
			for i in 20: await RenderingServer.frame_post_draw
			var samples=[]
			for i in 24:
				await RenderingServer.frame_post_draw
				samples.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
			samples.sort()
			var key="%d-%s-%s" % [pose,"bent" if bending else "unbent",variant]
			results[key]={"gpu_ms":samples[12]}
			main.get_viewport().get_texture().get_image().save_png(OUT.path_join(key+".png"))
m.shader.code=optimized
m.set_shader_parameter("interaction_enabled",true)
m.set_shader_parameter("clock_override",-1.0)
m.set_shader_parameter("interaction_centres",centres)
m.set_shader_parameter("interaction_count",actor_count)
main.set_process(was_main)
client.set_process(was_client)
return results
'''.replace('REFERENCE', json.dumps(args.reference.read_text())).replace('OUT', json.dumps(str(out)))
try:
    result = call('run', src=src)['value']
    (out/'results.json').write_text(json.dumps(result, indent=2))
    for name, row in result.items():
        print(f'{name}: {row["gpu_ms"]:.2f} ms', flush=True)
finally:
    call('reload_shader', path='res://shaders/grass_volume.gdshader')
    call('run', src='main.set_process(true)\nclient.set_process(true)\nreturn true')
    call('pose', x=6, y=82, z=0, pitch=-8, yaw=0)
