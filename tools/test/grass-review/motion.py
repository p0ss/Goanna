#!/usr/bin/env python3
"""Capture deterministic grass sway and camera travel as actual frame sequences."""
import argparse
import json
from pathlib import Path
import socket
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('label')
parser.add_argument('--port',type=int,default=30867)
parser.add_argument('--frames',type=int,default=72)
args=parser.parse_args()
out=(Path('build/grass-review/motion')/args.label).resolve()
out.mkdir(parents=True,exist_ok=True)

def call(cmd,**params):
    with socket.create_connection(('127.0.0.1',args.port),timeout=5) as s:
        s.settimeout(150)
        s.sendall((json.dumps(dict(id=1,cmd=cmd,args=params))+'\n').encode())
        reply=json.loads(s.makefile().readline())
    if not reply.get('ok'): raise RuntimeError(reply)
    return reply['result']

call('pose',x=6,y=82,z=0,pitch=-8,yaw=0)
for move in (False,True):
    name='travel' if move else 'sway'
    folder=out/name
    folder.mkdir(exist_ok=True)
    src='''var materials=[]
for n in client.get_children():
	if n is MeshInstance3D and n.mesh:
		for s in n.mesh.get_surface_count():
			var m=n.mesh.surface_get_material(s)
			if m and m.has_meta("goanna_grass_volume") and not materials.has(m): materials.append(m)
var was_processing=main.is_processing()
var time_scale=Engine.time_scale
var origin=Vector3(6,82,0)
main.set_process(false)
Engine.time_scale=0.0
cam.position=origin
cam.rotation_degrees=Vector3(-8,0,0)
cam.fov=70.0
client.set_show_body(false)
for m in materials:
	m.set_shader_parameter("clock_override",4.0)
	m.set_shader_parameter("enabled",true)
for i in 24: await RenderingServer.frame_post_draw
for i in %d:
	for m in materials: m.set_shader_parameter("clock_override",4.0+float(i)/60.0)
	cam.position=origin+Vector3(%s,0,0)
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png(%s.path_join("%%04d.png" %% i))
cam.position=origin
Engine.time_scale=time_scale
main.set_process(was_processing)
for m in materials: m.set_shader_parameter("clock_override",-1.0)
return {"frames":%d,"camera":cam.position,"rotation":cam.rotation_degrees,"fov":cam.fov,"msaa":main.get_viewport().msaa_3d,"taa":main.get_viewport().use_taa,"size":main.get_viewport().get_texture().get_size()}
''' % (args.frames,'float(i)*0.015' if move else '0.0',json.dumps(str(folder)),args.frames)
    result=call('run',src=src)
    (out/f'{name}.json').write_text(json.dumps(result,indent=2))
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-framerate','60',
        '-i',str(folder/'%04d.png'),'-c:v','libx264','-crf','15','-pix_fmt','yuv420p',str(out/f'{name}.mp4')],check=True)
    print(f'{name}: {out / (name+".mp4")}',flush=True)
