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
            "inputs": [({"name": a, "type": b, "link": None} if not isinstance(b, tuple)
                        else {"name": a, "type": b[0], "link": None,
                              "widget": {"name": b[1]}})
                       for a, b in inputs],
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


def build(size=768, denoise=0.55, strength=0.9, steps=20, seed=1, lora=0.0, pack=False):
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

    if pack:
        # height from the normals, AO from the height, then both into the
        # LabPBR pair the client actually reads
        hgt = g.node("GoannaNormalsToHeight", (2240, 430), [True],
                [("normals", "IMAGE"), ], [("IMAGE", "IMAGE")], (300, 60),
                title="normals to height")
        aon = g.node("GoannaAOFromHeight", (2240, 530), [1.0, 6, 8],
                [("height", "IMAGE")], [("IMAGE", "IMAGE")], (300, 110),
                title="AO from height (wraps at the edges)")
        lab = g.node("GoannaSaveLabPBR", (2600, 330),
                ["texture", "goanna_labpbr", 0.2, 0.04, False, 0.0, 0.0, 0.0],
                [("normals", "IMAGE"), ("height", "IMAGE"), ("ao", "IMAGE")],
                [("report", "STRING")], (360, 260),
                title="save LabPBR pair (_n and _s)")
        g.link(bump, 0, hgt, 0, "IMAGE")
        g.link(hgt, 0, aon, 0, "IMAGE")
        g.link(bump, 0, lab, 0, "IMAGE")
        g.link(hgt, 0, lab, 1, "IMAGE")
        g.link(aon, 0, lab, 2, "IMAGE")
    return g.dump()


def build_sdxl_lora(lora_strength=0.8, steps=28, cfg=6.0, size=1024, seed=1):
    """Plain SDXL with a LoRA. Nothing to do with textures; a starting point."""
    g = Graph()
    ckpt = g.node("CheckpointLoaderSimple", (-20, 100), ["sd_xl_base_1.0.safetensors"], [],
            [("MODEL", "MODEL"), ("CLIP", "CLIP"), ("VAE", "VAE")], (340, 100))
    lo = g.node("LoraLoader", (360, 100),
            ["texture-synthesis-topdown-sdxl.safetensors", lora_strength, lora_strength],
            [("model", "MODEL"), ("clip", "CLIP")],
            [("MODEL", "MODEL"), ("CLIP", "CLIP")], (340, 130))
    pos = g.node("CLIPTextEncode", (740, 100), ["a mossy cobblestone wall, top down, even light"],
            [("clip", "CLIP")], [("CONDITIONING", "CONDITIONING")], (400, 120), title="positive")
    neg = g.node("CLIPTextEncode", (740, 260), ["blurry, watermark, text, border"],
            [("clip", "CLIP")], [("CONDITIONING", "CONDITIONING")], (400, 120), title="negative")
    lat = g.node("EmptyLatentImage", (740, 420), [size, size, 1], [],
            [("LATENT", "LATENT")], (300, 110), title="SDXL wants about 1024")
    ks = g.node("KSampler", (1180, 100),
            [seed, "fixed", steps, cfg, "dpmpp_2m", "karras", 1.0],
            [("model", "MODEL"), ("positive", "CONDITIONING"),
             ("negative", "CONDITIONING"), ("latent_image", "LATENT")],
            [("LATENT", "LATENT")], (300, 260))
    dec = g.node("VAEDecode", (1520, 100), [], [("samples", "LATENT"), ("vae", "VAE")],
            [("IMAGE", "IMAGE")], (210, 50))
    sav = g.node("SaveImage", (1520, 200), ["sdxl_lora"], [("images", "IMAGE")], [], (320, 280))
    g.link(ckpt, 0, lo, 0, "MODEL")
    g.link(ckpt, 1, lo, 1, "CLIP")
    g.link(lo, 1, pos, 0, "CLIP")
    g.link(lo, 1, neg, 0, "CLIP")
    g.link(lo, 0, ks, 0, "MODEL")
    g.link(pos, 0, ks, 1, "CONDITIONING")
    g.link(neg, 0, ks, 2, "CONDITIONING")
    g.link(lat, 0, ks, 3, "LATENT")
    g.link(ks, 0, dec, 0, "LATENT")
    g.link(ckpt, 2, dec, 1, "VAE")
    g.link(dec, 0, sav, 0, "IMAGE")
    return g.dump()


def build_lora_train(dataset="my_dataset", steps=500, rank=16, lr=0.0005,
        batch=1, seed=0, size=1024):
    """Train a LoRA, then sample with it, in one graph.

    That last part is the difference from doing this in A1111 or kohya. The
    trained weights come back as a value on a wire, so the same run can load
    them into the model and generate a test image. There is no export, no
    file to go and find, no second tool.

    The dataset is a folder under ComfyUI/input holding images beside .txt
    captions of the same name, which is the convention kohya and A1111 use.

    Fewer dials than kohya: one learning rate rather than separate rates for
    the unet and the text encoder, no scheduler, and bucketing is a toggle
    rather than a resolution list. Start around 500 steps at rank 16 and
    watch the loss map.
    """
    g = Graph()
    ckpt = g.node("CheckpointLoaderSimple", (-20, 100), ["sd_xl_base_1.0.safetensors"], [],
            [("MODEL", "MODEL"), ("CLIP", "CLIP"), ("VAE", "VAE")], (340, 100))
    ds = g.node("LoadImageTextDataSetFromFolder", (-20, 300), [dataset], [],
            [("images", "IMAGE"), ("texts", "STRING")], (340, 80),
            title="dataset: ComfyUI/input/<folder>, images beside .txt captions")
    enc = g.node("VAEEncode", (360, 300), [], [("pixels", "IMAGE"), ("vae", "VAE")],
            [("LATENT", "LATENT")], (240, 50), title="images to latents")
    cap = g.node("CLIPTextEncode", (360, 420), [""],
            [("clip", "CLIP"), ("text", ("STRING", "text"))],
            [("CONDITIONING", "CONDITIONING")], (400, 120),
            title="captions (text is linked, not typed)")
    tr = g.node("TrainLoraNode", (800, 100),
            [batch, 1, steps, lr, rank, "AdamW", "MSE", seed, "fixed",
             "bf16", "bf16", False, "LoRA", True, 1, False, "[None]", False, False],
            [("model", "MODEL"), ("latents", "LATENT"), ("positive", "CONDITIONING")],
            [("lora", "LORA_MODEL"), ("loss_map", "LOSS_MAP"), ("steps", "INT")],
            (360, 520), title="train")
    sv = g.node("SaveLoRA", (1200, 100), ["loras/goanna_trained"],
            [("lora", "LORA_MODEL"), ("steps", "INT")], [], (340, 80))
    ld = g.node("LoraModelLoader", (1200, 240), [1.0, False],
            [("model", "MODEL"), ("lora", "LORA_MODEL")],
            [("MODEL", "MODEL")], (340, 110), title="test it without leaving the graph")
    pos = g.node("CLIPTextEncode", (1200, 400), ["a stone block texture, top down"],
            [("clip", "CLIP")], [("CONDITIONING", "CONDITIONING")], (400, 100), title="test prompt")
    neg = g.node("CLIPTextEncode", (1200, 540), ["blurry, watermark"],
            [("clip", "CLIP")], [("CONDITIONING", "CONDITIONING")], (400, 100), title="test negative")
    lat = g.node("EmptyLatentImage", (1200, 680), [size, size, 1], [],
            [("LATENT", "LATENT")], (300, 110))
    ks = g.node("KSampler", (1640, 240),
            [seed, "fixed", 28, 6.0, "dpmpp_2m", "karras", 1.0],
            [("model", "MODEL"), ("positive", "CONDITIONING"),
             ("negative", "CONDITIONING"), ("latent_image", "LATENT")],
            [("LATENT", "LATENT")], (300, 260))
    dec = g.node("VAEDecode", (1980, 240), [], [("samples", "LATENT"), ("vae", "VAE")],
            [("IMAGE", "IMAGE")], (210, 50))
    sav = g.node("SaveImage", (1980, 340), ["lora_test"], [("images", "IMAGE")], [], (320, 280))
    g.link(ds, 0, enc, 0, "IMAGE")
    g.link(ckpt, 2, enc, 1, "VAE")
    g.link(ckpt, 1, cap, 0, "CLIP")
    g.link(ds, 1, cap, 1, "STRING")
    g.link(ckpt, 0, tr, 0, "MODEL")
    g.link(enc, 0, tr, 1, "LATENT")
    g.link(cap, 0, tr, 2, "CONDITIONING")
    g.link(tr, 0, sv, 0, "LORA_MODEL")
    g.link(tr, 2, sv, 1, "INT")
    g.link(ckpt, 0, ld, 0, "MODEL")
    g.link(tr, 0, ld, 1, "LORA_MODEL")
    g.link(ckpt, 1, pos, 0, "CLIP")
    g.link(ckpt, 1, neg, 0, "CLIP")
    g.link(ld, 0, ks, 0, "MODEL")
    g.link(pos, 0, ks, 1, "CONDITIONING")
    g.link(neg, 0, ks, 2, "CONDITIONING")
    g.link(lat, 0, ks, 3, "LATENT")
    g.link(ks, 0, dec, 0, "LATENT")
    g.link(ckpt, 2, dec, 1, "VAE")
    g.link(dec, 0, sav, 0, "IMAGE")
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
    ap.add_argument("--pack", action="store_true",
            help="also derive height and AO and write the LabPBR pair")
    ap.add_argument("--both", action="store_true",
            help="write the plain workflow and the packed one side by side")
    ap.add_argument("--all", action="store_true",
            help="also write the plain SDXL LoRA flow and the LoRA training flow")
    ap.add_argument("--dataset", default="goanna_example",
            help="training: a folder under ComfyUI/input")
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    variants = [(args.out, args.pack)]
    if args.both:
        stem = args.out[:-5] if args.out.endswith(".json") else args.out
        variants = [(stem + ".json", False), (stem + "_labpbr.json", True)]
    if args.all:
        d = os.path.dirname(args.out)
        for nm, wf in (("goanna_sdxl_lora", build_sdxl_lora()),
                       ("goanna_lora_train", build_lora_train(args.dataset))):
            with open(os.path.join(d, nm + ".json"), "w") as f:
                json.dump(wf, f, indent=2)
            print("wrote", os.path.join(d, nm + ".json"))
    for path, pack in variants:
        with open(path, "w") as f:
            json.dump(build(args.size, args.denoise, args.strength, args.steps,
                    lora=args.lora, pack=pack), f, indent=2)
        print("wrote", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
