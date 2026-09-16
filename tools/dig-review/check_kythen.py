#!/usr/bin/env python3
"""Compare actual Goanna impact vectors against Kythen's existing Lua bake.
This validates the shared primitive, not the older Lua strike operator.
"""
import argparse,json,subprocess
from pathlib import Path
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('kythen',type=Path)
ap.add_argument('--binary',default='build/goanna_radial_form_test')
a=ap.parse_args()
cases=[json.loads(line) for line in subprocess.check_output([a.binary,'--dump-impacts'],text=True).splitlines()]
source='local F=dofile('+json.dumps(str(a.kythen/'mods/kythen/core/radial_form.lua'))+')\n'
for case in cases:
    cuts=','.join('{x=%.9g,y=%.9g,z=%.9g,r=%.9g}'%tuple(c) for c in case['carve'])
    source+='do local f=F.normalise({carve={'+cuts+'}}); local g=F.grid(f,16); for z=0,15 do for y=0,15 do for x=0,15 do io.write(g[z][y][x] and "1" or "0") end end end; io.write("\\n") end\n'
result=subprocess.check_output(['luajit','-'],input=source,text=True).splitlines()
assert len(result)==len(cases),(len(result),len(cases))
for i,(actual,expected) in enumerate(zip(result,cases)):
    assert actual==expected['grid'],f'case {i} differs from Kythen occupancy'
print(f'{len(cases)} impact states: all 4096 subcubes agree with Kythen')
