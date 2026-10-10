#!/usr/bin/env python3
"""atlas.py's .obj reader, against Luanti's loader's rules.

The synthetic cases need nothing installed. The two Mineclonia models the
reader was written for (the dragon head and the armour stand) are checked
too when the game is where tools/pbr/pbr_author/lib.py looks for it, and skipped
otherwise.
"""
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent / "pbr_author"))
import atlas  # noqa: E402
import lib  # noqa: E402

QUAD = """v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
vt 0 0
vt 0.5 0
vt 0.5 0.25
vt 0 0.25
"""


def write(tmp, text, name="m.obj"):
    p = Path(tmp) / name
    p.write_text(text)
    return p


class ObjReaderTest(unittest.TestCase):
    def test_quad_fans_and_flips_v(self):
        with tempfile.TemporaryDirectory() as tmp:
            meshes = atlas.read_obj(write(tmp, QUAD + "f 1/1 2/2 3/3 4/4\n"))
        self.assertEqual(len(meshes), 1)
        pos, uv, tris = meshes[0]
        self.assertEqual([b for b, _ in tris], [0])
        # Fanned from the first corner, (i + 1, i, 0) as the loader orders it.
        self.assertEqual(tris[0][1].tolist(), [[2, 1, 0], [3, 2, 0]])
        # v is flipped: 0.25 in the file is 0.75 down the image.
        self.assertTrue(np.allclose(uv[2], [0.5, 0.75]))
        self.assertTrue(np.allclose(pos[3], [0, 1, 0]))

    def test_usemtl_without_group_keeps_the_buffer(self):
        text = QUAD + "o a\nusemtl m1\nf 1/1 2/2 3/3\no b\nusemtl m2\nf 1/1 3/3 4/4\n"
        with tempfile.TemporaryDirectory() as tmp:
            meshes = atlas.read_obj(write(tmp, text))
        self.assertEqual([b for b, _ in meshes[0][2]], [0])
        self.assertEqual(len(meshes[0][2][0][1]), 2)

    def test_each_group_starts_a_buffer(self):
        text = (QUAD + "g first\nusemtl Stand\nf 1/1 2/2 3/3\n"
                "g second\nusemtl Base\nf 1/1 3/3 4/4\nf -4/-4 -3/-3 -2/-2\n")
        with tempfile.TemporaryDirectory() as tmp:
            pos, uv, tris = atlas.read_obj(write(tmp, text))[0]
        self.assertEqual([b for b, _ in tris], [0, 1])
        self.assertEqual(len(tris[0][1]), 1)
        self.assertEqual(len(tris[1][1]), 2)
        # Negative indices count back from the end: -4 is vertex 1.
        second = tris[1][1]
        self.assertTrue(np.allclose(pos[second[1][2]], [0, 0, 0]))
        # The buffers share no vertices.
        self.assertFalse(set(tris[0][1].ravel()) & set(second.ravel()))

    def test_merged_corners_drop_the_triangle(self):
        # Corners 1 and 5 are the same vertex with the same uv: merged, so
        # the triangle (5, 2, 1) repeats a corner and is dropped.
        text = QUAD + "v 0 0 0\nf 1/1 2/2 5/1\nf 1/1 2/2 3/3\n"
        with tempfile.TemporaryDirectory() as tmp:
            tris = atlas.read_obj(write(tmp, text))[0][2]
        self.assertEqual(len(tris[0][1]), 1)

    def test_read_model_dispatches_on_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = write(tmp, QUAD + "f 1/1 2/2 3/3\n", "M.OBJ")
            self.assertEqual(len(atlas.read_model(p)[0][2][0][1]), 1)


ART = lib.GAMES[lib.DEFAULT_GAME]["art"]


@unittest.skipUnless((ART / "mods").is_dir(), "Mineclonia is not installed at %s" % ART)
class MinecloniaModelsTest(unittest.TestCase):
    # The buffer, triangle and vertex counts below are what Luanti's own
    # loader (COBJMeshFileLoader through the extension's ModelCache) made
    # of these files on 2026-10-05, Mineclonia as installed then.
    def counts(self, model):
        pos, uv, tris = atlas.read_model(atlas.model_path(model, lib.DEFAULT_GAME))[0]
        return [(b, len(t), len(set(t.ravel()))) for b, t in tris]

    def test_counts_match_luantis_loader(self):
        self.assertEqual(self.counts("mcl_heads_dragon_floor.obj"), [(0, 84, 168)])
        self.assertEqual(self.counts("3d_armor_stand.obj"), [(0, 120, 192), (1, 12, 24)])

    def test_dragon_head_is_one_buffer_of_boxes(self):
        rects = atlas.faces("mcl_heads_dragon_floor.obj", 0, 256, 256)
        self.assertTrue(rects, "the dragon head has faces on buffer 0")
        self.assertEqual(atlas.faces("mcl_heads_dragon_floor.obj", 1, 256, 256), [])
        # Every face is an axis aligned rectangle inside the image.
        for (x0, y0, x1, y1), n in rects:
            self.assertTrue(0 <= x0 < x1 <= 256 and 0 <= y0 < y1 <= 256)
            self.assertGreaterEqual(n, 2)

    def test_armour_stand_is_two_buffers(self):
        path = atlas.model_path("3d_armor_stand.obj", lib.DEFAULT_GAME)
        meshes = atlas.read_model(path)
        self.assertEqual([b for b, _ in meshes[0][2]], [0, 1])
        self.assertTrue(atlas.faces("3d_armor_stand.obj", 0, 64, 64))
        self.assertTrue(atlas.face_frames("3d_armor_stand.obj", 0, 64, 64))


if __name__ == "__main__":
    unittest.main()
