#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

from PIL import Image

spec = importlib.util.spec_from_file_location("pbr_bundle", Path(__file__).with_name("pbr_bundle.py"))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class BundleTest(unittest.TestCase):
    def test_build_is_deterministic_and_installable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            textures = root / "textures"
            textures.mkdir()
            for suffix in ("n", "s"):
                Image.new("RGBA", (2, 2), (128, 128, 255, 255)).save(textures / f"stone_{suffix}.png")
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


if __name__ == "__main__":
    unittest.main()
