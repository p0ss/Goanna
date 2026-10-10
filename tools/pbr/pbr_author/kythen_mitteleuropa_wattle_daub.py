"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_wattle_daub.

The 32 px art is a fine mottled render, five close shades from 0.341 to
0.582, no drawn joint, block or weave outline anywhere: row means run 0.417
to 0.482 and column means 0.417 to 0.498, both wandering without a clean
repeating period, so there is no strong row or column signal to read a
withy spacing back from directly, the same situation
kythen_habesha_terrace_face.py's art gives for its dry stone joints. The
name and the brief are explicit about what this surface physically is
though: a daub render smoothed over a wattle lattice, with the withies
just showing through as faint horizontal ridges, so that structure is
reasoned by hand rather than invented from nothing: a withy roughly every
eight texels, the ordinary spacing kythen_habesha_wattle.py's own woven
withies use, barely proud under the render.

lib.class_of reads back "wood" from the bake, an artefact of the level
readback the way kythen_khmer_stucco.py's docstring explains for its own
render, not a material judgement: a daub wall is dried mud plastered over a
timber lattice, earth rather than timber, so this overrides to "soil".
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_wattle_daub"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("col means:", np.round(lum.mean(axis=0), 3))
    print(f"class_of would read: {lib.class_of(STEM, GAME)}, overridden to {CLS} "
          f"(dried mud render over a timber lattice, earth not timber)")

    # The render's own mottling, smoothly upscaled and rounded: a gentle
    # undulation from a daub wall trowelled by hand, the same construction
    # hardened_clay_family.py and kythen_khmer_stucco.py use for their own
    # renders.
    norm_lum = (lum - lum.min()) / max(lum.max() - lum.min(), 1e-6)
    mottle = lib.blur(lib.upscale(norm_lum, smooth=True), 3)

    # Faint horizontal ridges: the wattle withies just showing through the
    # render, one per eight texels (four withies over the tile height), a
    # single wrapped cosine period each so the band tiles cleanly with no
    # kink at the wrap.
    period = 8
    rows = np.arange(SIZE)[:, None]
    art_row = rows / SIZE * src.shape[0]
    withy = 0.5 * (1.0 + np.cos(2 * np.pi * (art_row % period) / period))
    withy = np.broadcast_to(withy, (SIZE, SIZE))

    # Fine grain and pores, the render's own texture below the withy scale.
    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=861, gain=0.55)
    pores = lib.blur(lib.white_noise(SIZE, seed=862), 1)

    # Weighted toward the fine grain and pores, the same balance
    # kythen_habesha_threshing_floor.py found for its own flat soil face:
    # the broad mottle and withy bands carry the overall shape but the
    # texel scale grain is what actually self shadows, since ao_from_height
    # sees local contrast, not a slow wide undulation.
    field = 0.08 * mottle + 0.08 * withy + 0.44 * grain + 0.40 * pores
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    # A daub render is close to flat: the withies barely show, so the whole
    # field is held in a narrow band rather than stretched to the byte, the
    # same call the two renders above make.
    height = lib.band(field, 0.45)
    print(f"height sd {height.std():.3f}")

    # Smoothness: fairly even, a touch glossier on the withy ridges and the
    # trowelled high points than in the shallow low ground between them.
    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=863, gain=0.55)
    smooth = 0.20 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 7
    # The only relief on this near flat render is grain and withy scale
    # texture, one or two texels across, which pack()'s default fine_detail
    # (0.35) is built to damp; at the default it damped the self shadow
    # away entirely, the same shortfall kythen_habesha_threshing_floor.py
    # reports for its own flat soil face. fine_detail=1.0 keeps it.
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0], fine_detail=1.0)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
