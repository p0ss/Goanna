#!/usr/bin/env python3
"""Fixed live views, shader A/B, and GPU samples for the opt-in grass layer."""
import argparse
import json
from pathlib import Path
import socket
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out',type=Path,default=Path('build/grass-review/final'))
parser.add_argument('--port',type=int,default=30867)
parser.add_argument('--steps',type=int,default=64)
parser.add_argument('--reference',action='store_true',help='Use the original distance marcher')
args=parser.parse_args()
out=args.out.resolve()
out.mkdir(parents=True,exist_ok=True)

def call(cmd,**params):
    with socket.create_connection(('127.0.0.1',args.port),timeout=5) as s:
        s.settimeout(90)
        s.sendall((json.dumps(dict(id=1,cmd=cmd,args=params))+'\n').encode())
        reply=json.loads(s.makefile().readline())
    if not reply.get('ok'): raise RuntimeError(reply)
    return reply['result']

def run(src): return call('run',src=src)['value']

def configure(enabled):
    return run('''var total=0
for n in client.get_children():
	if n is MeshInstance3D and n.mesh:
		for s in n.mesh.get_surface_count():
			var m=n.mesh.surface_get_material(s)
			if m and m.has_meta("goanna_grass_volume"):
				m.set_shader_parameter("enabled",%s)
				m.set_shader_parameter("clock_override",4.0)
				m.set_shader_parameter("march_steps",%d)
				m.set_shader_parameter("debug_bounds",false)
				m.set_shader_parameter("analytic_blades",%s)
				total+=1
return total''' % ('true' if enabled else 'false',args.steps,'false' if args.reference else 'true'))

run('client.set_show_body(false)\nmain.get_window().content_scale_size=Vector2i(1280,720)\nmain.get_window().content_scale_mode=Window.CONTENT_SCALE_MODE_VIEWPORT\nmain.get_window().content_scale_aspect=Window.CONTENT_SCALE_ASPECT_KEEP\nDisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)\nEngine.max_fps=0\nRenderingServer.viewport_set_measure_render_time(main.get_viewport().get_viewport_rid(),true)\nreturn true')
views={
    'steps':(6,82,0,-8,0),
    'field':(17,83,8,-6,140),
    'dry':(57,84,12,-10,0),
    'aerial':(6,116,26,-32,0),
    'inside':(6,80.1,0,0,0),
}
results={}
try:
    for name,(x,y,z,pitch,yaw) in views.items():
        call('pose',x=x,y=y,z=z,pitch=pitch,yaw=yaw)
        time.sleep(3)
        results[name]={}
        for enabled in (False,True):
            label='on' if enabled else 'off'
            volumes=configure(enabled)
            call('wait',frames=45)
            sample=run('''var samples=[]
var last=Time.get_ticks_usec()
for i in 120:
	await main.get_tree().process_frame
	var now=Time.get_ticks_usec()
	samples.append([float(now-last)/1000.0,RenderingServer.viewport_get_measured_render_time_gpu(main.get_viewport().get_viewport_rid())])
	last=now
return samples''')
            shot=call('shot',path=str(out/f'{name}-{label}.png'),settle=False,warm=8)
            stats=call('inspect',target='render')
            gpu=sorted(row[1] for row in sample)
            frame=sorted(row[0] for row in sample)
            results[name][label]=dict(gpu_median_ms=gpu[len(gpu)//2],
                gpu_p95_ms=gpu[int(len(gpu)*.95)],frame_median_ms=frame[len(frame)//2],
                samples=sample,volumes=volumes,shot=shot,render=stats)
            (out/'results.json').write_text(json.dumps(results,indent=2))
            print(f'{name} {label}: GPU {gpu[len(gpu)//2]:.2f} ms',flush=True)
finally:
    configure(True)
    call('pose',x=6,y=82,z=0,pitch=-8,yaw=0)
