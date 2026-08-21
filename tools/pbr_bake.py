#!/usr/bin/env python3
"""Bake PBR companions for a Luanti game's textures.

Pack matching against a Minecraft pack tops out near 20 per cent coverage,
because most of what a Luanti game ships has no Minecraft equivalent and no
pack will ever cover it. This derives the maps from the game's own textures
instead, so coverage is total and the result is aligned to the art by
construction.

    16 px texture
      -> stage 1: upscale with tile ControlNet in ComfyUI, conditioned on
         the source itself, low denoise, keeps the structure
      -> stage 2: a fresh pass conditioned on stage 1's own output, same
         tile ControlNet, higher denoise, prompted with the texture's
         material class and its own filename, actually adds detail
      -> DeepBump colour to normals, on stage 2's result, which needs the
         resolution to say anything: on a raw 16 px tile it returns a
         nearly flat map
      -> <name>_n.png beside the texture, LabPBR channel order

The default is a single coherent upscale of the texture as it is, nothing
replicated. An earlier version of this replicated the source three by
three and cropped the centre tile out afterwards, on the idea that
generating the centre with its own neighbours present would make its
edges line up, useful for a texture that genuinely repeats across
thousands of nodes (stone, planks, dirt). In practice, checked by hand
across hundreds of textures, that is nearly never what a node's tile
actually is: a furnace front, an anvil top, a tree trunk's end grain, a
flower are each drawn once and never repeated next to a copy of
themselves, and asking the model to invent a coherent 3x3 grid of a
picture that was never meant to be a grid produces exactly that, a grid
of near-duplicates, not one clean texture. It is also not even the right
technique for the rare texture that does need seamlessness: that wants an
offset pass that moves the wraparound seam to the centre of the image
where it can be targeted directly and fixed, the way
https://github.com/SparknightLLC/ComfyUI-MakeSeamlessTexture does it, not
a hope that nine independently-generated copies happen to agree at their
borders. Nothing here implements that yet; --replicate-3x3 is the old
technique, kept for the rare confirmed-shared material where it happened
to look fine, off by default.

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

# Chord estimates relief from shading cues (its own demo is a photograph
# under raking light, see chord_image_to_material.png), and the prompt
# above exists specifically to suppress those cues so DeepBump's diffuse
# bake stays flat. Feeding Chord the flat-lit pass gave it nothing to work
# with: normal std 0.32 and roughness std 2.7 out of a 0-255 range, next to
# basecolor's 14.2, measured on default_stone. This second prompt asks for
# the opposite, for a pass that only ever feeds Chord, never the albedo.
CHORD_PROMPT = ("photograph of a physical material surface, macro texture "
        "photography, raking directional light, visible surface relief and grain")
CHORD_NEGATIVE = ("flat lighting, even illumination, text, watermark, border, "
        "frame, perspective, cartoon, illustration, painting")

# Node classification, from a JSON dump of the game's own registered nodes
# (tools/goanna_nodedef_dump.lua), not from guessed group names. Luanti games
# differ wildly in which groups they use: Mineclonia has no cracky, crumbly or
# choppy at all, and uses its own material_stone/material_wood/pickaxey/axey
# convention instead, so this reads whatever the game actually registered
# rather than assuming Minetest Game's vocabulary.
#
# sound_footstep is the strongest signal by far: it is named
# default_<material>_footstep for the overwhelming majority of Mineclonia's
# nodes, and that <material> token already says almost exactly what the
# prompt needs. Groups and drawtype only cover what the footstep sound misses.
FOOTSTEP_CLASS = {
    "hard": "stone", "wood": "wood", "metal": "metal", "grass": "leaves",
    "dirt": "soil", "glass": "glass", "sand": "sand", "gravel": "gravel",
    "ice": "ice",
}
GROUP_CLASS = {
    "material_stone": "stone", "material_wood": "wood", "material_glass": "glass",
    "axey": "wood", "shearsy": "cloth", "hoey": "soil",
}
DRAWTYPE_CLASS = {
    "plantlike": "leaves", "plantlike_rooted": "leaves",
    "allfaces_optional": "leaves", "allfaces": "leaves",
    "glasslike": "glass", "glasslike_framed_optional": "glass",
}
CLASS_PROMPT = {
    "stone": "rough natural stone", "wood": "wood grain",
    "leaves": "organic foliage, leaves", "glass": "smooth clear glass",
    "sand": "loose granular sand", "gravel": "loose coarse gravel",
    "snow": "soft packed snow", "ice": "smooth translucent ice",
    "soil": "packed earth, soil", "metal": "brushed metal",
    "cloth": "woven cloth",
}

# Roughness/metal defaults by material class: (smoothness, f0, metal). Real
# material knowledge, not measured: chord_v1.safetensors was tried for this
# first (tools/pbr_bake.py --chord) and rejected, its own roughness read 147,
# 141, 165 out of 255 for stone/wood/leaves respectively, a spread too narrow
# to trust over noise, next to a wide, physically motivated spread here.
# f0 is ignored when metal is true (G channel becomes 255, "use albedo as
# F0", the same convention tools/comfy_nodes/goanna_texture uses).
CLASS_SPEC = {
    "stone": (0.12, 0.04, False), "wood": (0.22, 0.04, False),
    "leaves": (0.30, 0.04, False), "glass": (0.92, 0.04, False),
    "sand": (0.08, 0.04, False), "gravel": (0.10, 0.04, False),
    "snow": (0.35, 0.04, False), "ice": (0.88, 0.04, False),
    "soil": (0.05, 0.04, False), "metal": (0.55, 1.0, True),
    "cloth": (0.08, 0.04, False),
}
DEFAULT_SPEC = (0.20, 0.04, False)  # matches tools/pbr_pack.py's own dull default

# Subsurface scattering by class, LabPBR's B channel above 65/255 (see
# nodes_array.gdshader's BACKLIGHT decode). Only classes translucent enough
# to glow with the sun behind them get one; everyone else keeps the channel
# at 0. Porosity, the same channel's other half (up to 64/255), is left out
# entirely: nothing in nodes_array.gdshader decodes it yet, LabPBR's own
# convention has porosity only read as anything once a surface is wet, and
# that weather-reactive path does not exist in Goanna yet either, so a
# porosity byte here would be write-only until something reads it.
CLASS_SSS = {"leaves": 0.5, "ice": 0.35, "snow": 0.2}


# Groups that name what a node *is* strongly enough to outrank its footstep
# sound. The footstep is the best general signal and stays first for
# everything else, but it is chosen for how a block sounds underfoot, not for
# what it is made of, and Mineclonia gives its machines default_hard_footstep.
# That made a blast furnace classify as stone, which then fed the stone prompt
# to the upscale, which rendered its metal banding as stone, after which Chord
# reported no metal and was right about the image it was given. The furnace
# came out identical to a bush in the metalness channel. Fixing it at the
# footstep is the only place that reaches the prompt as well as the class.
def classify_node(d):
    fs = d.get("sound_footstep") or ""
    if fs.startswith("default_") and fs.endswith("_footstep"):
        token = fs[len("default_"):-len("_footstep")]
        if token in FOOTSTEP_CLASS:
            return FOOTSTEP_CLASS[token]
    if "snow" in fs:
        return "snow"
    if "cloth" in fs:
        return "cloth"
    groups = d.get("groups") or {}
    for g, cls in GROUP_CLASS.items():
        if g in groups:
            return cls
    return DRAWTYPE_CLASS.get(d.get("drawtype") or "")


def load_classes(nodedefs_path):
    """texture stem -> material class, majority vote across nodes sharing it."""
    import collections
    with open(nodedefs_path) as f:
        nodes = json.load(f)
    votes = collections.defaultdict(collections.Counter)
    for d in nodes:
        cls = classify_node(d)
        if not cls:
            continue
        for tile in d.get("tiles", []):
            if tile.endswith(".png"):
                votes[tile[:-4]][cls] += 1
    return {stem: counter.most_common(1)[0][0] for stem, counter in votes.items()}


def load_repeating_tile_stems(nodedefs_path):
    """A guess at which node face textures are genuine shared surface
    material, for --replicate-3x3 to restrict itself to. Not load-bearing
    for the default path, which upscales every texture as a single image
    regardless.

    A real material (stone, planks, glass) tends to get reused across
    nodes of several different drawtypes: the same PNG on a full cube, a
    stair, a slab, a wall. A decorative face used by exactly one
    functional block (an anvil top, a furnace front, a jukebox top) stays
    inside one drawtype even when the block itself has several variants
    (three anvil damage stages, a dozen cauldron fill levels). But this is
    a guess, not proof: manual review across hundreds of Mineclonia's
    textures found plenty of drawtype-diverse stems, tree bark and end
    grain among them, that still are not a pattern meant to repeat as a
    3x3 grid. Treat a stem showing up here as "worth a look", not "safe to
    --replicate-3x3 unattended".
    """
    import collections
    with open(nodedefs_path) as f:
        nodes = json.load(f)
    drawtypes = collections.defaultdict(set)
    for d in nodes:
        for tile in d.get("tiles", []):
            if tile.endswith(".png"):
                drawtypes[tile[:-4]].add(d.get("drawtype"))
    return {stem for stem, dts in drawtypes.items() if len(dts) >= 2}


def load_node_tile_stems(nodedefs_path):
    """Every texture stem actually used as a node face, from the same dump.

    Walking the game directory for square 8-64px PNGs also catches item
    icons, GUI art and mob textures, none of which are node faces at all.
    minetest.registered_nodes is nodes only, so this set is not a guess.
    """
    with open(nodedefs_path) as f:
        nodes = json.load(f)
    stems = set()
    for d in nodes:
        for tile in d.get("tiles", []):
            if tile.endswith(".png"):
                stems.add(tile[:-4])
    return stems


def load_item_texture_stems(itemdefs_path):
    """Every texture stem an item carries, from a JSON dump written by
    tools/goanna_itemdef_dump.lua. An inventory slot is flat and unlit, but the
    same image is the item in hand and the item on the ground, and both of
    those are lit geometry.
    """
    with open(itemdefs_path) as f:
        items = json.load(f)
    stems = set()
    for d in items:
        for t in d.get("textures", []):
            if t.endswith(".png"):
                stems.add(t[:-4])
    return stems


def load_entity_texture_stems(entitydefs_path):
    """Every texture stem used as a mob/entity skin, from a JSON dump
    written by tools/goanna_entitydef_dump.lua. Scopes a run to genuine
    entity skins the same way load_node_tile_stems scopes one to node faces.
    """
    with open(entitydefs_path) as f:
        entities = json.load(f)
    stems = set()
    for d in entities:
        for tex in d.get("textures", []):
            if tex.endswith(".png"):
                stems.add(tex[:-4])
    return stems


# Eleven material classes is not enough specificity on its own for
# thousands of textures: "stone" alone covers andesite, deepslate,
# blackstone and a dozen ores that look nothing alike. Mineclonia's texture
# stems are themselves descriptive (mcl_deepslate_polished,
# mcl_nether_quartz_ore, mcl_core_stripped_dark_oak_top), so add whatever
# words the stem itself carries on top of the class phrase, rather than
# growing the class table to try to name every material by hand.
_HINT_STOPWORDS = {"top", "bottom", "side", "front", "back", "left", "right",
        "upper", "lower", "inner", "outer", "on", "off", "end", "ends", "png"}


def name_hint(stem):
    words = [w for w in stem.split("_") if w and w.lower() not in _HINT_STOPWORDS
            and not w.isdigit()]
    return " ".join(words)


def write_attribution(game_dir, out_dir, textures=None):
    """Record where the source art came from, beside the output.

    Every map this tool writes is a derivative work. Stage 1 is deliberately a
    low denoise pass conditioned on the source so that the output stays the
    same texture, and the normal and spec maps are then derived from that. So
    whatever licence the game's textures carry, these carry too, and a folder
    of loose PNGs with no provenance is exactly how that gets lost.

    Mineclonia is the case in point and it is not obvious: its code is GPL-3.0
    but its textures are CC BY-SA 4.0, being mostly verbatim copies of Pixel
    Perfection by XSSheep and Pixel Perfection Legacy by Nova Wostra. Neither
    matches Luanti's own media terms, which is what you would assume.
    """
    top = [f for f in ("LEGAL.md", "LICENSE.txt", "LICENSE", "LICENSE.md",
            "COPYING", "README.md") if os.path.exists(os.path.join(game_dir, f))]
    # The top level file is the floor, not the whole story. Individual mods
    # carry their own, naming specific authors the game-wide statement does
    # not: Mineclonia's mcl_amethyst/textures/LICENSE.txt credits Nova_Wostra
    # by name, and mcl_experience/textures/attributes.txt points one texture at
    # a third party repository entirely. Attribution that only quotes the top
    # level file misses those, so collect them.
    # Which mod each texture actually came from, because licensing here is per
    # mod and sometimes per file, not per game. mobs_mc alone declares six
    # media licences in one LICENSE-media.md (CC0, CC BY 3.0, CC BY-SA 4.0,
    # GPL-3.0, MIT, LGPL-2.1) with per file attributions under them, and
    # mcl_mobs descends from Mobs Redo under MIT with Mineclonia's own changes
    # GPL-3.0. A single game wide answer does not exist, so the honest record
    # is: this texture came from that mod, and these are that mod's terms.
    def owning_mod(path):
        d = os.path.dirname(path)
        while d.startswith(game_dir) and len(d) > len(game_dir):
            if os.path.exists(os.path.join(d, "mod.conf")):
                return d
            d = os.path.dirname(d)
        return game_dir

    def licence_files(mod_dir):
        found = []
        for root, _, files in os.walk(mod_dir):
            for fn in files:
                low = fn.lower()
                if low.startswith("license") or low.startswith("licence") \
                        or low.startswith("copying") or low.startswith("credits") \
                        or low in ("attributes.txt", "attribution.txt"):
                    found.append(os.path.relpath(os.path.join(root, fn), game_dir))
        return sorted(found)

    by_mod = {}
    for stem, path in sorted((textures or {}).items()):
        by_mod.setdefault(owning_mod(path), []).append(stem)
    per_mod = []
    for mod_dir in sorted(by_mod):
        per_mod.append((os.path.relpath(mod_dir, game_dir), by_mod[mod_dir],
                licence_files(mod_dir)))
    with open(os.path.join(out_dir, "ATTRIBUTION.md"), "w") as f:
        f.write("# Attribution for these maps\n\n"
                "Generated by tools/pbr_bake.py from the textures of the game at\n"
                "`%s`.\n\n"
                "These are derivative works of that game's art, not new art. The\n"
                "upscale is conditioned on the source at low denoise so the output\n"
                "stays the same texture, and the normal and spec maps are derived\n"
                "from the upscale. They therefore carry the source's licence and its\n"
                "attribution requirements, including any share-alike term.\n\n"
                "## Game wide terms\n\n"
                % game_dir)
        for n in top:
            f.write("- `%s`\n" % n)
        if not top:
            f.write("- (none found, which is itself worth resolving before sharing)\n")
        f.write("\n## Where each texture came from\n\n"
                "Licensing here is per mod and sometimes per file, so this lists the\n"
                "mod each baked texture was read from and that mod's own licence\n"
                "files. Read those, not just the game wide ones: a single mod can\n"
                "declare several media licences with per file attributions under\n"
                "them. %d mods contributed.\n\n" % len(per_mod))
        for rel, stems, lics in per_mod:
            f.write("### `%s` (%d textures)\n\n" % (rel, len(stems)))
            if lics:
                for l in lics:
                    f.write("- licence file: `%s`\n" % l)
            else:
                f.write("- no licence file of its own; falls back to the game wide terms\n")
            f.write("- textures: %s\n\n" % ", ".join(stems))
        if not per_mod:
            f.write("(no textures recorded)\n")


def prompt_for(stem, classes):
    cls = classes.get(stem)
    parts = [PROMPT]
    if cls:
        parts.append(CLASS_PROMPT[cls])
    hint = name_hint(stem)
    if hint and hint.lower() not in PROMPT.lower():
        parts.append(hint)
    return ", ".join(parts)


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


def workflow(image_name, ckpt, controlnet, width, height, denoise, strength, steps, seed,
        prompt=PROMPT, negative=NEGATIVE, lora=None, lora_strength=0.0,
        filename_prefix="goanna_bake"):
    """The API graph: img2img steered by tile ControlNet.

    Low denoise plus tile conditioning is what makes a pass stay close to
    its input rather than wander into a fresh generation; a higher denoise
    on the same graph, fed the previous pass's own output, is what turns
    that into the detail pass described in main()'s per-texture loop.
    width/height are independent (not a single square size) so a
    non-square source, a mob skin sheet rather than a node tile, scales
    without distorting its aspect ratio. filename_prefix reaches ComfyUI's
    own saved output filenames, so a live view of the queue can be read
    against the texture and pass it belongs to instead of an opaque
    incrementing counter.
    """
    g = {
        "1": {"class_type": "CheckpointLoaderSimple",
              "inputs": {"ckpt_name": ckpt}},
        "2": {"class_type": "LoadImage",
              "inputs": {"image": image_name}},
        # nearest, so the control signal keeps the hard pixel edges that carry
        # the texture's identity rather than a smeared interpolation
        "3": {"class_type": "ImageScale",
              "inputs": {"image": ["2", 0], "upscale_method": "nearest-exact",
                         "width": width, "height": height, "crop": "disabled"}},
        "6": {"class_type": "ControlNetLoader",
              "inputs": {"control_net_name": controlnet}},
        "8": {"class_type": "VAEEncode",
              "inputs": {"pixels": ["3", 0], "vae": ["1", 2]}},
        "10": {"class_type": "VAEDecode",
               "inputs": {"samples": ["9", 0], "vae": ["1", 2]}},
        "11": {"class_type": "SaveImage",
               "inputs": {"images": ["10", 0], "filename_prefix": filename_prefix}},
    }
    model_ref, clip_ref = ["1", 0], ["1", 1]
    if lora and lora_strength:
        g["12"] = {"class_type": "LoraLoader",
                "inputs": {"model": ["1", 0], "clip": ["1", 1], "lora_name": lora,
                           "strength_model": lora_strength, "strength_clip": lora_strength}}
        model_ref, clip_ref = ["12", 0], ["12", 1]
    g["4"] = {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": clip_ref}}
    g["5"] = {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": clip_ref}}
    g["7"] = {"class_type": "ControlNetApplyAdvanced",
            "inputs": {"positive": ["4", 0], "negative": ["5", 0],
                       "control_net": ["6", 0], "image": ["3", 0],
                       "strength": strength, "start_percent": 0.0, "end_percent": 1.0}}
    g["9"] = {"class_type": "KSampler",
            "inputs": {"model": model_ref, "seed": seed, "steps": steps,
                       "cfg": 5.0, "sampler_name": "dpmpp_2m", "scheduler": "karras",
                       "positive": ["7", 0], "negative": ["7", 1], "latent_image": ["8", 0],
                       "denoise": denoise}}
    return g


def chord_workflow(image_name, chord_ckpt, filename_prefix="goanna_chord"):
    """Decompose an already-upscaled, already-cropped texture into material
    maps. Chord estimates from the image alone, so it wants the detail the
    SDXL upscale added, not the raw 16 px source; see pbr-plan.md's own note
    that Chord slots in after the upscale, not instead of it.
    """
    return {
        "1": {"class_type": "ChordLoadModel", "inputs": {"ckpt_name": chord_ckpt}},
        "2": {"class_type": "LoadImage", "inputs": {"image": image_name}},
        "3": {"class_type": "ChordMaterialEstimation",
              "inputs": {"chord_model": ["1", 0], "image": ["2", 0]}},
        "4": {"class_type": "SaveImage",
              "inputs": {"images": ["3", 0], "filename_prefix": filename_prefix + "_basecolor"}},
        "5": {"class_type": "SaveImage",
              "inputs": {"images": ["3", 1], "filename_prefix": filename_prefix + "_normal"}},
        "6": {"class_type": "SaveImage",
              "inputs": {"images": ["3", 2], "filename_prefix": filename_prefix + "_roughness"}},
        "7": {"class_type": "SaveImage",
              "inputs": {"images": ["3", 3], "filename_prefix": filename_prefix + "_metalness"}},
    }


def echo_workflow(image_name, filename_prefix):
    """A trivial LoadImage -> SaveImage graph. DeepBump and the class-spec
    packer write _n.png/_s.png straight to local disk with plain PIL calls;
    neither ever touches ComfyUI, so without this the finished PBR maps
    never appear in the same live queue/gallery view the two generation
    passes already show up in, and watching the bake run is watching half
    of it. Pushing the finished file back through ComfyUI's own save, under
    a name that says what it is, puts it in that same view.
    """
    return {
        "1": {"class_type": "LoadImage", "inputs": {"image": image_name}},
        "2": {"class_type": "SaveImage",
              "inputs": {"images": ["1", 0], "filename_prefix": filename_prefix}},
    }


def _wait_for_outputs(server, wf, timeout):
    pid = post(server, "/prompt", {"prompt": wf})["prompt_id"]
    t0 = time.time()
    while time.time() - t0 < timeout:
        hist = get(server, "/history/" + pid)
        if pid in hist:
            return hist[pid]["outputs"]
        time.sleep(0.5)
    raise TimeoutError("workflow did not finish in %ds" % timeout)


def _fetch_image(server, im):
    q = urllib.parse.urlencode({"filename": im["filename"],
            "subfolder": im.get("subfolder", ""), "type": im.get("type", "output")})
    with urllib.request.urlopen(server + "/view?" + q) as r:
        return Image.open(io.BytesIO(r.read())).convert("RGB")


def run_workflow(server, wf, timeout=300):
    outs = _wait_for_outputs(server, wf, timeout)
    for node in outs.values():
        for im in node.get("images", []):
            return _fetch_image(server, im)
    raise RuntimeError("workflow produced no image")


def run_workflow_named(server, wf, node_ids, timeout=300):
    """Like run_workflow, but for a graph with several distinct SaveImage
    nodes: returns {node_id: PIL.Image} for exactly the requested node ids.
    """
    outs = _wait_for_outputs(server, wf, timeout)
    result = {}
    for node_id in node_ids:
        images = outs.get(node_id, {}).get("images", [])
        if not images:
            raise RuntimeError("workflow node %s produced no image" % node_id)
        result[node_id] = _fetch_image(server, images[0])
    return result


def generate_pass(args, prompt, src_img, w, h, target_w, target_h, denoise, strength,
        use_tile, filename_prefix):
    """One img2img/tile-ControlNet pass: replicate 3x3 and crop the centre
    back out when use_tile, otherwise run src_img through as it is; either
    way, generation happens at args.size (or src_img's own longer side
    scaled to it) and the result is returned resized to (target_w,
    target_h). Shared by both passes in main()'s per-texture loop: a
    structural upscale conditioned on the source, then a fresh detail pass
    conditioned on that upscale's own output. strength is a parameter, not
    always args.strength, because the detail pass needs its own lower tile
    ControlNet strength: at args.strength (0.9, right for holding a 16 px
    source's structure together) it also holds the detail pass so tightly
    that raising its denoise barely changes anything, checked by hand on
    default_stone at denoise up to 0.85, normal map channel std moved from
    22.2 (single pass) to 20.0-21.0 (two passes at 0.9 strength), which is
    noise, not added material.
    """
    if use_tile:
        rep = Image.new("RGB", (w * 3, h * 3))
        for yy in range(3):
            for xx in range(3):
                rep.paste(src_img, (xx * w, yy * h))
        work_w = work_h = args.size
    else:
        rep = src_img
        work_scale = args.size / max(w, h)
        work_w = max(1, int(round(w * work_scale)))
        work_h = max(1, int(round(h * work_scale)))
    # ComfyUI's own /upload/image endpoint is untested with a "/" in the
    # name; filename_prefix can have one (a run subfolder, see main()), the
    # upload only ever needs a name unique enough not to collide, not the
    # same folder structure as the eventual SaveImage output.
    up_name = upload_image(args.server, rep, filename_prefix.replace("/", "_") + "_in.png")
    wf = workflow(up_name, args.ckpt, args.controlnet, work_w, work_h, denoise,
            strength, args.steps, args.seed, prompt=prompt,
            lora=args.lora, lora_strength=args.lora_strength,
            filename_prefix=filename_prefix)
    out = run_workflow(args.server, wf)
    if use_tile:
        third = out.size[0] // 3
        out = out.crop((third, third, third * 2, third * 2))
    if target_w <= 0 or target_h <= 0 or out.size == (target_w, target_h):
        return out  # 0 means the caller wants whatever was generated
    # Upscaling to the target is fine. Downscaling to it is throwing away
    # generated detail, and it used to happen silently on every texture:
    # a 16 px source at the default --size 768 and --scale 4 generates at
    # 768 and kept 64, discarding 98 per cent of the pixels, and the LANCZOS
    # average of invented fine detail is exactly the smeared low contrast
    # mush that made packs read as muddy rather than detailed. Callers that
    # want the native result ask for it; see main()'s per texture loop, which
    # now derives the normal map before any downscale.
    return out.resize((target_w, target_h), Image.LANCZOS)


def deepbump(src_path, dst_path):
    r = subprocess.run([COMFY_VENV, "cli.py", src_path, dst_path, "color_to_normals"],
            cwd=DEEPBUMP, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("deepbump failed: " + r.stderr.strip()[-300:])


def deepbump_height(src_path, dst_path, seamless=True):
    r = subprocess.run([COMFY_VENV, "cli.py", src_path, dst_path, "normals_to_height",
            "--normals_to_height-seamless", "TRUE" if seamless else "FALSE"],
            cwd=DEEPBUMP, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("deepbump height failed: " + r.stderr.strip()[-300:])


def ao_from_height(height_img, strength=1.0, radius_px=6, directions=8, wrap=True):
    """Ambient occlusion from a height map. A port of
    tools/comfy_nodes/goanna_texture's GoannaAOFromHeight without the
    ComfyUI/torch dependency it needs there: a ring of directions, asking
    for each whether the terrain rises enough along it to block the sky.

    Wraps at the edges for a tile that repeats infinitely (an AO map
    darkened at its own edges reads as a grid of shadows once it repeats);
    clamps at the edges instead for a one-off image that is never tiled,
    like a mob skin, where wrapping would sample the opposite side of the
    sheet as a false neighbour that was never actually adjacent.
    """
    import numpy as np
    h = np.asarray(height_img.convert("L"), dtype=np.float32) / 255.0
    hh, ww = h.shape
    padded = None if wrap else np.pad(h, radius_px, mode="edge")
    occ = np.zeros_like(h)
    for d in range(directions):
        ang = 2.0 * np.pi * d / directions
        dx, dy = np.cos(ang), np.sin(ang)
        horizon = np.zeros_like(h)
        for r in range(1, radius_px + 1):
            sx, sy = int(round(dx * r)), int(round(dy * r))
            if wrap:
                shifted = np.roll(np.roll(h, -sy, axis=0), -sx, axis=1)
            else:
                shifted = padded[radius_px + sy:radius_px + sy + hh,
                        radius_px + sx:radius_px + sx + ww]
            horizon = np.maximum(horizon, (shifted - h) / float(r))
        occ += np.clip(horizon, 0.0, None)
    occ = occ / float(directions)
    return np.clip(1.0 - occ * strength * 4.0, 0.0, 1.0)


def pack_deepbump_normal(normal_img, height_img, n_path, wrap=True):
    """DeepBump's own colour_to_normals output carries a real tangent RG,
    but its B is DeepBump's own Z component, not ambient occlusion, and it
    writes nothing meaningful to A. Replace B with real AO computed from a
    normals_to_height pass, and A with that height. Nothing in
    nodes_array.gdshader reads A yet (no parallax), so its exact calibration
    is not visually consequential today, only worth getting right for later.
    """
    import numpy as np
    n = np.asarray(normal_img.convert("RGB"), dtype=np.uint8)
    h, w = n.shape[:2]
    height_resized = height_img.resize((w, h))
    ao = ao_from_height(height_resized, wrap=wrap)
    nmap = np.zeros((h, w, 4), dtype=np.uint8)
    nmap[..., 0:2] = n[..., 0:2]
    nmap[..., 2] = np.clip(ao * 255.0, 0, 255).astype(np.uint8)
    nmap[..., 3] = np.asarray(height_resized.convert("L"), dtype=np.uint8)
    Image.fromarray(nmap, "RGBA").save(n_path)


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


DIELECTRIC_F0 = 10  # matches tools/pbr_pack.py's own convention
METAL_THRESHOLD = 0.5


def pack_hybrid_spec(roughness_img, metalness_img, stem, classes, s_path, size):
    """_s from both sources, which is what neither single path gives.

    Chord estimates roughness and metalness per pixel from the image, so R and
    G come from it: one mortar line can be rougher than the brick beside it.
    It has nothing to say about the other two, and pack_chord_maps writes them
    as B = 0 and A = 255, which is worse than the class table it replaced: no
    leaf translucency and no emission anywhere. Those two are properties of
    what a node *is*, not of how its picture looks, so they stay on the class
    table, constant across the tile, which is all they ever were.

    So: R and G per pixel from Chord, B and A per class, at the map size
    rather than FLAT_SPEC_SIZE, because half of it is now real detail.
    """
    import numpy as np
    w, h = size
    rough = np.asarray(roughness_img.convert("L").resize((w, h), Image.LANCZOS),
            dtype=np.float32) / 255.0
    metal = np.asarray(metalness_img.convert("L").resize((w, h), Image.LANCZOS),
            dtype=np.float32) / 255.0
    cls = classes.get(stem)
    sss = CLASS_SSS.get(cls, 0.0)
    smap = np.zeros((h, w, 4), dtype=np.uint8)
    # Chord's variation, the class table's level. Chord's per pixel structure
    # looks real: its correlation with albedo luminance flips sign between
    # textures (+0.91 on gold, -0.82 on steel, -0.68 on stone) and is 0.04 on
    # birch planks, which is not what a model merely echoing brightness does.
    # Its absolute level is not trustworthy on flat lit low detail game art,
    # which is the standing objection to Chord here: measured means came out
    # near the class table for gold, steel, leaves and planks, and four times
    # too smooth for stone, 121 of 255 against 31. Stone is everywhere, and
    # glossy stone is exactly the "everything is shiny" failure this is
    # supposed to fix. So the mean is moved back onto the class value and only
    # the deviation around it is Chord's.
    class_smooth, _, class_is_metal = CLASS_SPEC.get(cls, DEFAULT_SPEC)
    smooth = (1.0 - rough)
    smooth = np.clip(class_smooth + (smooth - smooth.mean()), 0.0, 1.0)
    smap[..., 0] = np.clip(smooth * 255.0, 0, 255).astype(np.uint8)
    # The class table still gets a veto on metalness: Chord reads gold ore's
    # flecks as metal and the stone around them as not, which is right, but it
    # also reads wet-looking stone as metal, which is not. A class that is not
    # metal cannot have metal pixels.
    raw_metal = float((metal > METAL_THRESHOLD).mean())
    g = np.where(metal > METAL_THRESHOLD, 255, DIELECTRIC_F0).astype(np.uint8)
    if class_is_metal and not (g == 255).any():
        # Chord returned metalness below threshold across the whole of
        # default_gold_block, which would demote a solid gold block to a
        # dielectric: worse than the constant it replaced. Where the class says
        # metal and Chord finds none, the class is right.
        g[:] = 255
    smap[..., 1] = g
    smap[..., 2] = int(round(65 + sss * 190)) if sss > 0.0 else 0
    smap[..., 3] = 255  # emission: none by class; light_source comes over the protocol
    Image.fromarray(smap, "RGBA").save(s_path)
    return raw_metal


def pack_chord_maps(normal_img, roughness_img, metalness_img, n_path, s_path):
    """Chord's normal/roughness/metalness, packed the same way
    tools/comfy_nodes/goanna_texture writes a LabPBR pair by hand: _n is RG
    tangent normal (the shader reads AO from B and height from A, but Chord
    gives neither, so B/A come along for the ride from Chord's own normal
    image and a flat 255 respectively, exactly as the existing DeepBump path
    already does today). _s R is smoothness (1 - roughness), G is a metal
    table index above threshold or a plain dielectric F0 otherwise, B is 0
    (no porosity/SSS from an estimation model), A is 255 (no emission; the
    protocol already gives Goanna that separately via light_source).
    """
    import numpy as np
    n = np.asarray(normal_img.convert("RGB"), dtype=np.uint8)
    h, w = n.shape[:2]
    nmap = np.zeros((h, w, 4), dtype=np.uint8)
    nmap[..., 0:3] = n
    nmap[..., 3] = 255
    Image.fromarray(nmap, "RGBA").save(n_path)

    rough = np.asarray(roughness_img.convert("L").resize((w, h)), dtype=np.float32) / 255.0
    metal = np.asarray(metalness_img.convert("L").resize((w, h)), dtype=np.float32) / 255.0
    smap = np.zeros((h, w, 4), dtype=np.uint8)
    smap[..., 0] = np.clip((1.0 - rough) * 255.0, 0, 255).astype(np.uint8)
    smap[..., 1] = np.where(metal > METAL_THRESHOLD, 255, DIELECTRIC_F0).astype(np.uint8)
    smap[..., 3] = 255
    Image.fromarray(smap, "RGBA").save(s_path)


def channel_previews(n_path, s_path):
    """Split the packed LabPBR pair back out into individually viewable
    greyscale maps: normal.xy is the only part of _n/_s a plain image
    viewer already shows correctly, everything else (AO, height,
    smoothness, metal/F0, porosity-or-SSS, emission) lives one channel deep
    in an RGBA file and reads as noise or a flat tint until it is pulled
    out on its own. Nothing in the game reads these; they exist only so a
    bake can be watched and checked by eye the same way the two generation
    passes already can be.
    """
    import numpy as np
    n = np.asarray(Image.open(n_path).convert("RGBA"))
    s = np.asarray(Image.open(s_path).convert("RGBA"))
    return {
        "ao": Image.fromarray(n[..., 2], "L"),
        "height": Image.fromarray(n[..., 3], "L"),
        "smoothness": Image.fromarray(s[..., 0], "L"),
        "metal_or_f0": Image.fromarray(s[..., 1], "L"),
        "porosity_or_sss": Image.fromarray(s[..., 2], "L"),
        "emission": Image.fromarray(s[..., 3], "L"),
    }


def channel_summary(n_path, s_path):
    """min-max of every packed channel, as one line.

    The previews above are faithful, which makes several of them unreadable:
    a dielectric's metal/F0 channel is 10 of 255 and a non-translucent
    material's porosity/SSS channel is 0, so both render as black squares that
    look exactly like a bug. They are not: 10/255 is LabPBR's ordinary
    dielectric F0 (0.04), 255 is a metal, and only leaves, ice and snow carry
    any SSS at all. Printing the numbers is the only way to tell a correct 10
    from an accidental 0 without opening the file in something that reports
    pixel values.
    """
    import numpy as np
    n = np.asarray(Image.open(n_path).convert("RGBA"))
    s = np.asarray(Image.open(s_path).convert("RGBA"))
    def rng(c):
        return "%d" % c.min() if c.min() == c.max() else "%d-%d" % (c.min(), c.max())
    return ("ao %s height %s | smooth %s metal/F0 %s sss %s emis %s"
            % (rng(n[..., 2]), rng(n[..., 3]), rng(s[..., 0]), rng(s[..., 1]),
               rng(s[..., 2]), rng(s[..., 3])))


FLAT_SPEC_SIZE = 4  # a flat colour reads the same whatever size the texture
# actually is; a full target-resolution copy of one constant RGBA value (up
# to 2048x2048 for a scale 4 --no-tile source) is wasted disk and, once
# Godot loads it, wasted VRAM for information that is, provably, four bytes.


def write_class_spec(stem, classes, s_path):
    """A flat _s from CLASS_SPEC and CLASS_SSS, the DeepBump path's fallback
    when there is no authored companion and no per-pixel estimation to draw
    on. See FLAT_SPEC_SIZE for why this ignores the texture's own size.
    """
    cls = classes.get(stem)
    smoothness, f0, metal = CLASS_SPEC.get(cls, DEFAULT_SPEC)
    g = 255 if metal else int(round(min(f0, 229.0 / 255.0) * 255))
    sss = CLASS_SSS.get(cls, 0.0)
    b = int(round(65 + sss * 190)) if sss > 0.0 else 0
    Image.new("RGBA", (FLAT_SPEC_SIZE, FLAT_SPEC_SIZE),
            (int(round(smoothness * 255)), g, b, 255)).save(s_path)


def restore_alpha(src, img):
    """img with src's alpha channel, resampled to img's size."""
    src_rgba = src.convert("RGBA")
    if min(src_rgba.size) < 1:
        return img
    alpha = src_rgba.split()[3].resize(img.size, Image.NEAREST)
    out = img.convert("RGBA")
    out.putalpha(alpha)
    return out


def composite_for_generation(src):
    """RGBA -> RGB, filling transparent pixels with the mean colour of the
    opaque ones rather than whatever raw colour sits under them (often
    black, per this game's own PNG export convention). This same image is
    the tile ControlNet's conditioning input, not just the generation seed,
    so an unfilled black void under a cutout is not merely baked in, it is
    actively reproduced and extended: the model is being told a black hole
    is real structure to preserve.
    """
    import numpy as np
    arr = np.asarray(src.convert("RGBA"), dtype=np.float32)
    alpha = arr[..., 3]
    opaque = alpha >= 128
    fill = arr[opaque][:, :3].mean(axis=0) if opaque.any() else np.array([128.0, 128.0, 128.0])
    rgb = arr[..., :3].copy()
    rgb[~opaque] = fill
    return Image.fromarray(rgb.astype(np.uint8), "RGB")


NEUTRAL_N = (128, 128, 255, 255)  # flat normal, full AO, flat height
NEUTRAL_S = (int(round(DEFAULT_SPEC[0] * 255)), DIELECTRIC_F0, 0, 255)


def mask_transparent_regions(src, target_w, target_h, n_path, s_path=None):
    """Force genuinely transparent source regions back to neutral defaults
    in the baked output, regardless of what generation invented there.
    Compositing before generation (composite_for_generation) keeps the
    model from being actively misled by a black void, but the model still
    has to draw something for that whole area; the source's alpha, not
    anything it produced, is what actually decides which pixels of the bake
    are real. A node's transparent cutout (a torch's air, a rail's gaps)
    never had material there to infer from in the first place.

    s_path is optional: skip it for a write_class_spec output, which is
    FLAT_SPEC_SIZE regardless of target_w/target_h and has no per-pixel
    correspondence to the source's alpha to mask against in the first
    place, being one constant colour already. Pass it for a pack_chord_maps
    output, which is real per-pixel data at the texture's own resolution.
    """
    import numpy as np
    alpha = np.asarray(src.convert("RGBA"), dtype=np.uint8)[..., 3]
    alpha_img = Image.fromarray(alpha, "L").resize((target_w, target_h), Image.NEAREST)
    mask = np.asarray(alpha_img) < 128
    if not mask.any():
        return

    n = np.array(Image.open(n_path).convert("RGBA"))
    n[mask] = NEUTRAL_N
    Image.fromarray(n, "RGBA").save(n_path)

    if s_path is not None:
        s = np.array(Image.open(s_path).convert("RGBA"))
        s[mask] = NEUTRAL_S
        Image.fromarray(s, "RGBA").save(s_path)


def is_animation_strip(w, h):
    """True for a vertical or horizontal Luanti animated tile: several
    square frames stacked in one file, not one image.
    mcl_campfires_campfire_fire.png is 32x128, four 32x32 frames; a copper
    lantern is 16x48, three 16x16 frames. Checked by hand: baking one of
    these as a single image blends real detail straight across the frame
    boundaries, which have to stay exactly where they were for the engine's
    own frame slicing to still cut clean frames out afterwards. That needs
    per-frame handling this tool does not have yet, so for now these are
    skipped rather than baked wrong.
    """
    if w == h:
        return False
    long_side, short_side = max(w, h), min(w, h)
    return short_side >= 8 and long_side % short_side == 0 and long_side // short_side >= 2


def is_node_texture(name):
    if not name.endswith(".png"):
        return False
    stem = name[:-4]
    return not (stem.endswith("_n") or stem.endswith("_s"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", required=True, help="a Luanti game directory")
    ap.add_argument("--out", required=True)
    ap.add_argument("--run", default="",
            help="ComfyUI's own output directory is shared by every invocation of this "
                 "tool, so without this every run's images interleave in one flat folder "
                 "with no way to tell which run a given image came from; this becomes a "
                 "subfolder under it (SaveImage's filename_prefix accepts a leading "
                 "'name/'). Defaults to --out's own basename, which is unique per run in "
                 "practice already")
    ap.add_argument("--server", default="http://127.0.0.1:8188")
    ap.add_argument("--ckpt", default="promissingArtisanXL_v40.safetensors")
    ap.add_argument("--controlnet", default="controlnet-tile-sdxl-1.0.safetensors")
    ap.add_argument("--lora", default="texture-synthesis-topdown-sdxl.safetensors")
    ap.add_argument("--lora-strength", type=float, default=0.0,
            help="0 disables the LoRA; comfy_workflow.py's own comment says it earns "
                 "less here than tile conditioning does, so it defaults off, not assumed on")
    ap.add_argument("--nodedefs", default="",
            help="JSON dump from tools/goanna_nodedef_dump.lua, for per-texture "
                 "material classification in the prompt; omit to use the plain prompt")
    ap.add_argument("--entitydefs", default="",
            help="JSON dump from tools/goanna_entitydef_dump.lua, to scope a run to "
                 "genuine mob/entity skins instead of every square PNG found")
    ap.add_argument("--itemdefs", default="",
            help="JSON dump from tools/goanna_itemdef_dump.lua, adding items to the run's "
                 "scope. Combines with --nodedefs and --entitydefs rather than replacing "
                 "them.")
    ap.add_argument("--replicate-3x3", action="store_true",
            help="upscale by replicating the source 3x3 and cropping the centre tile out "
                 "afterwards, instead of the default single-image upscale. Checked by hand "
                 "against hundreds of Mineclonia's node textures and found wrong far more "
                 "often than right, even for textures a node genuinely repeats: most of "
                 "what registered_nodes calls a 'tile' is one-off art (a furnace front, a "
                 "flower, end grain), not a repeating pattern, and generating it as a 3x3 "
                 "grid produces a grid, not a texture. With --nodedefs, restricts itself to "
                 "load_repeating_tile_stems' guess at genuinely shared material; without "
                 "one, applies to every square 8-64px source. Off by default.")
    ap.add_argument("--chord-spec", action="store_true",
            help="per pixel smoothness and metalness from ComfyUI-Chord, packed into _s "
                 "R and G, while _n stays DeepBump's and _s B/A stay on the class table. "
                 "Without it every _s channel is one constant per texture, so a furnace "
                 "front cannot have glowing bits and every plank in the game has the same "
                 "gloss. Unlike --chord this keeps leaf translucency and emission, which "
                 "pack_chord_maps zeroes.")
    ap.add_argument("--chord", action="store_true",
            help="use ComfyUI-Chord for normal/roughness/metalness instead of DeepBump "
                 "(needs chord_v1.safetensors installed; see comfyui/GOANNA-SETUP.md)")
    ap.add_argument("--chord-ckpt", default="chord_v1.safetensors")
    ap.add_argument("--size", type=int, default=768,
            help="working size for the upscale: the longer side of the source, or, under "
                 "--replicate-3x3, the size of the whole 3x3 replica (so each tile is a "
                 "third of it)")
    ap.add_argument("--bump-size", type=int, default=128,
            help="the resolution DeepBump is run at, longer side. It is a convolutional "
                 "net with a fixed receptive field, so it detects relief at a particular "
                 "pixel scale and flattens out above it: measured on Mineclonia stone and "
                 "birch planks, the shading contrast its normals produce falls from 0.115 "
                 "and 0.148 at 64 px, through 0.109 and 0.105 at 128, to 0.042 and 0.036 "
                 "at 256 and under 0.03 at 512. 128 keeps most of the relief with twice "
                 "the spatial detail of 64. The normal is then scaled up to --map-size, "
                 "which preserves amplitude, unlike scaling one down.")
    ap.add_argument("--map-size", type=int, default=256,
            help="the size every finished map is kept at, longer side, aspect preserved. "
                 "Absolute rather than a multiple of the source, because a multiple that "
                 "suits 16 px art gives a 64 px source four times too much. Generation "
                 "still happens at --size and the normal map is taken there, so a "
                 "--size above this is supersampling rather than waste. 0 falls back to "
                 "--scale.")
    ap.add_argument("--scale", type=int, default=4,
            help="output map size as a multiple of the source. Superseded by --map-size; "
                 "only used when that is 0.")
    ap.add_argument("--denoise", type=float, default=0.55,
            help="stage 1, the structural upscale: low, so the output has to stay the "
                 "same texture, only with detail that was not resolvable at source size")
    ap.add_argument("--detail-denoise", type=float, default=0.65,
            help="stage 2, the detail pass: takes stage 1's own output as both the "
                 "img2img base and the tile ControlNet condition, prompted with the "
                 "same material class and filename hint, at a higher denoise so it "
                 "actually adds material detail rather than only cleaning aliasing. "
                 "This pass's output, not stage 1's, is what DeepBump/Chord and the "
                 "final albedo read, since the normal map has to match the detail "
                 "that ends up in the texture")
    ap.add_argument("--strength", type=float, default=0.9,
            help="stage 1's tile ControlNet strength: high, to hold a source as small as "
                 "16 px together while it is upscaled")
    ap.add_argument("--detail-strength", type=float, default=0.5,
            help="stage 2's tile ControlNet strength: lower than stage 1's, so raising "
                 "--detail-denoise actually invents material detail instead of being held "
                 "to stage 1's output as tightly as stage 1 was held to the source")
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--only", default="", help="comma separated texture stems")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--no-previews", action="store_true",
            help="do not push the finished maps and their split channels back through "
                 "ComfyUI. They are diagnostics only, and they cost eight of the eleven "
                 "workflow submissions each texture makes, queued behind the generation "
                 "passes: measured at roughly 90 seconds per texture with them and the "
                 "GPU idle most of that. The per texture log line reports every channel's "
                 "range either way.")
    ap.add_argument("--keep-albedo", action="store_true",
            help="also write the upscaled colour, which changes the game's look")
    args = ap.parse_args()
    # Absolute, because deepbump() and deepbump_height() run the DeepBump CLI
    # with cwd=DEEPBUMP, so a relative --out resolves against DeepBump's own
    # directory and every texture fails with a FileNotFoundError naming a path
    # under it. Nothing else here cares, which is why it stayed hidden: every
    # earlier run happened to pass an absolute path.
    args.out = os.path.abspath(args.out)
    # Say the resolution arithmetic out loud, because --size and --map-size can
    # disagree and the losing side used to be silent. Generating above the kept
    # size is supersampling and is wanted; the bug this replaced was keeping 64
    # from a 768 generation *and* inferring the normal map from the 64.
    native16 = (args.size // 3) if args.replicate_3x3 else args.size
    kept16 = 16 * args.scale if args.map_size <= 0 else args.map_size
    print("resolution: 16 px source generates at %d, every map kept at %d"
            % (native16, kept16))
    print("  normal and height are taken at %d (--bump-size), then scaled up"
            % args.bump_size)
    if kept16 < 128:
        print("  WARNING: %d is small for a material map; 256 is the default for a reason"
                % kept16)
    if kept16 > native16:
        print("  WARNING: kept size is above the generated size, so %d of those pixels "
              "are interpolation, not detail. Raise --size." % kept16)
    # Unique per invocation, not per output directory. It used to be the out
    # directory's own basename, so re-running into the same --out reused the
    # same ComfyUI folder and every image landed beside the previous run's as
    # goanna_<stem>_detail_00002_.png, leaving you to work out which of them
    # was current. The bake itself never cared, because run_workflow reads its
    # result back from /history/<prompt_id> rather than by globbing the folder,
    # but watching that folder is how a run is actually followed.
    run = args.run or "%s-%s" % (os.path.basename(os.path.normpath(args.out)),
            time.strftime("%Y%m%d-%H%M%S"))

    os.makedirs(args.out, exist_ok=True)
    only = set(x.strip() for x in args.only.split(",") if x.strip())
    classes = load_classes(args.nodedefs) if args.nodedefs else {}
    # Walking the game directory for square 8-64px PNGs also catches item
    # icons, GUI art and mob textures: on Mineclonia that's 1178 of 2199
    # candidates, over half, none of them drawn tiled. Restrict to genuine
    # node faces (or genuine entity skins) whenever the dump that can tell
    # them apart is available; --only still names exact stems directly and
    # bypasses this.
    # tile_stems only matters under --replicate-3x3 (see its help text):
    # load_repeating_tile_stems' guess at which node faces are shared
    # material rather than one-off art. None means "apply to everything",
    # for a --replicate-3x3 run made without a nodedefs dump.
    # The scopes are a union, not a choice. They were exclusive, which meant a
    # run could dress node faces or mob skins or items but never more than one,
    # and the arithmetic came out as "we baked everything" when 2166 of 3245
    # textures had been out of scope by construction. A held item and a dropped
    # item are lit geometry, and a mob is lit geometry, so all three belong in
    # the same pack.
    tile_stems = None
    scope_stems = set()
    for path, loader in ((args.nodedefs, load_node_tile_stems),
            (args.entitydefs, load_entity_texture_stems),
            (args.itemdefs, load_item_texture_stems)):
        if path:
            scope_stems |= loader(path)
    if not scope_stems:
        scope_stems = None
    if args.nodedefs and args.replicate_3x3:
        # Only node faces tile. A mob skin or an item icon replicated 3x3 wastes
        # the generation on eight copies of something never seen tiled.
        tile_stems = load_repeating_tile_stems(args.nodedefs)

    todo = {}
    skipped_out_of_scope = 0
    for root, _, files in os.walk(args.game):
        for f in files:
            if not is_node_texture(f):
                continue
            stem = f[:-4]
            if only:
                if stem not in only:
                    continue
            elif scope_stems is not None and stem not in scope_stems:
                skipped_out_of_scope += 1
                continue
            todo.setdefault(stem, os.path.join(root, f))

    names = sorted(todo)
    write_attribution(args.game, args.out, todo)
    if args.limit:
        names = names[:args.limit]
    if skipped_out_of_scope:
        print("%d out-of-scope textures skipped" % skipped_out_of_scope)
    print("%d textures to bake" % len(names))

    done = skipped = skipped_animation = failed = 0
    for i, stem in enumerate(names, 1):
        dst = os.path.join(args.out, stem + "_n.png")
        sdst_done = os.path.join(args.out, stem + "_s.png")
        adst_done = os.path.join(args.out, stem + "_albedo.png")
        # The whole set, not just _n. This is what makes an interrupted run
        # resumable, and keying it on _n alone was quietly wrong: _n is written
        # first, so a run killed between writing it and writing _s left a stem
        # that every later run then skipped, permanently short an albedo and a
        # spec map. Two of those existed by the time it was noticed.
        want = [dst, sdst_done] + ([adst_done] if args.keep_albedo else [])
        if all(os.path.exists(f) for f in want):
            skipped += 1
            continue
        try:
            src = Image.open(todo[stem]).convert("RGBA")
            w, h = src.size
            if is_animation_strip(w, h):
                skipped_animation += 1
                print("  [%d/%d] %-34s skipped, animation strip %dx%d" %
                        (i, len(names), stem, w, h))
                continue
            use_tile = args.replicate_3x3 and (tile_stems is None or stem in tile_stems)
            if use_tile and (w != h or w < 8 or w > 64):
                # oversized single-frame art needs its own handling too
                skipped += 1
                continue
            if not use_tile and (w < 8 or h < 8 or w > 512 or h > 512):
                skipped += 1
                continue
            composited = composite_for_generation(src)
            prompt = prompt_for(stem, classes)
            if args.map_size > 0:
                # longer side to map_size, aspect preserved, never below source
                k = max(args.map_size / float(max(w, h)), 1.0)
                target_w, target_h = int(round(w * k)), int(round(h * k))
            else:
                target_w, target_h = w * args.scale, h * args.scale

            # Stage 1: structural upscale, conditioned on the source itself,
            # low denoise so the output stays the same texture.
            structure = generate_pass(args, prompt, composited, w, h, target_w, target_h,
                    args.denoise, args.strength, use_tile, run + "/goanna_" + stem + "_upscale")

            # Stage 2: a fresh regeneration conditioned on stage 1's own
            # output (so the tile ControlNet is holding the upscale's
            # structure, not the raw source's), at a higher denoise, so this
            # pass actually adds material detail true to the same prompt
            # rather than only cleaning up aliasing. Everything downstream
            # reads this pass, not stage 1: the normal map has to match
            # whatever detail actually ends up in the texture.
            # Stage 2 runs at whatever ComfyUI natively produces (args.size,
            # or a third of it under --replicate-3x3) and is kept at that size
            # here: everything derived from it wants the real detail, not an
            # average of it. The downscale to target_w/target_h happens once,
            # at the end, after the normal map has been taken.
            native = generate_pass(args, prompt, structure, target_w, target_h,
                    0, 0, args.detail_denoise, args.detail_strength,
                    use_tile, run + "/goanna_" + stem + "_detail")
            centre = native

            sdst = os.path.join(args.out, stem + "_s.png")
            if args.chord:
                centre_name = upload_image(args.server, centre, "goanna_%s_final.png" % stem)
                chord_out = run_workflow_named(args.server,
                        chord_workflow(centre_name, args.chord_ckpt,
                                run + "/goanna_" + stem + "_chord"),
                        ["5", "6", "7"])
                pack_chord_maps(chord_out["5"], chord_out["6"], chord_out["7"], dst, sdst)
            else:
                # DeepBump runs at --bump-size, not at the native generation
                # size and not at the map size: see that flag for the numbers.
                tmp = os.path.join(args.out, "_tmp_%s.png" % stem)
                bw, bh = native.size
                bk = args.bump_size / float(max(bw, bh))
                if bk < 1.0:
                    native.resize((max(1, int(round(bw * bk))), max(1, int(round(bh * bk)))),
                            Image.LANCZOS).save(tmp)
                else:
                    native.save(tmp)
                raw_normal = os.path.join(args.out, "_tmp_normal_%s.png" % stem)
                deepbump(tmp, raw_normal)
                height_tmp = os.path.join(args.out, "_tmp_height_%s.png" % stem)
                deepbump_height(raw_normal, height_tmp, seamless=use_tile)
                # Scaled up to the map size. Scaling a normal map up preserves
                # its amplitude; scaling one down averages opposing slopes
                # against each other and cancels them, which is what made an
                # earlier attempt at this produce almost flat maps.
                nrm_img = Image.open(raw_normal)
                hgt_img = Image.open(height_tmp)
                if nrm_img.size != (target_w, target_h):
                    nrm_img = nrm_img.resize((target_w, target_h), Image.BICUBIC)
                    hgt_img = hgt_img.resize((target_w, target_h), Image.BICUBIC)
                pack_deepbump_normal(nrm_img, hgt_img, dst, wrap=use_tile)
                os.remove(tmp)
                os.remove(raw_normal)
                os.remove(height_tmp)
                if args.chord_spec:
                    # _n stays DeepBump's, above. Only _s comes from Chord,
                    # and only its R and G; see pack_hybrid_spec.
                    centre_name = upload_image(args.server, native,
                            "goanna_%s_final.png" % stem)
                    chord_out = run_workflow_named(args.server,
                            chord_workflow(centre_name, args.chord_ckpt,
                                    run + "/goanna_" + stem + "_chord"),
                            ["6", "7"])
                    pack_hybrid_spec(chord_out["6"], chord_out["7"], stem, classes,
                            sdst, (target_w, target_h))
                else:
                    write_class_spec(stem, classes, sdst)
            # write_class_spec's output is flat at FLAT_SPEC_SIZE, not at
            # target_w/target_h, so there is no per-pixel correspondence to
            # the source's alpha left to mask; only pass sdst through for
            # pack_chord_maps' real per-pixel result.
            mask_transparent_regions(src, target_w, target_h, dst, sdst if args.chord else None)
            # Neither DeepBump nor the class-spec packer above ever calls
            # into ComfyUI, so without this the finished _n/_s never appear
            # next to goanna_upscale_*/goanna_detail_* in ComfyUI's own
            # output directory, and watching that directory only shows half
            # the bake.
            if not args.no_previews:
                n_name = upload_image(args.server, Image.open(dst), "goanna_%s_normal.png" % stem)
                run_workflow(args.server, echo_workflow(n_name, run + "/goanna_" + stem + "_normal"))
                s_name = upload_image(args.server, Image.open(sdst), "goanna_%s_spec.png" % stem)
                run_workflow(args.server, echo_workflow(s_name, run + "/goanna_" + stem + "_spec"))
                # _n/_s are the deliverable, packed to match nodes_array.gdshader's
                # decode, but a packed channel is not something a plain viewer
                # shows meaningfully; split it back out purely so the bake can be
                # checked by eye, the same way the two generation passes can.
                for tag, img in channel_previews(dst, sdst).items():
                    # ComfyUI's LoadImage routes a small single-channel PNG
                    # through a video-probe path that errors below about 16px
                    # ("L" mode at 4x4/8x8 fails, RGB at the same size does not,
                    # checked by hand); a write_class_spec output is
                    # FLAT_SPEC_SIZE, well under that, so convert rather than
                    # lose the preview for every flat-spec texture.
                    up = upload_image(args.server, img.convert("RGB"), "goanna_%s_%s.png" % (stem, tag))
                    run_workflow(args.server, echo_workflow(up, run + "/goanna_" + stem + "_" + tag))
            seam = seam_energy(Image.open(dst))
            if args.keep_albedo:
                albedo = centre
                if albedo.size != (target_w, target_h):
                    albedo = albedo.resize((target_w, target_h), Image.LANCZOS)
                # Put the source's alpha back. composite_for_generation flattens
                # RGBA to RGB before generation, because a diffusion model given
                # transparent pixels invents colour in them, and nothing has
                # restored it by this point: mask_transparent_regions below runs
                # on the normal and spec maps, never on the albedo. Saved as it
                # stands, a flower or a ladder or a torch becomes a solid
                # rectangle of its own average colour. NEAREST because the alpha
                # of a plant sprite is a hard mask and must not be feathered.
                albedo = restore_alpha(src, albedo)
                albedo.save(os.path.join(args.out, stem + "_albedo.png"))
            done += 1
            print("  [%d/%d] %-34s %-6s seam %.2f | %s" %
                    (i, len(names), stem, "tile" if use_tile else "single", seam,
                     channel_summary(dst, sdst)))
        except Exception as e:  # keep going; one bad texture is not the run
            failed += 1
            print("  [%d/%d] %-34s FAILED %s" % (i, len(names), stem, str(e)[:120]))

    print("baked %d, skipped %d (%d animation strips), failed %d" %
            (done, skipped + skipped_animation, skipped_animation, failed))
    return 1 if failed and not done else 0


if __name__ == "__main__":
    sys.exit(main())
