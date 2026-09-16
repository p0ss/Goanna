#!/usr/bin/env python3
"""Compare native displacement fields AND strikes with the Kythen Lua bake."""
import argparse
import json
import subprocess
from pathlib import Path

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('kythen', type=Path)
ap.add_argument('--binary', default='build/goanna_radial_form_test')
ap.add_argument('--lua-file', type=Path)
a = ap.parse_args()
cases = [json.loads(line) for line in subprocess.check_output(
    [a.binary, '--dump-impacts'], text=True).splitlines()]
# Native order is faces/edges/corners; Lua uses keys, not positional indices.
keys = ['xn','xp','yn','yp','zn','zp','xnyn','xnyp','xpyn','xpyp',
        'xnzn','xnzp','xpzn','xpzp','ynzn','ynzp','ypzn','ypzp',
        'nnn','nnp','npn','npp','pnn','pnp','ppn','ppp']
source = 'local F=dofile(' + json.dumps(str(a.lua_file or
    a.kythen/'mods/kythen/core/radial_form.lua')) + ')\n'
source += '''local function dump(f)
local g=F.grid(f,16)
for z=0,15 do for y=0,15 do for x=0,15 do
io.write(g[z][y][x] and "1" or "0") end end end
io.write("\\n")
end
'''
for case in cases:
    controls = ','.join('%s={x=%.9g,y=%.9g,z=%.9g}' % (key, *d)
                        for key, d in zip(keys, case['displacement']))
    source += 'dump(F.normalise({displacement={' + controls + '}}))\n'
    hit = ','.join('%.9g' % x for x in case['hit'])
    source += ('do local f=F.normalise({}); for i=1,%d do '
               'f=F.strike(f,%s,0.08) end; dump(f) end\n') % (case['step']+1, hit)
result = subprocess.check_output(['luajit', '-'], input=source, text=True).splitlines()
assert len(result) == 2*len(cases), (len(result), len(cases))
for i, case in enumerate(cases):
    for j, mode in enumerate(['stored field', 'strike operator']):
        assert result[2*i+j] == case['grid'], f'case {i}: {mode} differs from Kythen'
print(f'{len(cases)} impact states: all 4096 subcubes agree for fields and strikes')
