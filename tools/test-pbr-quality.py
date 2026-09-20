#!/usr/bin/env python3
"""Synthetic regression tests for the PBR acceptance gate."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, PngImagePlugin


TOOLS = Path(__file__).parent
spec = importlib.util.spec_from_file_location("check_pbr_quality",
                                              TOOLS / "check-pbr-quality.py")
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)

spec = importlib.util.spec_from_file_location("pbr_bake", TOOLS / "pbr_bake.py")
bake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bake)

spec = importlib.util.spec_from_file_location("pbr_author_lib",
                                              TOOLS / "pbr_author" / "lib.py")
author = importlib.util.module_from_spec(spec)
spec.loader.exec_module(author)


class PbrQualityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def maps(self, smooth=31, metal=10, transparent_bad=False, height=None,
             sloped=False, authored=False):
        normal = np.zeros((16, 16, 4), dtype=np.uint8)
        normal[..., :2] = 128
        normal[..., 2] = 255
        if height is None:
            height = np.linspace(115, 255, 16, dtype=np.uint8)
        normal[..., 3] = np.asarray(height, dtype=np.uint8)[None, :]
        if sloped:
            normal[..., 0] = np.linspace(60, 200, 16, dtype=np.uint8)[None, :]
        if transparent_bad:
            normal[0, 0] = (20, 20, 20, 20)
        spec_map = np.zeros((4, 4, 4), dtype=np.uint8)
        spec_map[...] = (smooth, metal, 0, 255)
        info = None
        if authored:
            info = PngImagePlugin.PngInfo()
            info.add_text(quality.PIPELINE_KEY, quality.AUTHORED)
        npath, spath = self.root / "tile_n.png", self.root / "tile_s.png"
        Image.fromarray(normal, "RGBA").save(npath, pnginfo=info)
        Image.fromarray(spec_map, "RGBA").save(spath, pnginfo=info)
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

    def test_authored_height_is_measured_by_the_authored_rule(self):
        # lib.band holds a cast slab's relief in a narrow band about the
        # middle of the byte and leaves the depth to the shader's class
        # table, so the field neither reaches the bake's neutral 255 nor
        # stays inside the bake's class envelope. Both are true of the same
        # bytes; only the marker says which rule they were written to.
        band = np.linspace(96, 160, 16, dtype=np.uint8)
        npath, spath = self.maps(height=band)
        baked = quality.inspect("tile", npath, spath, "metal")
        self.assertEqual(baked["pipeline"], quality.BAKED)
        self.assertTrue(any("neutral/high" in item for item in baked["failures"]))
        self.assertTrue(any("depth envelope" in item for item in baked["failures"]))
        npath, spath = self.maps(height=band, authored=True)
        authored = quality.inspect("tile", npath, spath, "metal")
        self.assertEqual(authored["pipeline"], quality.AUTHORED)
        self.assertEqual(authored["failures"], [])

    def test_crushed_authored_height_still_fails(self):
        # Half the tile pinned at 0 and half at 255 is a field that ran off
        # both ends of the byte. The relief between them is gone and the
        # marker does not bring it back.
        crushed = np.array([0] * 8 + [255] * 8, dtype=np.uint8)
        report = quality.inspect("tile", *self.maps(height=crushed,
                                                    authored=True), "stone")
        self.assertTrue(any("crushed against the byte rails" in item
                            for item in report["failures"]))

    def test_flat_authored_height_under_relief_still_fails(self):
        # An authored normal is derived from the authored height, so a normal
        # with slope over a height with none is a packing fault, whatever
        # depth the class asks for.
        flat = np.full(16, 128, dtype=np.uint8)
        report = quality.inspect("tile", *self.maps(height=flat, sloped=True,
                                                    authored=True), "stone")
        self.assertTrue(any("effectively flat" in item
                            for item in report["failures"]))

    def test_author_library_marks_the_maps_it_writes(self):
        size = author.SIZE
        height = np.tile(np.linspace(0.0, 1.0, size, dtype=np.float32), (size, 1))
        smoothness = np.full((size, size), 0.12, dtype=np.float32)
        albedo = np.full((size, size, 3), 0.5, dtype=np.float32)
        author.pack("marked", self.root, albedo, height, smoothness, "stone", 8.0)
        for suffix in ("_n.png", "_s.png"):
            self.assertEqual(quality.pipeline_of(self.root / ("marked" + suffix)),
                             quality.AUTHORED)
        report = quality.inspect("marked", self.root / "marked_n.png",
                                 self.root / "marked_s.png", "stone")
        self.assertEqual(report["pipeline"], quality.AUTHORED)

    def cut_out_source(self, size=16):
        """16 px art whose left half is a hole, the shape a cut-out has."""
        art = np.zeros((size, size, 4), dtype=np.uint8)
        art[..., :3] = 128
        art[..., 3] = 255
        art[:, : size // 2, 3] = 0
        path = self.root / "cut.png"
        Image.fromarray(art, "RGBA").save(path)
        return path

    def test_author_library_neutralises_a_cut_out(self):
        # tools/pbr_bake.py's mask_transparent_regions puts the bake's
        # neutral in the texels a source draws nothing in, and the gate
        # holds the authored maps to the same rule. The same fields packed
        # twice, once behind a cut-out and once behind art that fills the
        # tile, must differ in the holes and nowhere else.
        size = author.SIZE
        ramp = np.tile(np.linspace(0.0, 1.0, size, dtype=np.float32), (size, 1))
        solid = np.full((size, size, 4), 0.5, dtype=np.float32)
        solid[..., 3] = 1.0
        cut = solid.copy()
        cut[:, : size // 2, 3] = 0.0
        author.pack("solid", self.root, solid, ramp, ramp, "stone", 8.0)
        author.pack("cut", self.root, cut, ramp, ramp, "stone", 8.0)
        hole = np.zeros((size, size), dtype=bool)
        hole[:, : size // 2] = True
        for suffix, neutral in (("_n.png", bake.NEUTRAL_N),
                                ("_s.png", bake.NEUTRAL_S)):
            filled = np.asarray(
                Image.open(self.root / ("solid" + suffix)).convert("RGBA"))
            masked = np.asarray(
                Image.open(self.root / ("cut" + suffix)).convert("RGBA"))
            neutral = np.array(neutral, dtype=np.uint8)
            self.assertTrue((masked[hole] == neutral).all())
            # The fields are derived across the whole tile before anything
            # is masked, so a drawn texel beside a hole keeps the slope and
            # the occlusion it had. Byte identical, not merely close.
            self.assertTrue((masked[~hole] == filled[~hole]).all())
            # And the holes were carrying something else before the mask,
            # so the assertion above is not passing on an accident.
            self.assertFalse((filled[hole] == neutral).all())
        report = quality.inspect("cut", self.root / "cut_n.png",
                                 self.root / "cut_s.png", "stone",
                                 str(self.cut_out_source()))
        self.assertNotIn("transparent pixels are not neutral in the normal map",
                         report["failures"])

    def test_author_library_takes_a_cut_out_from_an_explicit_alpha(self):
        # A script that upscales its art as RGB has no alpha in the albedo
        # for pack to read, so it passes the source's own instead.
        size = author.SIZE
        ramp = np.tile(np.linspace(0.0, 1.0, size, dtype=np.float32), (size, 1))
        rgb = np.full((size, size, 3), 0.5, dtype=np.float32)
        alpha = np.ones((size, size), dtype=np.float32)
        alpha[:, : size // 2] = 0.0
        author.pack("rgb_art", self.root, rgb, ramp, ramp, "stone", 8.0,
                    alpha=alpha)
        normal = np.asarray(
            Image.open(self.root / "rgb_art_n.png").convert("RGBA"))
        hole = np.zeros((size, size), dtype=bool)
        hole[:, : size // 2] = True
        self.assertTrue((normal[hole] ==
                         np.array(bake.NEUTRAL_N, dtype=np.uint8)).all())

    def test_author_library_leaves_art_that_fills_the_tile_alone(self):
        size = author.SIZE
        ramp = np.tile(np.linspace(0.0, 1.0, size, dtype=np.float32), (size, 1))
        opaque = np.full((size, size, 4), 0.5, dtype=np.float32)
        opaque[..., 3] = 1.0
        author.pack("opaque", self.root, opaque, ramp, ramp, "stone", 8.0)
        author.pack("three", self.root, opaque[..., :3], ramp, ramp, "stone", 8.0)
        for suffix in ("_n.png", "_s.png"):
            self.assertEqual(
                (self.root / ("opaque" + suffix)).read_bytes(),
                (self.root / ("three" + suffix)).read_bytes())

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
