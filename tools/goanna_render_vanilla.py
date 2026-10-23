# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Vanilla reference captures through the render service's server and launcher."""

import argparse
import json
import math
import os
import pathlib
import re
import signal
import time

import goanna_render as render


def camera_angles(pose):
    if 'look_at' not in pose:
        return float(pose.get('yaw', 0)), float(pose.get('pitch', 0))
    dx, dy, dz = [b - a for a, b in zip(pose['pos'], pose['look_at'])]
    if dx == dy == dz == 0:
        raise render.RenderError('a camera cannot look at its own position')
    return math.degrees(math.atan2(-dx, dz)), math.degrees(math.atan2(dy, math.hypot(dx, dz)))


class ReferenceServer(render.Server):
    def __init__(self, *args, poses, tod, creative=True, **kwargs):
        super().__init__(*args, **kwargs)
        self.poses = poses
        self.tod = tod
        if not isinstance(creative, bool):
            raise render.RenderError("creative mode must be a boolean")
        self.creative = creative

    def write_conf(self):
        path = super().write_conf()
        lines = path.read_text().splitlines(keepends=True)
        keys = [i for i, line in enumerate(lines)
                if re.match(r"^[ \t]*creative_mode[ \t]*=", line)]
        if len(keys) != 1:
            raise render.RenderError("reference config needs exactly one creative_mode setting")
        index = keys[0]
        match = re.fullmatch(r"([ \t]*creative_mode[ \t]*=[ \t]*)(true|false)([ \t]*)(\r?\n?)",
                             lines[index])
        if not match:
            raise render.RenderError("reference creative_mode setting must be true or false")
        value = "true" if self.creative else "false"
        replacement = match[1] + value + match[3] + match[4]
        if lines[index] != replacement:
            lines[index] = replacement
            path.write_text("".join(lines))
        return path

    def build_world(self):
        world = super().build_world()
        mod = world / 'worldmods' / 'goanna_render_reference'
        mod.mkdir(exist_ok=True)
        (mod / 'mod.conf').write_text('name = goanna_render_reference\n')
        rows = []
        for index, pose in enumerate(self.poses):
            yaw, pitch = camera_angles(pose)
            x, y, z = pose['pos']
            rows.append('["reference_%d"] = {x=%.9g,y=%.9g,z=%.9g,yaw=%.9g,pitch=%.9g,fov=%.9g}'
                        % (index, x, y, z, math.radians(yaw), math.radians(pitch), pose.get('fov', 70)))
        lua = '''local poses = {ROWS}
core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local pose = poses[name]
    if not pose then return end
    core.after(2, function()
        local p = core.get_player_by_name(name)
        if not p then return end
        p:set_physics_override({speed=0, jump=0, gravity=0})
        local eye = p:get_properties().eye_height or 1.625
        p:set_pos({x=pose.x, y=pose.y-eye, z=pose.z})
        p:set_look_horizontal(pose.yaw)
        p:set_look_vertical(-pose.pitch)
        p:set_fov(pose.fov, false, 0)
        p:hud_set_flags({hotbar=false, healthbar=false, crosshair=false,
            wielditem=false, breathbar=false, minimap=false, basic_debug=false, chat=false})
        core.set_timeofday(TOD)
        if mcl_weather then mcl_weather.change_weather("clear") end
        core.log("action", "GOANNA_REFERENCE_READY " .. name)
    end)
end)
'''.replace('ROWS', ',\n'.join(rows)).replace('TOD', str(float(self.tod)))
        (mod / 'init.lua').write_text(lua)
        return world


def command(args):
    ap = argparse.ArgumentParser(prog='goanna-render vanilla')
    ap.add_argument('job')
    ap.add_argument('--world-from', required=True)
    ap.add_argument('--game', default='mineclonia')
    ap.add_argument('--server-view-range', type=int, default=40, choices=range(1, 257), metavar='BLOCKS')
    ap.add_argument('--settle-seconds', type=float, default=60)
    ap.add_argument('--no-server-occlusion', action='store_true')
    ap.add_argument('--survival', action='store_true',
                    help='start the reference server with creative mode disabled')
    opt = ap.parse_args(args)
    job = json.loads(pathlib.Path(opt.job).read_text())
    if job.get('frame') != 'world' or not job.get('poses'):
        raise render.RenderError('vanilla reference captures need world-frame poses')
    if job.get('weather', 'clear') != 'clear':
        raise render.RenderError('vanilla reference captures currently support clear weather')
    if any(job.get(key) for key in ('nodes', 'statues', 'lua', 'lua_statues')):
        raise render.RenderError('vanilla reference captures need an unmodified world scene')
    for pose in job['poses']:
        camera_angles(pose)
    width, height = job.get('size', [1280, 720])
    out = pathlib.Path(job['out']).expanduser().resolve() / 'vanilla'
    out.mkdir(parents=True, exist_ok=True)
    fd, opened = render.gh.acquire_gpu_lock()
    server = None
    client = None
    def interrupted(*_args):
        raise KeyboardInterrupt
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        busy = render.foreign_gpu_users({os.getpid()})
        if busy:
            raise render.RenderError('; '.join(busy))
        server = ReferenceServer(opt.game, opt.world_from, render.DEFAULT_STAGE, '', out,
                                 view_range=opt.server_view_range, far=False,
                                 occlusion=not opt.no_server_occlusion,
                                 poses=job['poses'], tod=job.get('time', 0.5), creative=not opt.survival)
        server.start()
        frames = []
        for index, pose in enumerate(job['poses']):
            name = 'reference_%d' % index
            settings = {'viewing_range': opt.server_view_range * 16,
                        'enable_sound': 'false', 'enable_shaders': 'true',
                        'fps_max': 60, 'pause_on_lost_focus': 'false'}
            client = render.gh.start_vanilla(port=server.port, name=name, width=width,
                                            height=height, settings=settings)
            deadline = time.monotonic() + 120
            while 'GOANNA_REFERENCE_READY ' + name not in (out / 'server.log').read_text(errors='replace'):
                if time.monotonic() > deadline:
                    raise render.RenderError('vanilla player never reached the reference pose')
                time.sleep(0.5)
            # Vanilla has no control channel or streaming completion query.
            # Record this fixed wait rather than claiming the terrain settled.
            end = time.monotonic() + max(0, opt.settle_seconds)
            while time.monotonic() < end:
                own = {os.getpid()} | set(render.gh.descendants(os.getpid())) | server.pids()
                own |= set(render.gh.descendants(client['supervisor_pid'])) | {client['supervisor_pid']}
                busy = render.foreign_gpu_users(own)
                if busy:
                    raise render.RenderError('; '.join(busy))
                time.sleep(min(2, max(0, end-time.monotonic())))
            path = out / (render.safe_name(pose['name']) + '.png')
            shot = render.gh.screenshot(client['id'], path)
            metadata = {'renderer': 'vanilla Luanti', 'server': server.version,
                        'game': render.game_info(opt.game), 'world_from': opt.world_from,
                        'pose': pose, 'frame': 'world', 'size': [width, height],
                        'time': job.get('time', 0.5), 'weather': 'clear',
                        'settings': settings, 'client_config': client.get('config'),
                        'server_occlusion': not opt.no_server_occlusion,
                        'server_creative_mode': server.creative,
                        'client_log': client.get('client_log'),
                        'settled': {'quiet': None, 'fixed_wait_s': opt.settle_seconds},
                        'capture': shot}
            render.write_json(path.with_suffix('.settings.json'), metadata)
            frames.append(str(path))
            print(json.dumps({'captured': str(path)}), flush=True)
            render.gh.stop(client['id'])
            client = None
        render.write_json(out / 'result.json', {'ok': True, 'frames': frames})
        return 0
    finally:
        try:
            if client:
                render.gh.stop(client['id'])
        finally:
            try:
                if server:
                    server.stop()
            finally:
                signal.signal(signal.SIGTERM, previous)
                if opened:
                    os.close(fd)
