# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Capture Minecraft and Goanna against one local Minecraft server."""

import argparse
import fcntl
import hashlib
import html
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

import goanna_render as render
from minecraft.profile import prepare


def camera(pose):
    """Minecraft eye coordinates to Goanna through BridgeTest's centre offset."""
    x, y, z = map(float, pose['pos'])
    yaw, pitch = float(pose.get('yaw', 0)), float(pose.get('pitch', 0))
    if not all(math.isfinite(v) for v in (x, y, z, yaw, pitch)):
        raise render.RenderError('camera coordinates must be finite')
    if 'look_at' in pose:
        dx, dy, dz = [float(b) - float(a) for a, b in zip(pose['pos'], pose['look_at'])]
        if dx == dy == dz == 0:
            raise render.RenderError('camera target equals its position')
        yaw = math.degrees(math.atan2(-dx, dz))
        pitch = math.degrees(math.atan2(-dy, math.hypot(dx, dz)))
    fov = int(pose.get('fov', 70))
    if not all(math.isfinite(v) for v in (yaw, pitch)):
        raise render.RenderError('camera target must be finite')
    if not 30 <= fov <= 110:
        raise render.RenderError('Minecraft camera FOV must be between 30 and 110')
    return ({'x': x, 'y': y, 'z': z, 'yaw': yaw, 'pitch': pitch, 'fov': fov},
            {'x': -x - 0.5, 'y': y - 0.5, 'z': -z + 0.5,
             'yaw': -yaw, 'pitch': -pitch, 'fly': True})


class LocalProcess:
    def __init__(self, argv, cwd, logfile, env=None):
        self.logfile = Path(logfile)
        self.log = self.logfile.open('w')
        self.proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                     stdout=self.log, stderr=subprocess.STDOUT, text=True)

    def send(self, command):
        self.proc.stdin.write(command + '\n')
        self.proc.stdin.flush()

    def wait_for(self, text, timeout=180):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if text in self.logfile.read_text(errors='replace'):
                return
            if self.proc.poll() is not None:
                raise render.RenderError('process exited; see ' + str(self.logfile))
            time.sleep(0.5)
        raise render.RenderError('timed out waiting for %r; see %s' % (text, self.logfile))

    def stop(self, command=None):
        if self.proc.poll() is None:
            if command:
                try:
                    self.send(command)
                except (BrokenPipeError, OSError):
                    pass
            else:
                self.proc.terminate()
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        self.proc.stdin.close()
        self.log.close()


class MinecraftControl:
    def __init__(self, root):
        self.directory = root / 'client/.goanna-control'
        self.counter = time.time_ns() // 1000

    def send(self, cmd, args=None, timeout=30):
        self.counter += 1
        request = dict(args or {}, id=self.counter, cmd=cmd)
        temporary = self.directory / 'request.tmp'
        temporary.write_text(json.dumps(request))
        temporary.replace(self.directory / 'request.json')
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            path = self.directory / 'response.json'
            if path.exists():
                reply = json.loads(path.read_text())
                if reply.get('id') == self.counter:
                    if not reply.get('ok'):
                        raise render.RenderError(str(reply.get('error')))
                    return reply
            time.sleep(0.1)
        raise render.RenderError('Minecraft control timed out: ' + cmd)


def validate_frame_state(renderer, state):
    if renderer == 'minecraft':
        if not state.get('connected'):
            raise render.RenderError('Minecraft disconnected before capture')
    elif state.get('state') in ('none', 'disconnected', 'denied') or not state.get('blocks_meshed'):
        raise render.RenderError('Goanna has no connected terrain: ' + str(state.get('message', state)))


def validate_clock_state(renderer, state, time_ticks):
    if renderer == 'minecraft':
        if state.get('world_time') != time_ticks:
            raise render.RenderError('Minecraft clock differs from the job; rebuild the capture helper')
    elif renderer == 'goanna':
        expected = ((time_ticks + 6000) % 24000) / 24000
        observed = state.get('sky', {}).get('time_of_day', -1)
        error = abs((observed - expected + 0.5) % 1 - 0.5)
        if observed < 0 or error > 1 / 24000:
            raise render.RenderError('Goanna clock %.7f differs from job %.7f; '
                                     'rebuild the comparison bridge' % (observed, expected))


def validate_stage_state(nodes):
    for key, expected in {'red': 'red_concrete', 'gold': 'gold_block'}.items():
        if nodes.get(key, '').removeprefix('minecraft:') != expected:
            raise render.RenderError('Goanna calibration landmark %s is %r, expected %s' %
                                     (key, nodes.get(key), expected))


def validate_shader_state(reports):
    chain, geometry = reports.get('chain', {}), reports.get('gbuffers', {})
    active = bool(geometry.get('terrain', {}).get('translated'))
    if chain:
        passes = chain.get('passes', [])
        if chain.get('load_error') or chain.get('dead') or (passes and not chain.get('gpu_ready')):
            raise render.RenderError('Goanna shader chain failed: ' + str(chain))
        if any(p.get('error') or not p.get('compiled') for p in passes):
            raise render.RenderError('Goanna shader passes did not compile: ' + str(passes))
        active = active or bool(passes)
    if not active:
        raise render.RenderError('Goanna did not activate the requested shader pack')


def fixture(server):
    """A small calibration stage in the dedicated comparison world only."""
    server.send('forceload add -16 -16 32 32')
    # Force-loading is asynchronous. A console command succeeding is the
    # evidence that both corners are available, even without a player.
    end = time.monotonic() + 90
    while time.monotonic() < end:
        server.send('execute if loaded -8 100 -8 if loaded 24 100 28 run say GOANNA_STAGE_READY')
        time.sleep(0.5)
        if 'GOANNA_STAGE_READY' in server.logfile.read_text(errors='replace'):
            break
    else:
        raise render.RenderError('calibration chunks did not load')
    commands = [
        'gamerule minecraft:advance_time false',
        'time set noon', 'weather clear', 'tick freeze',
        'fill -8 99 -8 24 115 28 air',
        # The bridge's colormap is fixed to plains. Keep the calibration
        # biome explicit so foliage and water compare the same inputs.
        'fillbiome -8 96 -8 24 112 28 minecraft:plains',
        'fill -8 99 -8 24 99 28 smooth_stone',
        'fill 0 100 0 0 104 0 red_concrete',
        'fill 16 100 0 16 104 0 blue_concrete',
        'fill 8 100 8 8 102 8 gold_block',
        'fill 2 100 4 5 102 4 oak_planks',
        'fill 11 100 4 14 102 4 glass',
        'fill 2 99 10 5 99 13 water',
        'fill 11 100 10 14 101 13 oak_leaves[persistent=true]',
        'setblock 7 100 4 oak_log[axis=x]',
        'setblock 8 100 4 oak_stairs[facing=north,half=bottom]',
        'setblock 9 100 4 stone_slab[type=top]',
        'setblock 8 103 8 sea_lantern',
        'setworldspawn 8 100 20',
    ]
    for command in commands:
        server.send(command)
    return commands


def file_hash(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def report(out, frames):
    cards = []
    names = dict.fromkeys(frame['pose']['name'] for frame in frames)
    ordered = [frame for name in names for frame in frames if frame['pose']['name'] == name]
    columns = len({frame['renderer'] for frame in frames})
    for frame in ordered:
        path = Path(frame['path']).relative_to(out)
        label = html.escape(frame['renderer'] + ': ' + frame['pose']['name'])
        link = html.escape(str(path), quote=True)
        cards.append('<figure><figcaption>' + label + '</figcaption><a href="' +
                     link + '"><img src="' + link + '"></a></figure>')
    (out / 'index.html').write_text('''<!doctype html><meta charset="utf-8">
<title>Minecraft and Luanti comparison</title>
<style>body{background:#181818;color:#eee;font:16px sans-serif;margin:24px}
main{display:grid;grid-template-columns:repeat(COLUMNS,minmax(0,1fr));gap:16px}
figure{margin:0}img{width:100%}figcaption{padding:8px 0}</style>
<h1>Minecraft and Luanti comparison</h1>
<p>Shared Minecraft world. See result.json for settings and known differences.</p>
<main>'''.replace('COLUMNS', str(columns)) + ''.join(cards) + '</main>')


def command(args):
    if '--help' in args or '-h' in args:
        return capture(args)
    # Even software runs must serialise writes to the isolated client profile
    # and world. The GPU lock alone does not protect those files.
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--root', type=Path, default=Path('build/minecraft'))
    options, _ = parser.parse_known_args(args)
    root = options.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'comparison.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise render.RenderError('another comparison is using ' + str(root))
        try:
            return capture(args)
        except (ValueError, KeyError, FileNotFoundError) as error:
            raise render.RenderError(str(error)) from error


def capture(args):
    ap = argparse.ArgumentParser(prog='goanna-render minecraft')
    ap.add_argument('job')
    ap.add_argument('--root', type=Path, default=Path('build/minecraft'))
    ap.add_argument('--build', type=Path, help='Goanna checkout to capture')
    ap.add_argument('--bridge', type=Path)
    ap.add_argument('--out', type=Path, help='override the job output directory')
    ap.add_argument('--only', choices=('minecraft', 'goanna', 'vanilla'))
    ap.add_argument('--native', action='store_true', help='include the native Luanti reference')
    ap.add_argument('--software', action='store_true')
    opt = ap.parse_args(args)
    root = opt.root.resolve()
    goanna_build = opt.build.resolve() if opt.build else render.main_checkout()
    installation = json.loads((root / 'installation.json').read_text())
    job = json.loads(Path(opt.job).read_text())
    time_ticks = int(job.get('time_ticks', 6000))
    if not 0 <= time_ticks < 24000:
        raise render.RenderError('Minecraft time_ticks must be between 0 and 23999')
    poses = job['poses']
    if not poses:
        raise render.RenderError('comparison needs at least one pose')
    for pose in poses:
        camera(pose)
    if (opt.native or opt.only == 'vanilla') and len({camera(p)[0]['fov'] for p in poses}) != 1:
        raise render.RenderError('native reference poses need the same FOV')
    if len({render.safe_name(p['name']) for p in poses}) != len(poses):
        raise render.RenderError('pose names must produce unique filenames')
    width, height = map(int, job.get('size', [1280, 720]))
    if not 64 <= width <= 8192 or not 64 <= height <= 8192 or not 0 <= float(job.get('settle_seconds', 15)) <= 600:
        raise render.RenderError('invalid capture dimensions or settling time')
    if opt.out:
        job['out'] = str(opt.out)
    out = Path(job['out']).expanduser().resolve()
    if out.exists() and any(out.iterdir()):
        raise render.RenderError('comparison output must be empty: ' + str(out))
    out.mkdir(parents=True, exist_ok=True)
    if (root / 'server/eula.txt').read_text().strip() != 'eula=true':
        raise render.RenderError('accept the Minecraft EULA before starting the server')
    bridge_binary = (opt.bridge or root / 'bridge-target/release/bridgetest').resolve()
    for port in (25585, 30985):
        if not render.gh.port_free(port):
            raise render.RenderError('comparison port is busy: %d' % port)
    server = bridge = client = control = None
    frames = []
    metadata = {'installation': installation, 'job': job, 'frames': frames,
                'mode': 'headless', 'relative_only': True, 'software': opt.software,
                'goanna': render.git_state(goanna_build),
                'client_mods': {p.name: file_hash(p) for p in sorted((root / 'client/mods').glob('*.jar'))},
                'bridge_build': json.loads((root / 'bridge-build.json').read_text())
                                if (root / 'bridge-build.json').exists() else None,
                'bridge_sha256': file_hash(bridge_binary) if bridge_binary.exists() else None,
                'known_differences': ['BridgeTest approximates some Minecraft models and waterlogging',
                                      'No claim of matching shader-free engine lighting'],
                'ok': False}
    def interrupted(*_args):
        raise KeyboardInterrupt
    def check_gpu():
        if opt.software:
            return
        own = {os.getpid()} | set(render.gh.descendants(os.getpid()))
        if client:
            own |= {client['supervisor_pid']} | set(render.gh.descendants(client['supervisor_pid']))
        busy = render.foreign_gpu_users(own)
        if busy:
            raise render.RenderError('; '.join(busy))
    def settle():
        end = time.monotonic() + float(job.get('settle_seconds', 15))
        while time.monotonic() < end:
            check_gpu()
            if client and render.gh.load(client['id']).get('status') != 'running':
                raise render.RenderError('client exited; see ' + client['client_log'])
            if bridge and bridge.proc.poll() is not None:
                raise render.RenderError('BridgeTest exited; see ' + str(bridge.logfile))
            time.sleep(min(1, max(0, end - time.monotonic())))
    fd, opened = (None, False) if opt.software else render.gh.acquire_gpu_lock()
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        check_gpu()
        pack_env, metadata['packs'] = prepare(root, out, job)
        server = LocalProcess([installation['java'], '-Xms512M', '-Xmx2G', '-jar',
                               str(root / 'server.jar'), 'nogui'], root / 'server',
                              out / 'server.log')
        server.wait_for('Done (')
        metadata['fixture_commands'] = fixture(server)
        renderers = ('minecraft', 'vanilla', 'goanna') if opt.native or opt.only == 'vanilla' else ('minecraft', 'goanna')
        for renderer in renderers:
            if opt.only and opt.only != renderer:
                continue
            check_gpu()
            if renderer == 'minecraft':
                name = 'ComparisonMC'
                client = render.gh.start_minecraft(root, width=width, height=height,
                                                   software=opt.software)
                control = MinecraftControl(root)
            else:
                name = 'CompareVanilla' if renderer == 'vanilla' else 'ComparisonGoanna'
                env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'),
                           XDG_DATA_HOME=metadata['packs'].get('bridge_data', str(root / 'data')),
                           RUST_LOG='info,bridgetest::translator=debug',
                           GOANNA_COMPARISON_CAMERA='1')
                bridge = LocalProcess([str(bridge_binary)], root, out / (renderer + '-bridge.log'), env)
                bridge.wait_for('Waiting for client to connect')
                if renderer == 'vanilla':
                    client = render.gh.start_vanilla(port=30985, name=name, width=width,
                        height=height, software=opt.software,
                        settings={'fov': camera(poses[0])[0]['fov'], 'viewing_range': 128,
                                  'enable_sound': 'false', 'fps_max': 60,
                                  'free_move': 'true', 'noclip': 'true',
                                  'pause_on_lost_focus': 'false'})
                else:
                    xdg = out / 'goanna-data'
                    profile = xdg / 'godot/app_userdata/Goanna'
                    profile.mkdir(parents=True, exist_ok=True)
                    (profile / 'goanna.cfg').write_text('[settings]\nshow_body=0\nasset_updates=false\n')
                    client = render.gh.start_goanna(goanna_build, port=30985, name=name,
                                                    width=width, height=height, software=opt.software,
                                                    env=dict(pack_env, XDG_DATA_HOME=str(xdg),
                                                             GOANNA_NO_STORE='1', GOANNA_PACK_SET='1'))
                    control = render.Control(client['control_port'])
            server.wait_for(name + ' joined the game')
            if renderer == 'vanilla':
                bridge.wait_for('Got C2S ClientReady')
                time.sleep(2)
            end = time.monotonic() + 120
            while renderer != 'vanilla':
                state = control.send('status')
                if renderer == 'minecraft' and state.get('connected'):
                    break
                if renderer == 'goanna' and state.get('blocks_meshed', 0) > 0:
                    break
                if bridge and bridge.proc.poll() is not None:
                    raise render.RenderError('BridgeTest exited; see ' + str(bridge.logfile))
                if time.monotonic() > end:
                    raise render.RenderError('client never received terrain: ' + str(state))
                time.sleep(0.5)
            server.send('gamemode spectator ' + name)
            # Initial world clocks and camera packets can arrive before the
            # bridge has completed its Luanti handshake. Send a fresh clock
            # and teleport only after the receiving client is ready.
            server.send('tick unfreeze')
            server.send('time set %d' % time_ticks)
            time.sleep(2)
            server.send('tick freeze')
            for pose in poses:
                mc, goanna = camera(pose)
                server.send('tp %s %.9g %.9g %.9g %.9g %.9g' %
                            (name, mc['x'], mc['y'] - 1.62, mc['z'], mc['yaw'], mc['pitch']))
                time.sleep(2)
                if renderer == 'minecraft':
                    state = control.send('pose', mc)
                elif renderer == 'goanna':
                    control.send('pose', goanna)
                    control.run('main.cam.fov = %s\nmain.ui.visible = false\nreturn true' % mc['fov'])
                    state = control.send('status')
                settle()
                stage_nodes = None
                if renderer == 'goanna':
                    stage_nodes = control.run(
                        'return {"red": main.client.node_name_at(Vector3(-1, 100, 0)),\n'
                        '\t"gold": main.client.node_name_at(Vector3(-9, 100, -8))}')
                    validate_stage_state(stage_nodes)
                if control:
                    validate_frame_state(renderer, control.send('status'))
                path = out / (render.safe_name(pose['name']) + '-' + renderer + '.png')
                if renderer == 'minecraft':
                    shot = control.send('shot', timeout=60)
                    shutil.copyfile(shot['path'], path)
                    state = control.send('status')
                elif renderer == 'goanna':
                    shot = control.send('shot', {'path': str(path), 'settle': False}, timeout=120)
                    state = control.send('status')
                else:
                    shot = render.gh.screenshot(client['id'], path)
                    state = {'streaming_complete': None, 'native_shader_pack': False,
                             'settings': client['config'], 'hud_hidden': False}
                if control:
                    validate_frame_state(renderer, state)
                if renderer == 'minecraft' and job.get('shader_pack') and not state.get('shader_active'):
                    raise render.RenderError('Iris did not activate the requested shader pack')
                if renderer == 'goanna':
                    state['fixture_nodes'] = stage_nodes
                    state['render_settings'] = control.send('settings')
                    state['sky'] = control.run('return main.client.sky_state()')
                    state['camera_fov_vertical'] = control.run('return main.cam.fov')
                    state['pack_lighting'] = control.run(
                        'return main.iris_gbuffers.lighting_state() if main.iris_gbuffers != null else {}')
                    state['shader_reports'] = control.run(
                        'return {"chain": main.iris.report() if main.iris != null else {},\n'
                        '\t"gbuffers": main.iris_gbuffers.report() if main.iris_gbuffers != null else {}}')
                    if job.get('shader_pack'):
                        validate_shader_state(state['shader_reports'])
                validate_clock_state(renderer, state, time_ticks)
                frame = {'renderer': renderer, 'path': str(path), 'pose': pose,
                         'camera': mc if renderer == 'minecraft' else goanna,
                         'observed': state, 'capture': shot,
                         'fixed_wait_s': job.get('settle_seconds', 15),
                         'client_log': client['client_log']}
                if renderer == 'vanilla':
                    frame['camera'] = {'x': -mc['x'] - 0.5, 'y': mc['y'] - 0.5,
                                       'z': mc['z'] - 0.5, 'yaw': -mc['yaw'],
                                       'pitch': mc['pitch'], 'fov': mc['fov'],
                                       'framed_by': 'server teleport'}
                frames.append(frame)
                render.write_json(path.with_suffix('.json'), frame)
                print(json.dumps({'captured': str(path)}), flush=True)
            if renderer == 'goanna':
                control.close()
            control = None
            render.gh.stop(client['id'])
            client = None
            if bridge:
                bridge.stop()
                bridge = None
        metadata['ok'] = True
        report(out, frames)
        return 0
    except BaseException as error:
        metadata['error'] = str(error) or type(error).__name__
        raise
    finally:
        try:
            if client:
                render.gh.stop(client['id'])
        finally:
            try:
                try:
                    if control and isinstance(control, render.Control):
                        control.close()
                    if bridge:
                        bridge.stop()
                finally:
                    if server:
                        server.stop('stop')
            finally:
                try:
                    render.write_json(out / 'result.json', metadata)
                finally:
                    signal.signal(signal.SIGTERM, previous)
                    if opened:
                        os.close(fd)
