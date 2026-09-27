#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Check that the benchmark cannot call unconsumed terrain work settled."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "local_bench", Path(__file__).with_name("bench-local-play.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class SettleTests(unittest.TestCase):
    def run_settle(self, pending_key=None, release_after=None):
        clock = [100.0]

        def sleep(seconds):
            clock[0] += seconds

        def snapshot(*_args):
            # Player 1 stays quiet; player 2 owns the pending work. Constant
            # mesh counts alone must not establish that every view is ready.
            players = [{"status": {"state": "ready"},
                        "render": {"block_meshes": 12, "blocks_queued": 0}}
                       for _ in range(2)]
            if pending_key and (release_after is None or clock[0] < 100 + release_after):
                players[1]["render"][pending_key] = 1
            return players

        with patch.object(bench, "run_code", side_effect=snapshot), \
                patch.object(bench.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(bench.time, "sleep", side_effect=sleep):
            result = bench.settle(None, timeout=30, quiet_seconds=10)
        return result, clock[0] - 100

    def test_quiet_players_settle(self):
        result, elapsed = self.run_settle()
        self.assertTrue(result["settled"])
        self.assertGreaterEqual(elapsed, 10)

    def test_constant_pending_work_times_out(self):
        for key in ("blocks_queued", "near_ready", "mesh_queued", "mesh_running",
                    "near_regions_dirty", "near_regions_building",
                    "mesh_ready", "lod_regions_dirty", "lod_chain_queue", "lod_building",
                    "surface_inflight", "surface_building", "surface_uploads",
                    "lod_storage_pending", "lod_storage_queued", "lod_storage_active",
                    "lod_storage_ready", "lod_storage_retry_regions"):
            with self.subTest(key=key):
                result, _ = self.run_settle(key)
                self.assertFalse(result["settled"])

    def test_quiet_window_starts_after_last_player_drains(self):
        result, elapsed = self.run_settle("near_ready", release_after=15)
        self.assertTrue(result["settled"])
        self.assertGreaterEqual(elapsed, 25)


if __name__ == "__main__":
    unittest.main()
