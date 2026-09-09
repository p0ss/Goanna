#!/usr/bin/env python3
"""Synthetic regression tests for the PBR acceptance gate."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image


TOOLS = Path(__file__).parent
spec = importlib.util.spec_from_file_location("check_pbr_quality",
                                              TOOLS / "check-pbr-quality.py")
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)

spec = importlib.util.spec_from_file_location("pbr_bake", TOOLS / "pbr_bake.py")
bake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bake)


class PbrQualityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def maps(self, smooth=31, metal=10, transparent_bad=False):
        normal = np.zeros((16, 16, 4), dtype=np.uint8)
        normal[..., :2] = 128
        normal[..., 2] = 255
        normal[..., 3] = np.linspace(115, 255, 16, dtype=np.uint8)[None, :]
        if transparent_bad:
            normal[0, 0] = (20, 20, 20, 20)
        spec_map = np.zeros((4, 4, 4), dtype=np.uint8)
        spec_map[...] = (smooth, metal, 0, 255)
        npath, spath = self.root / "tile_n.png", self.root / "tile_s.png"
        Image.fromarray(normal, "RGBA").save(npath)
        Image.fromarray(spec_map, "RGBA").save(spath)
        return npath, spath

    def test_plastic_stone_is_rejected(self):
        npath, spath = self.maps(smooth=210)
        report = quality.inspect("tile", npath, spath, "stone")
        self.assertTrue(any("too smooth" in item for item in report["failures"]))

    def test_dark_diffuse_art_is_not_accepted_as_metal(self):
        npath, spath = self.maps(smooth=80, metal=255)
        source = self.root / "tile.png"
        Image.new("RGBA", (16, 16), (30, 30, 30, 255)).save(source)
        report = quality.inspect("tile", npath, spath, "metal", source)
        self.assertTrue(any("dark diffuse" in item for item in report["failures"]))

    def test_transparent_regions_must_be_neutral(self):
        npath, spath = self.maps(transparent_bad=True)
        source = self.root / "tile.png"
        image = Image.new("RGBA", (16, 16), (100, 100, 100, 255))
        image.putpixel((0, 0), (0, 0, 0, 0))
        image.save(source)
        report = quality.inspect("tile", npath, spath, "stone", source)
        self.assertTrue(any("transparent pixels" in item for item in report["failures"]))

    def test_height_is_robustly_bounded_by_material(self):
        normal = Image.new("RGB", (16, 16), (128, 128, 255))
        height = np.tile(np.arange(16, dtype=np.uint8), (16, 1)) * 16
        height[0, 0] = 255
        out = self.root / "bounded_n.png"
        bake.pack_deepbump_normal(normal, Image.fromarray(height, "L"), out,
                                  "tile", {"tile": "metal"})
        encoded = np.asarray(Image.open(out).convert("RGBA"))[..., 3]
        self.assertGreaterEqual(int(encoded.min()), 255 - round(0.18 * 255) - 1)
        self.assertEqual(int(encoded.max()), 255)

    def test_review_controls_full_resolution_spec_channels(self):
        roughness = Image.fromarray(np.tile(
            np.linspace(0, 255, 16, dtype=np.uint8), (16, 1)), "L")
        metalness = Image.fromarray(np.tile(
            np.array([0] * 8 + [255] * 8, dtype=np.uint8), (16, 1)), "L")
        out = self.root / "reviewed_s.png"
        review = {"tile": {
            "smoothness_min": 0.2,
            "smoothness_max": 0.6,
            "metalness_policy": "partial",
        }}
        bake.pack_hybrid_spec(roughness, metalness, "tile", {"tile": "stone"},
                              out, (16, 16), review)
        packed = np.asarray(Image.open(out).convert("RGBA"))
        self.assertEqual(packed.shape[:2], (16, 16))
        self.assertGreater(len(np.unique(packed[..., 0])), 1)
        self.assertGreaterEqual(int(packed[..., 0].min()), round(0.2 * 255) - 1)
        self.assertLessEqual(int(packed[..., 0].max()), round(0.6 * 255) + 1)
        self.assertEqual(set(np.unique(packed[..., 1])), {10, 255})

    def test_review_can_veto_false_metal(self):
        image = Image.new("L", (8, 8), 255)
        out = self.root / "nonmetal_s.png"
        review = {"tile": {"metalness_policy": "none"}}
        bake.pack_hybrid_spec(image, image, "tile", {"tile": "metal"},
                              out, (8, 8), review)
        packed = np.asarray(Image.open(out).convert("RGBA"))
        self.assertEqual(set(np.unique(packed[..., 1])), {10})

    def test_review_rules_are_ordered_and_exact_entries_win(self):
        path = self.root / "review.json"
        path.write_text(json.dumps({
            "rules": [
                {"match": "ore_*", "primary_material": "stone"},
                {"match": "ore_gold", "metalness_policy": "partial"},
            ],
            "entries": {
                "ore_gold": {"primary_material": "mixed"},
                "out_of_scope": {"primary_material": "metal"},
            },
        }))
        reviews = bake.load_classification_review(path, {"ore_gold", "ore_coal"})
        self.assertEqual(reviews["ore_gold"]["primary_material"], "mixed")
        self.assertEqual(reviews["ore_gold"]["metalness_policy"], "partial")
        self.assertEqual(reviews["ore_coal"]["primary_material"], "stone")
        self.assertNotIn("out_of_scope", reviews)


if __name__ == "__main__":
    unittest.main()
