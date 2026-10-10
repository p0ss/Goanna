#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

from PIL import Image, PngImagePlugin

spec = importlib.util.spec_from_file_location("pbr_bundle", Path(__file__).with_name("pbr_bundle.py"))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


def write_pair(textures, stem, height=(0, 255), authored=False):
    """A _n/_s pair whose _n alpha runs from height[0] to height[1]."""
    info = None
    if authored:
        info = PngImagePlugin.PngInfo()
        info.add_text("goanna_pipeline", "authored")
    normal = Image.new("RGBA", (2, 2), (128, 128, 255, height[1]))
    normal.putpixel((0, 0), (128, 128, 255, height[0]))
    normal.save(textures / f"{stem}_n.png", pnginfo=info)
    Image.new("RGBA", (2, 2), (31, 10, 0, 255)).save(textures / f"{stem}_s.png", pnginfo=info)


def build_args(textures, output):
    return Namespace(textures=str(textures), quality=None, attribution=None,
                     id="org.goanna.test", version="1.0.0", tranche="terrain",
                     game=["test"], source_package="test/game", source_release="1",
                     source_sha256="0" * 64, pipeline_version="1", output=str(output))


class BundleTest(unittest.TestCase):
    def test_build_is_deterministic_and_installable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            textures = root / "textures"
            textures.mkdir()
            write_pair(textures, "stone")
            common = dict(textures=str(textures), quality=None, attribution=None,
                          id="org.goanna.test", version="1.0.0", tranche="terrain",
                          game=["test"], source_package="test/game", source_release="1",
                          source_sha256="0" * 64, pipeline_version="1", catalogue=None, url=None)
            first, second = root / "a.zip", root / "b.zip"
            bundle.build(Namespace(**common, output=str(first)))
            bundle.build(Namespace(**common, output=str(second)))
            self.assertEqual(first.read_bytes(), second.read_bytes())
            manifest, files = bundle.read_bundle(first)
            self.assertEqual(manifest["texture_pairs"], 1)
            self.assertEqual(set(files), {"textures/stone_n.png", "textures/stone_s.png"})
            install = root / "installed"
            bundle.install(Namespace(bundle=str(first), root=str(install)))
            self.assertTrue((install / "org.goanna.test/1.0.0/textures/stone_n.png").is_file())
            self.assertTrue((install / "profiles/test/textures/stone_n.png").is_file())

    def test_flattened_height_is_refused(self):
        """A bake scaled by a class depth the shader applies again.

        0.55 is stone's depth: 141 of 255, the span every stone map in
        Minetest Game terrain 1.0.0 has.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            textures = root / "textures"
            textures.mkdir()
            for stem in ("stone", "cobble", "gravel"):
                write_pair(textures, stem, height=(114, 255))
            with self.assertRaisesRegex(ValueError, "do not fill the height byte"):
                bundle.build(build_args(textures, root / "flat.zip"))
            self.assertFalse((root / "flat.zip").exists())

    def test_authored_height_is_not_held_to_the_bake(self):
        """lib.band holds a cast slab to a few per cent of the byte on purpose."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            textures = root / "textures"
            textures.mkdir()
            write_pair(textures, "stone")
            for stem in ("slab_a", "slab_b"):
                write_pair(textures, stem, height=(120, 136), authored=True)
            bundle.build(build_args(textures, root / "mixed.zip"))
            bundle.verify(Namespace(bundle=str(root / "mixed.zip"), sha256=None))

    def test_archive_members_are_checked_by_name(self):
        """verify hands the check an archive's members, textures/ prefix and all.

        That is what catches a pack built before this check existed, such as
        Mineclonia pack 1.0.0.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            textures = root / "textures"
            textures.mkdir()
            write_pair(textures, "stone", height=(114, 255))
            files = bundle.payload(textures, None)
            self.assertIn("textures/stone_n.png", files)
            with self.assertRaisesRegex(ValueError, "do not fill the height byte"):
                bundle.require_height_fill(files, "test")


if __name__ == "__main__":
    unittest.main()
