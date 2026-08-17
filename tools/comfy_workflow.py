#!/usr/bin/env python3
"""Emit the texture bake as a ComfyUI GUI workflow, for playing with by hand.

tools/pbr_bake.py drives the same graph over the HTTP API for the batch run.
This writes the editable version, so the parameters can be found by eye first
and then pinned in the batch. Generated rather than hand written so the two
cannot drift apart.

    tools/comfy_workflow.py                 # writes to ComfyUI's workflow dir
    tools/comfy_workflow.py --out foo.json

Load it in ComfyUI, point LoadImage at a plain 16 px texture, and hit run.
The graph replicates it, upscales under tile conditioning, crops the centre,
runs DeepBump for the normal map and reports the seam energy. The
interesting dials are:

  denoise (KSampler)       0.4 timid, 0.55 default, 0.7 starts inventing
  strength (ControlNet)    how hard the original holds the structure
  ImageScale width/height  the working size for the whole 3x3 replica,
                           so each tile gets a third of it

The 3x3 replica is what keeps the result seamless: the centre tile is
generated with its own neighbours present, so its edges line up. The graph
crops the middle ninth for you.

Needs the goanna_texture nodes in ComfyUI/custom_nodes.
"""

import argparse
import json
import os
import sys

# Kept identical to tools/pbr_bake.py. The tile ControlNet carries the
# structure, palette and layout, so the prompt only has to stop the model
# wandering off into photography.
PROMPT = ("seamless tiling game texture, flat lighting, even illumination, "
        "sharp detail, material surface")
NEGATIVE = ("blurry, soft focus, vignette, shadow, drop shadow, gradient "
        "background, text, watermark, border, frame, perspective, 3d render")

CKPT = "juggernautXL_ragnarokBy.safetensors"
CONTROLNET = "controlnet-tile-sdxl-1.0.safetensors"
# Optional. Apache-2.0, SDXL native, and the topdown variant is trained on
# flat surfaces viewed straight on, which is what a block texture is. Left
# off by default because tile conditioning dominates an upscale and a style
# LoRA earns much less here than it would generating from a prompt.
LORA = "texture-synthesis-topdown-sdxl.safetensors"


class Graph:
    """Builds ComfyUI's editor format, which wants explicit link records."""

    def __init__(self):
        self.nodes = []
        self.links = []
        self._nid = 0
        self._lid = 0

    def node(self, type_, pos, widgets, inputs, outputs, size=(315, 100), title=None):
        self._nid += 1
        n = {
            "id": self._nid,
            "type": type_,
            "pos": list(pos),
            "size": list(size),
            "flags": {},
            "order": self._nid - 1,
            "mode": 0,
            "inputs": [{"name": a, "type": b, "link": None} for a, b in inputs],
            "outputs": [{"name": a, "type": b, "links": [], "slot_index": i}
                        for i, (a, b) in enumerate(outputs)],
            "properties": {"Node name for S&R": type_},
            "widgets_values": widgets,
        }
        if title:
            n["title"] = title
        self.nodes.append(n)
        return self._nid

    def link(self, src, src_slot, dst, dst_slot, type_):
        self._lid += 1
        self.links.append([self._lid, src, src_slot, dst, dst_slot, type_])
        for n in self.nodes:
            if n["id"] == src:
                n["outputs"][src_slot]["links"].append(self._lid)
            if n["id"] == dst:
                n["inputs"][dst_slot]["link"] = self._lid
        return self._lid

    def dump(self):
        return {
            "last_node_id": self._nid,
            "last_link_id": self._lid,
            "nodes": self.nodes,
            "links": self.links,
            "groups": [{
                "title": "Replicate the tile 3x3 before this, crop the centre after",
                "bounding": [-40, -120, 1900, 700],
                "color": "#3f789e",
                "font_size": 24,
                "flags": {},
            }],
            "config": {},
            "extra": {},
            "version": 0.4,
        }


def build(size=768, denoise=0.55, strength=0.9, steps=20, seed=1, lora=0.0):
    g = Graph()

    ckpt = g.node("CheckpointLoaderSimple", (-20, 100), [CKPT], [],
            [("MODEL", "MODEL"), ("CLIP", "CLIP"), ("VAE", "VAE")], (340, 100))
    model_src, model_slot = ckpt, 0
    clip_src, clip_slot = ckpt, 1
    if lora:
        lo = g.node("LoraLoader", (-20, 240), [LORA, lora, lora],
                [("model", "MODEL"), ("clip", "CLIP")],
                [("MODEL", "MODEL"), ("CLIP", "CLIP")], (340, 130),
                title="LoraLoader (set strength 0 to compare without)")
        g.link(ckpt, 0, lo, 0, "MODEL")
        g.link(ckpt, 1, lo, 1, "CLIP")
        model_src, model_slot = lo, 0
        clip_src, clip_slot = lo, 1
    load = g.node("LoadImage", (-20, 430), ["example.png", "image"], [],
            [("IMAGE", "IMAGE"), ("MASK", "MASK")], (340, 320),
            title="LoadImage (a plain 16 px texture)")
    tile = g.node("GoannaTile3x3", (360, 430), [], [("image", "IMAGE")],
            [("IMAGE", "IMAGE")], (280, 40),
            title="tile 3x3 (so the seams are generated with neighbours)")
    scale = g.node("ImageScale", (360, 520), ["nearest-exact", size, size, "disabled"],
            [("image", "IMAGE")], [("IMAGE", "IMAGE")], (315, 130),
            title="ImageScale (nearest keeps the pixel edges)")
    pos = g.node("CLIPTextEncode", (360, 480), [PROMPT], [("clip", "CLIP")],
            [("CONDITIONING", "CONDITIONING")], (400, 120), title="positive")
    neg = g.node("CLIPTextEncode", (360, 640), [NEGATIVE], [("clip", "CLIP")],
            [("CONDITIONING", "CONDITIONING")], (400, 120), title="negative")
    cnl = g.node("ControlNetLoader", (360, 100), [CONTROLNET], [],
            [("CONTROL_NET", "CONTROL_NET")], (340, 60))
    cna = g.node("ControlNetApplyAdvanced", (800, 400),
            [strength, 0.0, 1.0],
            [("positive", "CONDITIONING"), ("negative", "CONDITIONING"),
             ("control_net", "CONTROL_NET"), ("image", "IMAGE")],
            [("positive", "CONDITIONING"), ("negative", "CONDITIONING")], (320, 140))
    enc = g.node("VAEEncode", (800, 220), [], [("pixels", "IMAGE"), ("vae", "VAE")],
            [("LATENT", "LATENT")], (240, 50),
            title="VAEEncode (img2img, so it stays the same texture)")
    ks = g.node("KSampler", (1180, 220),
            [seed, "fixed", steps, 5.0, "dpmpp_2m", "karras", denoise],
            [("model", "MODEL"), ("positive", "CONDITIONING"),
             ("negative", "CONDITIONING"), ("latent_image", "LATENT")],
            [("LATENT", "LATENT")], (300, 260))
    dec = g.node("VAEDecode", (1520, 220), [], [("samples", "LATENT"), ("vae", "VAE")],
            [("IMAGE", "IMAGE")], (210, 50))
    crop = g.node("GoannaCropCentre", (1520, 330), [], [("image", "IMAGE")],
            [("IMAGE", "IMAGE")], (280, 40),
            title="crop centre (the tile that had neighbours)")
    save = g.node("SaveImage", (1520, 420), ["goanna_albedo"], [("images", "IMAGE")],
            [], (320, 280), title="upscaled colour")
    bump = g.node("GoannaDeepBumpNormals", (1880, 330), ["LARGE"], [("image", "IMAGE")],
            [("IMAGE", "IMAGE")], (300, 60),
            title="DeepBump normals (needs the upscale to say anything)")
    savn = g.node("SaveImage", (1880, 430), ["goanna_normal"], [("images", "IMAGE")],
            [], (320, 280), title="normal map")
    seam = g.node("GoannaSeamEnergy", (2240, 330), [], [("image", "IMAGE")],
            [("seam", "FLOAT"), ("report", "STRING")], (300, 70),
            title="seam check (under 1.2 is seamless)")

    g.link(load, 0, tile, 0, "IMAGE")
    g.link(tile, 0, scale, 0, "IMAGE")
    g.link(clip_src, clip_slot, pos, 0, "CLIP")
    g.link(clip_src, clip_slot, neg, 0, "CLIP")
    g.link(pos, 0, cna, 0, "CONDITIONING")
    g.link(neg, 0, cna, 1, "CONDITIONING")
    g.link(cnl, 0, cna, 2, "CONTROL_NET")
    g.link(scale, 0, cna, 3, "IMAGE")
    g.link(scale, 0, enc, 0, "IMAGE")
    g.link(ckpt, 2, enc, 1, "VAE")
    g.link(model_src, model_slot, ks, 0, "MODEL")
    g.link(cna, 0, ks, 1, "CONDITIONING")
    g.link(cna, 1, ks, 2, "CONDITIONING")
    g.link(enc, 0, ks, 3, "LATENT")
    g.link(ks, 0, dec, 0, "LATENT")
    g.link(ckpt, 2, dec, 1, "VAE")
    g.link(dec, 0, crop, 0, "IMAGE")
    g.link(crop, 0, save, 0, "IMAGE")
    g.link(crop, 0, bump, 0, "IMAGE")
    g.link(bump, 0, savn, 0, "IMAGE")
    g.link(bump, 0, seam, 0, "IMAGE")
    return g.dump()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.expanduser(
            "~/Documents/Code/comfyui/user/default/workflows/goanna_texture_bake.json"))
    ap.add_argument("--size", type=int, default=768)
    ap.add_argument("--denoise", type=float, default=0.55)
    ap.add_argument("--strength", type=float, default=0.9)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--lora", type=float, default=0.0,
            help="add the texture synthesis LoRA at this strength, 0 to omit")
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(build(args.size, args.denoise, args.strength, args.steps, lora=args.lora), f, indent=2)
    print("wrote", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
