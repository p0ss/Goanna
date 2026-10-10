#!/usr/bin/env python3
"""Live grass regression: first-person footprint, body toggle, weather and waves."""
import argparse
import json
from pathlib import Path
import socket

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=30867)
parser.add_argument('--no-shots', action='store_true')
parser.add_argument('--out', type=Path, default=Path('build/grass-review/features'))
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)


def call(cmd, **params):
    if cmd == 'shot' and args.no_shots:
        return {}
    with socket.create_connection(('127.0.0.1', args.port), timeout=5) as sock:
        sock.settimeout(90)
        sock.sendall((json.dumps(dict(id=1, cmd=cmd, args=params))+'\n').encode())
        reply = json.loads(sock.makefile().readline())
    if not reply.get('ok'):
        raise RuntimeError(reply)
    return reply['result']


def run(src):
    return call('run', src=src)['value']


STATE = '''var m=client.get_meta("goanna_grass_material")
var actors=m.get_shader_parameter("interaction_centres")
var foot=client.step_player(0.0,{},main.pitch,main.yaw).pos
return {"count":m.get_shader_parameter("interaction_count"),
    "foot":[foot.x,foot.y,foot.z],
    "player":[actors[0].x,actors[0].y,actors[0].z,actors[0].w],
    "wind":m.get_shader_parameter("wind_strength")}'''
results = {}
try:
    run('main.set_procedural_grass(true)\nclient.set_show_body(false)\nreturn true')
    call('pose', x=6, y=81.125, z=0, pitch=-55, yaw=0)
    call('wait', frames=30)
    results['first_person'] = run(STATE)
    state = results['first_person']
    assert 1 <= state['count'] <= 8, state
    assert max(abs(a-b) for a, b in zip(state['foot'], state['player'])) < 0.01, state
    assert state['player'][3] >= 0.45, state
    for label, enabled in [('bent', True), ('unbent', False)]:
        run('client.get_meta("goanna_grass_material").set_shader_parameter("interaction_enabled",%s)\nreturn true' % str(enabled).lower())
        call('shot', path=str(out/f'first-person-{label}.png'), settle=False, warm=8)
    run('client.get_meta("goanna_grass_material").set_shader_parameter("interaction_enabled",true)\nclient.set_show_body(true)\nreturn true')
    call('wait', frames=20)
    results['body_visible'] = run(STATE)
    assert results['body_visible']['count'] == state['count'], results
    assert results['body_visible']['player'] == state['player'], results
    run('client.set_show_body(false)\nreturn true')
    call('pose', x=6.6, y=81.125, z=0, pitch=-55, yaw=0)
    call('wait', frames=20)
    results['moved'] = run(STATE)
    assert abs(results['moved']['player'][0]-state['player'][0]-0.6) < 0.01, results
    call('pose', x=6, y=82, z=0, pitch=-8, yaw=0)
    for kind in ('clear', 'rain', 'clear'):
        call('weather', kind=kind, fake=True)
        call('wait', ms=12000 if kind == 'rain' or 'rain' in results else 1000)
        results['drying' if kind == 'clear' and 'rain' in results else kind] = run(STATE)
    assert results['rain']['wind'] > results['clear']['wind'] + 0.1, results
    assert results['drying']['wind'] < results['rain']['wind'] - 0.03, results
    for clock in (4.0, 5.5):
        run('client.get_meta("goanna_grass_material").set_shader_parameter("clock_override",%s)\nreturn true' % clock)
        call('shot', path=str(out/f'wave-{clock}.png'), settle=False, warm=8)
    (out/'results.json').write_text(json.dumps(results, indent=2))
    print('Grass features: first person, body visibility, movement and weather PASS', flush=True)
finally:
    call('weather', kind='clear', fake=True)
    run('var m=client.get_meta("goanna_grass_material")\nm.set_shader_parameter("interaction_enabled",true)\nm.set_shader_parameter("clock_override",-1.0)\nclient.set_show_body(false)\nreturn true')
