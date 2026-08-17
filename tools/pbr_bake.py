#!/usr/bin/env python3
"""Bake PBR companions for a Luanti game's textures.

Pack matching against a Minecraft pack tops out near 20 per cent coverage,
because most of what a Luanti game ships has no Minecraft equivalent and no
pack will ever cover it. This derives the maps from the game's own textures
instead, so coverage is total and the result is aligned to the art by
construction.

    16 px texture
      -> replicate 3x3, so the generated detail is seamless (see below)
      -> upscale with tile ControlNet in ComfyUI, which keeps the structure
      -> crop the centre tile
      -> DeepBump colour to normals, which needs the resolution to say
         anything: on a raw 16 px tile it returns a nearly flat map
      -> <name>_n.png beside the texture, LabPBR channel order

Tileability is not optional. Every block texture repeats across thousands of
nodes, and a visible seam on each one is worse than no relief at all. Rather
than depend on a circular padding node, the input is replicated three by
three and the centre is cropped out afterwards: the centre tile's edges are
then generated with its own neighbours present, so they line up.

Needs ComfyUI running (see comfyui/GOANNA-SETUP.md) and DeepBump checked out.

    tools/pbr_bake.py --game ~/.minetest/games/mineclonia --out /tmp/baked
    tools/pbr_bake.py --game ... --out ... --only default_stone,default_dirt
"""

import argparse
import io
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow: pip install pillow")

DEEPBUMP = os.path.expanduser("~/Documents/Code/deepbump")
COMFY_VENV = os.path.expanduser("~/Documents/Code/comfyui/.venv/bin/python")

# Deliberately plain. The tile ControlNet is carrying the structure, the
# palette and the layout; the prompt only has to stop the model wandering off
# into photography.
PROMPT = ("seamless tiling game texture, flat lighting, even illumination, "
        "sharp detail, material surface")
NEGATIVE = ("blurry, soft focus, vignette, shadow, drop shadow, gradient "
        "background, text, watermark, border, frame, perspective, 3d render")


def post(server, path, payload):
    req = urllib.request.Request(server + path,
            data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def get(server, path):
    with urllib.request.urlopen(server + path) as r:
        return json.loads(r.read())


def upload_image(server, img, name):
    """Push a PIL image into ComfyUI's input folder."""
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    body = []
    boundary = "----goannabake"
    body.append(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"image\"; "
            "filename=\"" + name + "\"\r\nContent-Type: image/png\r\n\r\n").encode())
    body.append(buf.getvalue())
    body.append(("\r\n--" + boundary + "\r\nContent-Disposition: form-data; "
            "name=\"overwrite\"\r\n\r\ntrue\r\n--" + boundary + "--\r\n").encode())
    data = b"".join(body)
    req = urllib.request.Request(server + "/upload/image", data=data,
            headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())["name"]


def workflow(image_name, ckpt, controlnet, size, denoise, strength, steps, seed):
    """The API graph: img2img at low denoise, steered by tile ControlNet.

    Low denoise plus tile conditioning is what makes this an upscale rather
    than a generation: the output has to stay the same texture, only with
    detail that was not resolvable at 16 px.
    """
    return {
        "1": {"class_type": "CheckpointLoaderSimple",
              "inputs": {"ckpt_name": ckpt}},
        "2": {"class_type": "LoadImage",
              "inputs": {"image": image_name}},
        # nearest, so the control signal keeps the hard pixel edges that carry
        # the texture's identity rather than a smeared interpolation
        "3": {"class_type": "ImageScale",
              "inputs": {"image": ["2", 0], "upscale_method": "nearest-exact",
                         "width": size, "height": size, "crop": "disabled"}},
        "4": {"class_type": "CLIPTextEncode",
              "inputs": {"text": PROMPT, "clip": ["1", 1]}},
        "5": {"class_type": "CLIPTextEncode",
              "inputs": {"text": NEGATIVE, "clip": ["1", 1]}},
        "6": {"class_type": "ControlNetLoader",
              "inputs": {"control_net_name": controlnet}},
        "7": {"class_type": "ControlNetApplyAdvanced",
              "inputs": {"positive": ["4", 0], "negative": ["5", 0],
                         "control_net": ["6", 0], "image": ["3", 0],
                         "strength": strength, "start_percent": 0.0,
                         "end_percent": 1.0}},
        "8": {"class_type": "VAEEncode",
              "inputs": {"pixels": ["3", 0], "vae": ["1", 2]}},
        "9": {"class_type": "KSampler",
              "inputs": {"model": ["1", 0], "seed": seed, "steps": steps,
                         "cfg": 5.0, "sampler_name": "dpmpp_2m",
                         "scheduler": "karras", "positive": ["7", 0],
                         "negative": ["7", 1], "latent_image": ["8", 0],
                         "denoise": denoise}},
        "10": {"class_type": "VAEDecode",
               "inputs": {"samples": ["9", 0], "vae": ["1", 2]}},
        "11": {"class_type": "SaveImage",
               "inputs": {"images": ["10", 0], "filename_prefix": "goanna_bake"}},
    }


def run_workflow(server, wf, timeout=300):
    pid = post(server, "/prompt", {"prompt": wf})["prompt_id"]
    t0 = time.time()
    while time.time() - t0 < timeout:
        hist = get(server, "/history/" + pid)
        if pid in hist:
            outs = hist[pid]["outputs"]
            for node in outs.values():
                for im in node.get("images", []):
                    q = urllib.parse.urlencode(
                            {"filename": im["filename"], "subfolder": im.get("subfolder", ""),
                             "type": im.get("type", "output")})
                    with urllib.request.urlopen(server + "/view?" + q) as r:
                        return Image.open(io.BytesIO(r.read())).convert("RGB")
            raise RuntimeError("workflow produced no image")
        time.sleep(0.5)
    raise TimeoutError("workflow did not finish in %ds" % timeout)


def deepbump(src_path, dst_path):
    r = subprocess.run([COMFY_VENV, "cli.py", src_path, dst_path, "color_to_normals"],
            cwd=DEEPBUMP, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("deepbump failed: " + r.stderr.strip()[-300:])


def seam_energy(img):
    """How badly the texture fails to tile: 0 is seamless.

    Compare the wrap-around edge difference against the difference one row or
    column inside. A seamless tile is no worse across the join than anywhere
    else, so a ratio near 1 is good and a large ratio is a visible seam.
    """
    import numpy as np
    a = np.asarray(img.convert("RGB"), dtype=float)
    wrap_h = np.abs(a[0, :] - a[-1, :]).mean()
    wrap_v = np.abs(a[:, 0] - a[:, -1]).mean()
    inner_h = np.abs(a[0, :] - a[1, :]).mean()
    inner_v = np.abs(a[:, 0] - a[:, 1]).mean()
    return ((wrap_h + wrap_v) / max(inner_h + inner_v, 1e-6))


def is_node_texture(name):
    if not name.endswith(".png"):
        return False
    stem = name[:-4]
    return not (stem.endswith("_n") or stem.endswith("_s"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", required=True, help="a Luanti game directory")
    ap.add_argument("--out", required=True)
    ap.add_argument("--server", default="http://127.0.0.1:8188")
    ap.add_argument("--ckpt", default="juggernautXL_ragnarokBy.safetensors")
    ap.add_argument("--controlnet", default="controlnet-tile-sdxl-1.0.safetensors")
    ap.add_argument("--size", type=int, default=768,
            help="working size for the 3x3 replica, so each tile is a third of it")
    ap.add_argument("--scale", type=int, default=4, help="output map size, as a multiple of the source")
    ap.add_argument("--denoise", type=float, default=0.55)
    ap.add_argument("--strength", type=float, default=0.9, help="tile ControlNet strength")
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--only", default="", help="comma separated texture stems")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--keep-albedo", action="store_true",
            help="also write the upscaled colour, which changes the game's look")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    only = set(x.strip() for x in args.only.split(",") if x.strip())

    todo = {}
    for root, _, files in os.walk(args.game):
        for f in files:
            if not is_node_texture(f):
                continue
            stem = f[:-4]
            if only and stem not in only:
                continue
            todo.setdefault(stem, os.path.join(root, f))

    names = sorted(todo)
    if args.limit:
        names = names[:args.limit]
    print("%d textures to bake" % len(names))

    done = skipped = failed = 0
    for i, stem in enumerate(names, 1):
        dst = os.path.join(args.out, stem + "_n.png")
        if os.path.exists(dst):
            skipped += 1
            continue
        try:
            src = Image.open(todo[stem]).convert("RGBA")
            w, h = src.size
            if w != h or w < 8 or w > 64:
                # animation strips and oversized art need their own handling
                skipped += 1
                continue
            # 3x3 replica so the centre tile is generated with neighbours
            rep = Image.new("RGB", (w * 3, h * 3))
            for yy in range(3):
                for xx in range(3):
                    rep.paste(src.convert("RGB"), (xx * w, yy * h))
            up_name = upload_image(args.server, rep, "goanna_%s.png" % stem)
            wf = workflow(up_name, args.ckpt, args.controlnet, args.size,
                    args.denoise, args.strength, args.steps, args.seed)
            out = run_workflow(args.server, wf)
            third = out.size[0] // 3
            centre = out.crop((third, third, third * 2, third * 2))
            target = w * args.scale
            centre = centre.resize((target, target), Image.LANCZOS)
            tmp = os.path.join(args.out, "_tmp_%s.png" % stem)
            centre.save(tmp)
            deepbump(tmp, dst)
            seam = seam_energy(Image.open(dst))
            if args.keep_albedo:
                centre.save(os.path.join(args.out, stem + "_albedo.png"))
            os.remove(tmp)
            done += 1
            print("  [%d/%d] %-34s seam %.2f" % (i, len(names), stem, seam))
        except Exception as e:  # keep going; one bad texture is not the run
            failed += 1
            print("  [%d/%d] %-34s FAILED %s" % (i, len(names), stem, str(e)[:120]))

    print("baked %d, skipped %d, failed %d" % (done, skipped, failed))
    return 1 if failed and not done else 0


if __name__ == "__main__":
    sys.exit(main())
