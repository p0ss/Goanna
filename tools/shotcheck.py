#!/usr/bin/env python3
"""Check what a test screenshot actually contains before reading numbers off it.

A shot taken before the world streamed in is a photograph of the sky, and it
looks exactly like a render with the feature under test switched off. Both
Goanna sessions have drawn a confident conclusion from one: an inverted
normal map hid behind it for a day, a jungle canopy was measured and reported
as snow, an autojump was verified against a character swimming in the ocean,
and rain was checked against a sky holding no storm.

None of that is caught by looking at whether the file exists, and reviewing
every frame by eye does not scale. So measure the frame first, and only
believe a reading once the frame is the one you meant to take.

Usage:
    tools/shotcheck.py shot.png [shot2.png ...]
    tools/shotcheck.py --expect terrain shot.png     # non-zero exit if not
    tools/shotcheck.py --compare a.png b.png         # same framing?
    tools/shotcheck.py --walk-series lighting_walk_*.png

Checks are deliberately crude. They answer "is this the scene I think it is",
not "is it correct".
"""

import argparse
import json
import math
import sys

try:
    from PIL import Image
    import numpy as np
except ImportError:
    sys.exit("needs Pillow and numpy: pip install pillow numpy")


def describe(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=float)
    h, w, _ = a.shape
    lum = a.mean(axis=2)
    top, bottom = a[: h // 3], a[2 * h // 3 :]
    # Sky is smooth and blue: little local variation, blue above red.
    sky_flat = float(top.mean(axis=2).std())
    blue_excess = float(top[:, :, 2].mean() - top[:, :, 0].mean())
    # A frame with nothing in it is smooth all the way down.
    empty = float(lum.std()) < 12.0 and blue_excess > 4.0
    green_excess = float(bottom[:, :, 1].mean() - (bottom[:, :, 0].mean() + bottom[:, :, 2].mean()) / 2)
    return {
        "size": "%dx%d" % (w, h),
        "mean": float(lum.mean()),
        "detail": float(lum.std()),
        "clipped": float((lum >= 250).mean() * 100),
        "black": float((lum <= 4).mean() * 100),
        "sky_flatness": sky_flat,
        "green_excess": green_excess,
        "empty": empty,
    }


def classify(d):
    """A guess at what is in frame, good enough to catch the usual mistake."""
    if d["empty"]:
        return "empty sky (nothing streamed in)"
    if d["green_excess"] > 6.0:
        return "vegetation, so a natural world rather than a built scene"
    if d["black"] > 40.0:
        return "mostly black, so underground, night or badly unlit"
    return "terrain or built scene"


def centre_luminance(path):
    """Mean luminance of the stable centre region used by walking fixtures."""
    a = np.asarray(Image.open(path).convert("RGB"), dtype=float)
    h, w, _ = a.shape
    centre = a[h // 5: h * 4 // 5, w // 5: w * 4 // 5]
    return float((centre[:, :, 0] * 0.2126 + centre[:, :, 1] * 0.7152
            + centre[:, :, 2] * 0.0722).mean())


def local_detail(path):
    """A crude proxy for shading variation across a nearby surface: the
    standard deviation of a Laplacian over the frame's centre quarter. A
    flat-lit or blank frame is near zero; a lit, bumped material is not.
    This cannot tell a normal map's relief from the albedo's own pattern, so
    it is evidence that materials are engaging at close range, not proof the
    normal map specifically is what produced it."""
    a = np.asarray(Image.open(path).convert("L"), dtype=float)
    h, w = a.shape
    c = a[h // 4: h * 3 // 4, w // 4: w * 3 // 4]
    lap = -4 * c[1:-1, 1:-1] + c[:-2, 1:-1] + c[2:, 1:-1] + c[1:-1, :-2] + c[1:-1, 2:]
    return float(lap.std())


def band_detail(path, top, bottom):
    """The same Laplacian standard deviation as local_detail, over a
    horizontal band of the frame (top and bottom as fractions of height, full
    width) instead of the centre quarter. Used to read the far band of a
    horizon shot, docs/far-rendering.md task 2c: a tile that still repeats
    once per node at the range a merged region quad is actually seen from
    aliases into a per-pixel shimmer, which this measures as high local
    variance even though the frame is otherwise an ordinary lit scene, not a
    synthetic pattern. A flat, blended-to-average surface (correct) reads
    close to the sky's own near-zero value; ordinary terrain detail sits well
    below what aliasing produces because distance has already minified it."""
    a = np.asarray(Image.open(path).convert("L"), dtype=float)
    h, w = a.shape
    c = a[int(h * top): int(h * bottom)]
    if c.shape[0] < 3:
        return 0.0
    lap = -4 * c[1:-1, 1:-1] + c[:-2, 1:-1] + c[2:, 1:-1] + c[1:-1, :-2] + c[1:-1, 2:]
    return float(lap.std())


def _row_for_elevation(pitch_deg, fov_deg, elevation_deg):
    """Fraction of image height (0 at the top) where a ray at `elevation_deg`
    from horizontal (positive is up, matching main.gd's own
    `pitch = rad_to_deg(asin(d.y))`) crosses the frame, given the camera's
    boresight `pitch_deg` and its vertical `fov_deg` (`Camera3D.fov` under
    `KEEP_ASPECT_HEIGHT`, which is what `main.gd` leaves it at). None if that
    ray is outside the frame altogether.

    This is a plain symmetric perspective projection: the screen offset from
    the boresight goes as the tangent of the angle off it, scaled by the
    tangent of the half vertical fov. Checked on this machine against the
    real camera (`cam.project_ray_normal` at the row this returns lands
    within a node of the ground distance it was asked for; see the R4 entry
    in docs/launch-target.md for the numbers)."""
    if fov_deg is None or fov_deg <= 0 or elevation_deg is None:
        return None
    theta_deg = elevation_deg - pitch_deg
    if abs(theta_deg) >= 90.0:
        return None
    tan_half = math.tan(math.radians(fov_deg / 2.0))
    if tan_half <= 0:
        return None
    ndc_y = math.tan(math.radians(theta_deg)) / tan_half
    v = (1.0 - ndc_y) / 2.0
    if v < 0.0 or v > 1.0:
        return None
    return v


def horizon_boundary_row(pitch_deg, fov_deg, eye_height, target_distance):
    """Row (as a fraction of image height) where a flat ground plane
    `target_distance` nodes out crosses the frame, given the camera's
    `eye_height` above that plane. This is the live/far boundary row for
    docs/launch-target.md's R4 continuity check, with `target_distance` the
    live range (`view_range` blocks * 16). None if the boundary is not
    visible in this frame, most often because the camera is pitched above
    the horizon."""
    if eye_height is None or target_distance is None or eye_height <= 0 or target_distance <= 0:
        return None
    elevation_deg = -math.degrees(math.atan2(eye_height, target_distance))
    return _row_for_elevation(pitch_deg, fov_deg, elevation_deg)


def horizon_row(pitch_deg, fov_deg):
    """Row (as a fraction of image height) where the true horizon, ground at
    infinite distance, crosses the frame: the top edge of the far band, above
    which nothing but sky can appear regardless of draw distance."""
    return _row_for_elevation(pitch_deg, fov_deg, 0.0)


def band_luma_chroma(arr, top_frac, bottom_frac):
    """Mean luminance and mean chroma (the average of |R-G| and |G-B|, a
    crude but sensible measure: it is near zero for a neutral grey or a
    single hue shaded by sun and sky alone, and rises with per tier colour
    that does not belong) of a horizontal band, full width, given as
    fractions of image height, of an HxWx3 float RGB array. None if fewer
    than two rows survive clipping to the image."""
    h = arr.shape[0]
    top = max(0, min(h, int(round(top_frac * h))))
    bottom = max(0, min(h, int(round(bottom_frac * h))))
    if bottom - top < 2:
        return None
    band = arr[top:bottom]
    r, g, b = band[:, :, 0], band[:, :, 1], band[:, :, 2]
    lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    chroma = (np.abs(r - g) + np.abs(g - b)) / 2.0
    return {"rows": [top, bottom], "luminance": float(lum.mean()), "chroma": float(chroma.mean())}


def _far_geometry(meta):
    """Everything docs/launch-target.md's R4 continuity and pop checks need
    to place the live/far boundary and the horizon on a horizon shot: the
    camera's pitch and vertical fov, its height above the ground the harness
    found under the player, and the live range in nodes (view_range * 16).
    Returns (geometry, None) or (None, reason) if the settings JSON predates
    one of these fields, or the boundary is not in this frame at all."""
    horizon_shot = meta.get("horizon_shot", {})
    ground = meta.get("ground", {})
    settings = meta.get("settings", {})
    pitch = horizon_shot.get("pitch")
    camera = horizon_shot.get("camera")
    fov = settings.get("fov", {}).get("value")
    view_range = settings.get("view_range", {}).get("value")
    ground_y = ground.get("y")
    if None in (pitch, camera, fov, view_range, ground_y):
        return None, ("missing pose, fov, view_range or ground in the settings JSON "
                "(an older harness run)")
    eye_height = float(camera[1]) - float(ground_y)
    target_distance = float(view_range) * 16.0
    v_boundary = horizon_boundary_row(float(pitch), float(fov), eye_height, target_distance)
    v_horizon = horizon_row(float(pitch), float(fov))
    if v_boundary is None or v_horizon is None:
        return None, "the live/far boundary is not in this frame (camera pitched above the horizon?)"
    return {
        "pitch": float(pitch), "fov": float(fov), "eye_height": eye_height,
        "target_distance": target_distance,
        "v_boundary": v_boundary, "v_horizon": v_horizon,
    }, None


def continuity_check(horizon_path, v_boundary, band_frac):
    """docs/launch-target.md R4: the mean luminance and mean chroma of a
    band just inside the live/far boundary (closer than it, still live)
    against a band just outside it (past it, in the far tiers), on the one
    horizon shot. One light, one air says these should read the same; a per
    tier tint or brightness shift shows up as a difference between them."""
    arr = np.asarray(Image.open(horizon_path).convert("RGB"), dtype=float)
    inside = band_luma_chroma(arr, v_boundary, v_boundary + band_frac)
    outside = band_luma_chroma(arr, v_boundary - band_frac, v_boundary)
    if inside is None or outside is None:
        return None
    return {
        "inside": inside, "outside": outside,
        "luminance_diff": abs(inside["luminance"] - outside["luminance"]),
        "chroma_diff": abs(inside["chroma"] - outside["chroma"]),
    }


def pop_fraction_series(paths, top_frac, bottom_frac, change):
    """docs/launch-target.md R4's pop metric: the fraction of pixels in a
    horizontal band (full width, the far band between the horizon and the
    live/far boundary) whose luminance moves by more than `change` between
    each consecutive pair of frames in `paths`, a burst taken with the
    camera standing still. A dither fade spreads a change over many frames
    and keeps every one of these small; a cell popping in or out changes its
    whole area in a single frame and shows as a spike."""
    frames = []
    for p in paths:
        a = np.asarray(Image.open(p).convert("L"), dtype=float)
        h, w = a.shape
        top = max(0, min(h, int(round(top_frac * h))))
        bottom = max(0, min(h, int(round(bottom_frac * h))))
        frames.append(a[top:bottom])
    fractions = []
    for i in range(1, len(frames)):
        if frames[i].shape != frames[i - 1].shape or frames[i].size == 0:
            continue
        fractions.append(float((np.abs(frames[i] - frames[i - 1]) > change).mean()))
    return fractions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="+")
    ap.add_argument("--expect", choices=["terrain", "vegetation", "any"], default="any",
            help="exit non-zero if the frame does not look like this")
    ap.add_argument("--compare", action="store_true",
            help="report whether two shots share a framing, so a diff means something")
    ap.add_argument("--walk-series", action="store_true",
            help="report adjacent centre-luminance changes along a fixed-facing path")
    ap.add_argument("--max-step", type=float,
            help="with --walk-series, fail if an adjacent luminance step exceeds this")
    ap.add_argument("--launch-target", action="store_true",
            help="check docs/launch-target.md task 1's pair: a horizon shot and a wall "
                 "shot, plus --settings, the JSON of settings and render_stats the "
                 "harness wrote beside them. Also runs R4's continuity and pop checks "
                 "when the settings JSON carries the pose and burst frames for them")
    ap.add_argument("--settings", help="the settings.json tools/test-launch-target.sh wrote")
    ap.add_argument("--far-cells-min", type=int, default=500,
            help="with --launch-target, minimum render_stats().far_remote (default 500)")
    ap.add_argument("--normal-detail-min", type=float, default=5.0,
            help="with --launch-target, minimum local_detail() on the wall shot, when "
                 "auto_bump is on (default 5.0)")
    ap.add_argument("--continuity-band-frac", type=float, default=0.03,
            help="with --launch-target, docs/launch-target.md R4: half width, as a fraction "
                 "of frame height, of the band read just inside and just outside the live/far "
                 "boundary row on the horizon shot (default 0.03)")
    ap.add_argument("--continuity-luminance-max", type=float, default=8.0,
            help="with --launch-target, R4: maximum mean luminance difference (0-255) between "
                 "the band just inside the live/far boundary and the band just outside it "
                 "(default 8.0, see docs/launch-target.md R4 for how this was chosen)")
    ap.add_argument("--continuity-chroma-max", type=float, default=3.0,
            help="with --launch-target, R4: maximum mean chroma difference between the same "
                 "two bands (default 3.0)")
    ap.add_argument("--pop-change-threshold", type=float, default=10.0,
            help="with --launch-target, R4: a pixel's luminance has to move by more than this "
                 "(0-255) between two burst frames to count as changed (default 10.0)")
    ap.add_argument("--pop-max-fraction", type=float, default=0.01,
            help="with --launch-target, R4: maximum fraction of far-band pixels allowed to "
                 "change in any single frame of the standing-still burst (default 0.01)")
    ap.add_argument("--far-band", action="store_true",
            help="check a horizon shot's far band (docs/far-rendering.md task 2c): fails "
                 "if a merged region quad, water included, still aliases into a shimmer "
                 "at the range it is actually seen from")
    ap.add_argument("--far-band-top", type=float, default=0.40,
            help="with --far-band, top of the band as a fraction of frame height (default 0.40)")
    ap.add_argument("--far-band-bottom", type=float, default=0.60,
            help="with --far-band, bottom of the band as a fraction of frame height (default 0.60)")
    ap.add_argument("--far-band-max", type=float, default=9.0,
            help="with --far-band, maximum band_detail() before it reads as aliasing "
                 "rather than ordinary, already-distant terrain detail (default 9.0)")
    args = ap.parse_args()

    rows = [(p, describe(p)) for p in args.images]
    for p, d in rows:
        print("%s\n  %s  mean %.1f  detail %.1f  clipped %.1f%%  black %.1f%%\n  looks like: %s"
                % (p, d["size"], d["mean"], d["detail"], d["clipped"], d["black"], classify(d)))

    bad = 0
    if args.expect != "any":
        for p, d in rows:
            got = classify(d)
            ok = (args.expect == "vegetation" and "vegetation" in got) or (
                    args.expect == "terrain" and got.startswith("terrain"))
            if not ok:
                print("FAIL %s: wanted %s, got %s" % (p, args.expect, got), file=sys.stderr)
                bad += 1

    if args.compare and len(rows) == 2:
        a = np.asarray(Image.open(rows[0][0]).convert("L"), dtype=float)
        b = np.asarray(Image.open(rows[1][0]).convert("L"), dtype=float)
        if a.shape != b.shape:
            print("FAIL different sizes, not comparable", file=sys.stderr)
            bad += 1
        else:
            # Moving the camera shifts where things are; changing the
            # exposure does not. So compare coarse structure, normalised per
            # image. Counting edges instead fails on the comparison we make
            # most, because a blown out region has no edges to count.
            def coarse(img):
                h2, w2 = 18, 32
                small = img[: (img.shape[0] // h2) * h2, : (img.shape[1] // w2) * w2]
                small = small.reshape(h2, -1, w2, small.shape[1] // w2).mean(axis=(1, 3))
                return (small - small.mean()) / max(small.std(), 1e-6)
            ca, cb = coarse(a), coarse(b)
            agree = float(np.corrcoef(ca.ravel(), cb.ravel())[0, 1] * 100)
            print("framing: structure correlates %.0f%%" % agree)
            if agree < 85.0:
                print("FAIL the camera moved between these, a pixel diff means nothing",
                        file=sys.stderr)
                bad += 1

    if args.walk_series:
        if len(rows) < 3:
            print("FAIL a walking series needs at least three frames", file=sys.stderr)
            bad += 1
        else:
            values = [centre_luminance(p) for p, _ in rows]
            steps = [abs(values[i] - values[i - 1]) for i in range(1, len(values))]
            print("walking centre luminance:")
            for i, ((path, _), value) in enumerate(zip(rows, values)):
                change = "" if i == 0 else "  step %+.2f" % (value - values[i - 1])
                print("  %s  %.2f%s" % (path, value, change))
            worst = max(steps)
            typical = float(np.median(steps))
            ratio = worst / max(typical, 0.01)
            print("walking steps: typical %.2f, worst %.2f, worst/typical %.2f"
                    % (typical, worst, ratio))
            if args.max_step is not None and worst > args.max_step:
                print("FAIL worst luminance step %.2f exceeds %.2f"
                        % (worst, args.max_step), file=sys.stderr)
                bad += 1

    if args.far_band:
        for p, _ in rows:
            detail = band_detail(p, args.far_band_top, args.far_band_bottom)
            ok = detail <= args.far_band_max
            print("far band: %s: %s detail %.2f, wanted at most %.2f"
                    % ("PASS" if ok else "FAIL", p, detail, args.far_band_max))
            if not ok:
                bad += 1

    if args.launch_target:
        if not args.settings:
            print("FAIL --launch-target needs --settings <path>", file=sys.stderr)
            bad += 1
        elif len(args.images) != 2:
            print("FAIL --launch-target wants exactly two images: the horizon shot "
                    "then the wall shot", file=sys.stderr)
            bad += 1
        else:
            horizon_path, wall_path = args.images
            with open(args.settings) as f:
                meta = json.load(f)

            far_remote = meta.get("render_stats", {}).get("far_remote", 0)
            far_ok = far_remote >= args.far_cells_min
            print("launch target: %s: far cells %d, wanted at least %d"
                    % ("PASS" if far_ok else "FAIL", far_remote, args.far_cells_min))
            if not far_ok:
                bad += 1

            auto_bump = meta.get("settings", {}).get("auto_bump", {}).get("value", 0.0)
            if auto_bump <= 0.0:
                print("launch target: SKIP: normal map response (auto_bump is off)")
            else:
                detail = local_detail(wall_path)
                normal_ok = detail >= args.normal_detail_min
                print("launch target: %s: normal map response, close shot detail %.2f, "
                        "wanted at least %.2f" % ("PASS" if normal_ok else "FAIL",
                        detail, args.normal_detail_min))
                if not normal_ok:
                    bad += 1

            shader_pack = meta.get("shader_pack", "")
            if not shader_pack:
                print("launch target: SKIP: shader pack final pass (no pack active)")
            else:
                # The same crude mark shaderpack_check.py looks for on the proof pack's
                # composite: a flat identity pass leaves the frame smooth, a real final
                # pass (fog, bloom, tonemap) does not.
                frame_std = describe(horizon_path)["detail"]
                pack_ok = frame_std > 8.0
                print("launch target: %s: shader pack final pass, horizon frame detail %.2f"
                        % ("PASS" if pack_ok else "FAIL", frame_std))
                if not pack_ok:
                    bad += 1

            # R4, docs/launch-target.md: continuity across the live/far boundary, and a
            # pop metric, both needing the pose and (for the pop metric) the burst frames
            # tools/test-launch-target.sh writes into the settings JSON alongside the two
            # shots task 1 already takes.
            geom, geom_err = _far_geometry(meta)
            if geom is None:
                print("launch target: SKIP: continuity and pop (%s)" % geom_err)
            else:
                cont = continuity_check(horizon_path, geom["v_boundary"], args.continuity_band_frac)
                if cont is None:
                    print("launch target: FAIL: continuity band fell outside the frame",
                            file=sys.stderr)
                    bad += 1
                else:
                    lum_ok = cont["luminance_diff"] <= args.continuity_luminance_max
                    chroma_ok = cont["chroma_diff"] <= args.continuity_chroma_max
                    img_h = Image.open(horizon_path).height
                    print("continuity: boundary row %d of %d (%.0f nodes out, eye height "
                            "%.1f): inside luminance %.2f chroma %.2f, outside luminance %.2f "
                            "chroma %.2f"
                            % (int(round(geom["v_boundary"] * img_h)), img_h,
                                geom["target_distance"], geom["eye_height"],
                                cont["inside"]["luminance"], cont["inside"]["chroma"],
                                cont["outside"]["luminance"], cont["outside"]["chroma"]))
                    print("continuity: luminance diff %.2f (wanted at most %.2f), chroma diff "
                            "%.2f (wanted at most %.2f)"
                            % (cont["luminance_diff"], args.continuity_luminance_max,
                                cont["chroma_diff"], args.continuity_chroma_max))
                    print("launch target: %s: continuity"
                            % ("PASS" if (lum_ok and chroma_ok) else "FAIL"))
                    if not (lum_ok and chroma_ok):
                        bad += 1

                pop_frames = meta.get("pop_frames", [])
                if len(pop_frames) < 2:
                    print("launch target: SKIP: pop metric (fewer than two burst frames in "
                            "the settings JSON)")
                else:
                    fractions = pop_fraction_series(pop_frames, geom["v_horizon"],
                            geom["v_boundary"], args.pop_change_threshold)
                    if not fractions:
                        print("launch target: FAIL: pop metric could not compare the burst "
                                "frames (sizes did not match)", file=sys.stderr)
                        bad += 1
                    else:
                        worst = max(fractions)
                        print("pop: far band, %d frame pairs, changed fraction per pair: %s"
                                % (len(fractions), ", ".join("%.3f" % f for f in fractions)))
                        pop_ok = worst <= args.pop_max_fraction
                        print("launch target: %s: pop, worst frame changed fraction %.3f, "
                                "wanted at most %.3f"
                                % ("PASS" if pop_ok else "FAIL", worst, args.pop_max_fraction))
                        if not pop_ok:
                            bad += 1

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
