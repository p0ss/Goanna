#!/usr/bin/env python3
"""Reject mechanically valid but materially implausible PBR maps.

Covers both producers. A directory can hold either, or a mix of the two: an
authored set is installed over a bake, stem by stem, by
tools/pbr_author/build_pack.py. Each map says which wrote it (PIPELINE_KEY),
and only the height rules differ between them.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import pbr_bake


# tools/pbr_author/lib.py stamps every map it writes with this PNG text
# chunk. The two pipelines put different things in the _n alpha, so the gate
# has to know which it is holding before it can measure the height at all:
#
#   baked     tools/pbr_bake.py, pack_deepbump_normal, line 826:
#             255 - (1 - normalised) * depth * 255. The top of the byte is the
#             neutral surface and the field occupies the class's share of the
#             range below it, so max is 255 and the span is CLASS_HEIGHT_DEPTH.
#   authored  tools/pbr_author/lib.py, pack, line 420: the author's 0 deep to
#             1 high field straight into the byte. Neither end is reserved,
#             and the depth is applied at draw time instead, by
#             goanna_class_depth in nodes_array_common.gdshaderinc.
#
# Nothing else about a map differs, so only the height rules split.
PIPELINE_KEY = "goanna_pipeline"
AUTHORED = "authored"
BAKED = "baked"


def pipeline_of(path):
    """Which tool wrote this map, from the marker it left, or "baked".

    Read from the file rather than inferred from the pixels: an authored
    height field that happens to reach 255 and a baked one are the same
    bytes, and a guess would move the baked gate about as art changed.
    """
    with Image.open(path) as image:
        return AUTHORED if image.info.get(PIPELINE_KEY) == AUTHORED else BAKED


def texture_classes(path):
    return pbr_bake.load_classes(path) if path else {}


def source_index(root):
    result = {}
    if not root:
        return result
    for path in sorted(Path(root).rglob("*.png")):
        result.setdefault(path.stem, path)
    return result


def seam_energy(array):
    rgb = array[..., :3].astype(float)
    wrap = np.abs(rgb[0] - rgb[-1]).mean() + np.abs(rgb[:, 0] - rgb[:, -1]).mean()
    inner = np.abs(rgb[0] - rgb[1]).mean() + np.abs(rgb[:, 0] - rgb[:, 1]).mean()
    return float(wrap / max(inner, 1e-6))


def visible_mask(src_alpha, shape):
    """Which texels of a map the source actually authored.

    An all-transparent source would leave nothing to measure, so that falls
    back to the whole image rather than reporting on an empty selection.
    """
    if src_alpha is None:
        return np.ones(shape, dtype=bool)
    resized = Image.fromarray(src_alpha).resize(
        (shape[1], shape[0]), Image.Resampling.NEAREST)
    mask = np.asarray(resized) >= 128
    return mask if mask.any() else np.ones(shape, dtype=bool)


def inspect(stem, normal_path, spec_path, material, source=None, albedo=None,
            review=None, pipeline=None):
    failures, warnings = [], []
    pipeline = pipeline or pipeline_of(normal_path)
    normal = np.asarray(Image.open(normal_path).convert("RGBA"))
    spec = np.asarray(Image.open(spec_path).convert("RGBA"))
    xy = normal[..., :2].astype(float) / 127.5 - 1.0
    slope = np.linalg.norm(xy, axis=2)
    height = normal[..., 3].astype(float)
    smooth = spec[..., 0].astype(float) / 255.0
    # LabPBR splits the _s green byte at 230: 0 to 229 is a dielectric's
    # linear F0, 230 to 255 indexes the metal table. Both producers hold
    # dielectrics at or below 229 (pbr_bake.write_class_spec clamps there,
    # tools/pbr_author/lib.py's pack clips its per texel F0 there), so a byte
    # of exactly 229 is the top of the dielectric range and not a metal. It
    # read as one here, which called kythen_norse_bog_ore's ochre metallic.
    # Nothing baked is affected: pack_hybrid_spec and pack_chord_maps write
    # only 10 or 255 into this byte.
    metal = spec[..., 1] >= 230
    review = review or {}
    # Transparent texels hold the neutral fill mask_transparent_regions wrote,
    # not material. NEUTRAL_S is smoother than a foliage sprite's reviewed
    # maximum on its own, so averaging a billboard that is 70 per cent
    # transparent over the whole image measures the fill and rejects art that
    # is inside its band everywhere it exists. The colour drift check below
    # has always sampled only the visible texels; these statistics now do the
    # same. Fully opaque terrain art is unaffected.
    src_alpha = None
    if source:
        alpha = np.asarray(Image.open(source).convert("RGBA"))[..., 3]
        if (alpha < 128).any():
            src_alpha = alpha
    # The normal map and the spec map need their own masks: a flat class spec
    # is FLAT_SPEC_SIZE whatever the normal's resolution is.
    visible_n = visible_mask(src_alpha, normal.shape[:2])
    visible_s = visible_mask(src_alpha, spec.shape[:2])
    height_v = height[visible_n]
    slope_v = slope[visible_n]
    smooth_v = smooth[visible_s]
    metal_v = metal[visible_s]
    xy_v = xy[visible_n]
    expected_depth = float(review.get("relief_strength",
        pbr_bake.CLASS_HEIGHT_DEPTH.get(
            material, pbr_bake.DEFAULT_HEIGHT_DEPTH))) * 255.0
    height_span = float(np.percentile(height_v, 98) - np.percentile(height_v, 2))
    authored = pipeline == AUTHORED
    metrics = {
        "height_span": height_span,
        "height_rail_fraction": float(
            ((height_v <= 0.0) | (height_v >= 255.0)).mean()),
        "mean_smoothness": float(smooth_v.mean()),
        "metal_fraction": float(metal_v.mean()),
        "normal_slope_p95": float(np.percentile(slope_v, 95)),
        "normal_xy_bias": float(np.linalg.norm(xy_v.mean(axis=0))),
        "seam_energy": seam_energy(normal),
    }
    if metrics["normal_slope_p95"] > 1.02:
        failures.append("normal XY leaves the unit hemisphere")
    if metrics["normal_xy_bias"] > 0.22:
        failures.append("normal field has a strong directional bias")
    if authored:
        # The authored field owns the whole byte on purpose, so neither the
        # neutral 255 reference nor the class depth envelope means anything
        # here: lib.band deliberately holds a cast slab inside a few per cent
        # about the middle, and lib.normalise01 deliberately fills the range,
        # and both come out as the class's depth once the shader scales them.
        # What is still true of a usable authored field is that it has not
        # run off either end of the byte, which is where relief is lost and
        # cannot be recovered.
        if metrics["height_rail_fraction"] > 0.35:
            failures.append("authored height is crushed against the byte rails")
    else:
        if height_v.max() < 245:
            failures.append("height has no neutral/high reference")
        if height_span > expected_depth + 12:
            failures.append("height exceeds the material depth envelope")
    # A height that says nothing where the normal says there is relief is a
    # packing fault either way. The baked floor scales with the envelope the
    # bake wrote to; an authored field has no envelope, so it only has to
    # carry more than rounding.
    flat_floor = 4.0 if authored else min(8.0, expected_depth * 0.15)
    if slope_v.std() > 0.02 and height_span < flat_floor:
        failures.append("height is effectively flat despite normal relief")
    max_smooth = review.get("smoothness_max", {"stone": 0.25, "soil": 0.18, "sand": 0.20,
                  "gravel": 0.22, "wood": 0.36, "cloth": 0.22,
                  "leaves": 0.42, "metal": 0.62}.get(material, 0.65))
    if metrics["mean_smoothness"] > max_smooth and material not in ("glass", "ice"):
        failures.append("surface is too smooth for material class %s" % material)
    # Opposite edges only need to meet on art that repeats. Warning that a
    # plant sprite's left and right edges differ describes the sprite, not a
    # defect: it was 190 of the warnings across the two billboard tranches,
    # every one of them on a texture the review marks as not tiling.
    if metrics["seam_energy"] > 3.0 and review.get("tiles") is not False:
        warnings.append("visible wrap seam likely")
    if source:
        src = np.asarray(Image.open(source).convert("RGBA"))
        opaque = src[..., 3] >= 128
        if metal_v.any() and opaque.any():
            rgb = src[..., :3].astype(float) / 255.0
            lum = (rgb * (0.2126, 0.7152, 0.0722)).sum(axis=2)
            metrics["source_luminance"] = float(lum[opaque].mean())
            # A reviewed metal or mixed object is allowed to be dark: a musket,
            # a flashlight and flint and steel are all metal drawn in dark
            # pixels, and rejecting them measures the art's palette rather than
            # its material. The rule still bites where the review calls
            # something glass or stone and Chord found metal in it anyway,
            # which is the wet-stone false positive it was written for.
            reviewed_metal = (review.get("metalness_policy") in
                              ("partial", "predominant")
                              and review.get("primary_material") in
                              ("metal", "mixed"))
            if metrics["source_luminance"] < 0.35:
                if reviewed_metal:
                    warnings.append("dark art carries reviewed metalness")
                else:
                    failures.append(
                        "dark diffuse-authored art was marked metallic")
        if (~opaque).any():
            alpha = Image.fromarray(src[..., 3]).resize(
                (normal.shape[1], normal.shape[0]), Image.Resampling.NEAREST)
            transparent = np.asarray(alpha) < 128
            neutral = np.array((128, 128, 255, 255), dtype=np.uint8)
            if transparent.any() and not np.all(normal[transparent] == neutral):
                failures.append("transparent pixels are not neutral in the normal map")
    if source and albedo:
        src = Image.open(source).convert("RGBA").resize(
            Image.open(albedo).size, Image.Resampling.NEAREST)
        src_rgba = np.asarray(src)
        opaque = src_rgba[..., 3] >= 128
        a = src_rgba[..., :3].astype(float) / 255.0
        b = np.asarray(Image.open(albedo).convert("RGB"), dtype=float) / 255.0
        # Transparent RGB is padding, not visible art.  Comparing it penalises
        # overlays (ores, glass details, litter sides) for colours that never
        # reach the framebuffer, so measure only the authored visible texels.
        sample = opaque if opaque.any() else np.ones(opaque.shape, dtype=bool)
        drift = np.abs(a[sample].mean(axis=0) - b[sample].mean(axis=0)).mean()
        metrics["mean_colour_drift"] = float(drift)
        if drift > 0.12:
            failures.append("generated albedo has excessive mean colour drift")
    return {"stem": stem, "material": material, "pipeline": pipeline,
            "metrics": metrics, "failures": failures, "warnings": warnings}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baked", required=True)
    parser.add_argument("--nodedefs")
    parser.add_argument("--sources")
    parser.add_argument("--classification-review")
    parser.add_argument("--json")
    args = parser.parse_args()
    baked = Path(args.baked)
    classes = texture_classes(args.nodedefs)
    sources = source_index(args.sources)
    reviews = pbr_bake.load_classification_review(
        args.classification_review, set(classes) | set(sources))
    for stem, review in reviews.items():
        if review.get("primary_material"):
            classes[stem] = pbr_bake.physical_class(review["primary_material"])
    reports = []
    for normal in sorted(baked.glob("*_n.png")):
        stem = normal.name[:-len("_n.png")]
        spec = baked / (stem + "_s.png")
        if not spec.exists():
            reports.append({"stem": stem, "material": classes.get(stem),
                            "pipeline": pipeline_of(normal), "metrics": {},
                            "failures": ["missing material map"],
                            "warnings": []})
            continue
        albedo = baked / (stem + "_albedo.png")
        reports.append(inspect(stem, normal, spec, classes.get(stem),
                               sources.get(stem), albedo if albedo.exists() else None,
                               reviews.get(stem)))
    failures = sum(bool(item["failures"]) for item in reports)
    warnings = sum(bool(item["warnings"]) for item in reports)
    authored = sum(item["pipeline"] == AUTHORED for item in reports)
    summary = {"checked": len(reports), "failed": failures,
               "warned": warnings, "authored": authored, "textures": reports}
    if args.json:
        Path(args.json).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    for item in reports:
        for message in item["failures"]:
            print("FAIL %s: %s" % (item["stem"], message))
        for message in item["warnings"]:
            print("WARN %s: %s" % (item["stem"], message))
    print("PBR quality: %d checked (%d authored, %d baked), %d failed, %d warned" %
          (len(reports), authored, len(reports) - authored, failures, warnings))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
