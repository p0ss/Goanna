#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Record a repeatable far-rendering baseline from a running Goanna client.

Start a Terrain Diffusion showcase world with GOANNA_CONTROL set, wait until
the player is standing at the intended showcase spawn, then run this tool.
It anchors every view to the server-reported player position, records JSONL
telemetry, captures fixed screenshots, and writes an aggregate summary.
"""

import argparse
import json
import math
import os
import socket
import statistics
import time
from pathlib import Path


DEFAULT_PORT = 30800


class Control:
    def __init__(self, host, port, timeout):
        self.sock = socket.create_connection((host, port), timeout=5.0)
        self.sock.settimeout(timeout)
        self.next_id = 0

    def close(self):
        self.sock.close()

    def call(self, command, args=None):
        self.next_id += 1
        request = {"id": self.next_id, "cmd": command, "args": args or {}}
        self.sock.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("control channel closed during %s" % command)
            data += chunk
        reply = json.loads(data.split(b"\n", 1)[0])
        if not reply.get("ok"):
            raise RuntimeError("%s failed: %s" % (command, reply.get("error")))
        return reply.get("result")


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    at = fraction * (len(ordered) - 1)
    lo = math.floor(at)
    hi = math.ceil(at)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] * (hi - at) + ordered[hi] * (at - lo)


def nested(sample, path):
    value = sample
    for key in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value if isinstance(value, (int, float)) else None


METRICS = [
    "render.frame_fps", "render.render_cpu_setup_ms", "render.render_cpu_draw_ms",
    "render.render_gpu_ms", "render.draw_calls", "render.objects",
    "render.primitives", "render.video_mem_mb", "render.blocks_queued",
    "render.mesh_queued", "render.mesh_running", "render.mesh_ready",
    "render.block_meshes", "render.lod_regions", "render.lod_regions_dirty",
    "render.lod_chains", "render.lod_chain_queue", "render.lod_update_ms",
    "render.lod_ms", "render.poll_max_ms", "render.far_blocks",
    "render.far_extent", "render.far_reach", "render.store_blocks",
    "render.store_mb",
]


def summarize(samples):
    result = {"samples": len(samples)}
    for metric in METRICS:
        values = [nested(sample, metric) for sample in samples]
        values = [float(value) for value in values if value is not None]
        if values:
            result[metric] = {
                "median": statistics.median(values),
                "p95": percentile(values, 0.95),
                "max": max(values),
                "last": values[-1],
            }
    return result


def telemetry(control):
    result = control.call("eval", {
        "expr": '{"status": client.status(), "render": client.render_stats(), '
                '"camera": cam.position, "server_position": '
                'client.server_player_position(), "frame_fps": '
                'Engine.get_frames_per_second()}'
    })
    value = result.get("value", result)
    value["monotonic_s"] = time.monotonic()
    render = value.setdefault("render", {})
    # Engine FPS is not part of render_stats on all builds.
    render["frame_fps"] = value.pop("frame_fps", 0)
    return value


def queues_settled(sample):
    render = sample.get("render", {})
    return all(int(render.get(key, 0)) == 0 for key in (
        "blocks_queued", "mesh_queued", "mesh_running", "mesh_ready",
        "lod_regions_dirty", "lod_chain_queue", "lod_building"))


def wait_for_settle(control, quiet_seconds, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    quiet_since = None
    last = None
    while time.monotonic() < deadline:
        last = telemetry(control)
        if queues_settled(last):
            quiet_since = quiet_since or time.monotonic()
            if time.monotonic() - quiet_since >= quiet_seconds:
                return True, last
        else:
            quiet_since = None
        time.sleep(1.0)
    return False, last


def sample_view(control, output, name, seconds):
    samples = []
    started = time.monotonic()
    next_sample = started
    while time.monotonic() - started < seconds:
        now = time.monotonic()
        if now < next_sample:
            time.sleep(next_sample - now)
        sample = telemetry(control)
        sample["view"] = name
        sample["elapsed_s"] = time.monotonic() - started
        samples.append(sample)
        next_sample += 1.0
    with (output / "samples.jsonl").open("a", encoding="utf-8") as handle:
        for sample in samples:
            handle.write(json.dumps(sample, separators=(",", ":")) + "\n")
    return samples


def vec(value):
    if not isinstance(value, list) or len(value) != 3:
        raise RuntimeError("control channel returned an invalid Vector3: %r" % value)
    return [float(component) for component in value]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new or empty result directory")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--sample-seconds", type=int, default=60)
    parser.add_argument("--soak-seconds", type=int, default=600)
    parser.add_argument("--settle-seconds", type=int, default=30)
    parser.add_argument("--settle-timeout", type=int, default=600)
    parser.add_argument("--aerial-height", type=float, default=192.0)
    parser.add_argument("--look-distance", type=float, default=512.0)
    parser.add_argument("--build-label", default="unlabelled",
                        help="commit, branch or build name stored with the run")
    options = parser.parse_args()

    options.output.mkdir(parents=True, exist_ok=True)
    if any(options.output.iterdir()):
        parser.error("output directory must be empty: %s" % options.output)

    control = Control(options.host, options.port,
                      max(120, options.settle_timeout + 30))
    summaries = {}
    try:
        control.call("label", {"text": "TDL far-rendering baseline"})
        initial = control.call("status")
        anchor = vec(initial["server_position"])
        machine = control.call("eval", {
            "expr": '{"godot": Engine.get_version_info(), "gpu": '
                    'RenderingServer.get_video_adapter_name(), "cpu": '
                    'OS.get_processor_name(), "cores": OS.get_processor_count(), '
                    '"viewport": get_viewport().get_visible_rect().size}'
        })
        manifest = {
            "format": 1,
            "created_unix": time.time(),
            "build_label": options.build_label,
            "machine": machine.get("value", machine),
            "anchor_server_position": anchor,
            "initial_status": initial,
            "sample_seconds": options.sample_seconds,
            "soak_seconds": options.soak_seconds,
            "settle_seconds": options.settle_seconds,
            "settle_timeout": options.settle_timeout,
        }

        settled, settle_sample = wait_for_settle(
            control, options.settle_seconds, options.settle_timeout)
        manifest["initial_settled"] = settled
        manifest["settle_sample"] = settle_sample

        x, y, z = anchor
        aerial = [x, y + options.aerial_height, z]
        views = [
            ("spawn_north", aerial, [x, y + 32, z - options.look_distance]),
            ("spawn_east", aerial, [x + options.look_distance, y + 32, z]),
            ("spawn_south", aerial, [x, y + 32, z + options.look_distance]),
            ("spawn_west", aerial, [x - options.look_distance, y + 32, z]),
        ]
        for name, camera, target in views:
            control.call("pose", {"x": camera[0], "y": camera[1],
                                   "z": camera[2], "fly": True})
            control.call("look", {"x": target[0], "y": target[1], "z": target[2]})
            settled, _ = wait_for_settle(
                control, options.settle_seconds, options.settle_timeout)
            samples = sample_view(control, options.output, name,
                                  options.sample_seconds)
            control.call("shot", {"path": str((options.output / (name + ".png")).resolve()),
                                  "settle": False, "warm": 0})
            summaries[name] = summarize(samples)
            summaries[name]["settled"] = settled

        soak_name = "stationary_soak"
        samples = sample_view(control, options.output, soak_name,
                              options.soak_seconds)
        control.call("shot", {"path": str((options.output / "stationary_soak.png").resolve()),
                              "settle": False, "warm": 0})
        summaries[soak_name] = summarize(samples)

        manifest["views"] = list(summaries)
        (options.output / "manifest.json").write_text(
            json.dumps(manifest, indent=2), encoding="utf-8")
        (options.output / "summary.json").write_text(
            json.dumps(summaries, indent=2), encoding="utf-8")
        print("far baseline written to %s" % options.output)
        if options.build_label == "unlabelled":
            print("warning: use --build-label so this run can be identified later")
        if not manifest["initial_settled"] or any(
                not summary.get("settled", True) for summary in summaries.values()):
            print("warning: at least one view did not settle before measurement")
    finally:
        control.close()


if __name__ == "__main__":
    main()
