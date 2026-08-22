"""Goanna texture nodes: the whole bake chain, visible in the editor.

The batch script drives the same steps over the API, but a graph that stops
at the upscale only shows half the job. These make the rest of it, the 3x3
replication, the centre crop, the normal map and the seam check, into nodes
you can watch and turn dials on.

DeepBump does the colour to normals. It needs resolution to say anything:
on a raw 16 pixel tile it returns a nearly flat map (measured tilt 0.04),
and after an upscale it comes out at 0.20 to 0.35, which is the range of a
hand authored pack. So upscale first, then this.

Install: this directory sits in ComfyUI/custom_nodes. It expects DeepBump
checked out at ~/Documents/Code/deepbump and onnxruntime in the venv.
"""

import os
import sys

import numpy as np
import torch

DEEPBUMP = os.path.expanduser("~/Documents/Code/deepbump")
if DEEPBUMP not in sys.path:
    sys.path.insert(0, DEEPBUMP)


def _to_chw(image):
    """ComfyUI hands over [B,H,W,C] float 0-1; DeepBump wants C,H,W."""
    arr = image[0].cpu().numpy()
    return np.transpose(arr, (2, 0, 1)).astype(np.float32)


def _to_comfy(chw):
    arr = np.transpose(chw, (1, 2, 0)).astype(np.float32)
    return torch.from_numpy(np.clip(arr, 0.0, 1.0))[None,]


class GoannaTile3x3:
    """Replicate a tile three by three.

    This is how the result stays seamless without a circular padding node.
    Generate on the replica and keep the middle, and the centre tile's edges
    were produced with its own neighbours present, so they line up. A visible
    seam matters more here than anywhere else: a block texture repeats across
    thousands of nodes, so a seam is not one artefact but a grid of them.
    """

    CATEGORY = "goanna"
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"image": ("IMAGE",)}}

    def run(self, image):
        return (image.repeat(1, 3, 3, 1),)


class GoannaCropCentre:
    """Keep the middle ninth, which is the tile that had neighbours."""

    CATEGORY = "goanna"
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"image": ("IMAGE",)}}

    def run(self, image):
        h, w = image.shape[1], image.shape[2]
        return (image[:, h // 3:2 * (h // 3), w // 3:2 * (w // 3), :],)


class GoannaDeepBumpNormals:
    """Colour to tangent normals, by DeepBump's trained model.

    Unlike a gradient of luminance, which is what our own inference does and
    which correlates 1.00 with the image by construction, this infers: on the
    same textures it correlates between +0.05 and -0.35, so it is deciding
    what is relief and what is merely dark paint.
    """

    CATEGORY = "goanna"
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "image": ("IMAGE",),
            "overlap": (["SMALL", "MEDIUM", "LARGE"], {"default": "LARGE"}),
        }}

    def run(self, image, overlap):
        import module_color_to_normals
        out = module_color_to_normals.apply(_to_chw(image), overlap, None)
        return (_to_comfy(out),)


class GoannaNormalsToHeight:
    """Height from normals, for parallax later. Tell it if the tile is seamless."""

    CATEGORY = "goanna"
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "normals": ("IMAGE",),
            "seamless": ("BOOLEAN", {"default": True}),
        }}

    def run(self, normals, seamless):
        import module_normals_to_height
        out = module_normals_to_height.apply(_to_chw(normals), seamless, None)
        if out.shape[0] == 1:
            out = np.repeat(out, 3, axis=0)
        return (_to_comfy(out),)


class GoannaSeamEnergy:
    """Report how badly a tile fails to repeat. Under 1.0 is seamless.

    Compares the wrap around edge difference against the difference one row
    or column inside. A tile that joins itself no worse than it varies
    internally scores near or below 1; a visible seam scores well above it.
    Worth watching while turning denoise up, because that is the dial that
    breaks tiling first.
    """

    CATEGORY = "goanna"
    RETURN_TYPES = ("FLOAT", "STRING")
    RETURN_NAMES = ("seam", "report")
    FUNCTION = "run"
    OUTPUT_NODE = True

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"image": ("IMAGE",)}}

    def run(self, image):
        a = image[0].cpu().numpy().astype(np.float32)
        wrap = (np.abs(a[0, :] - a[-1, :]).mean() + np.abs(a[:, 0] - a[:, -1]).mean())
        inner = (np.abs(a[0, :] - a[1, :]).mean() + np.abs(a[:, 0] - a[:, 1]).mean())
        seam = float(wrap / max(inner, 1e-6))
        verdict = "seamless" if seam <= 1.2 else ("marginal" if seam <= 2.0 else "VISIBLE SEAM")
        text = "seam %.2f (%s)" % (seam, verdict)
        # OUTPUT_NODE only makes it run. Showing anything needs a ui dict,
        # otherwise the node computes a number and quietly keeps it.
        return {"ui": {"text": [text]}, "result": (seam, text)}


class GoannaAOFromHeight:
    """Ambient occlusion from a height map, wrapping at the edges.

    Ours rather than ComfyUI-Texture-Simple's, which has the node we wanted
    but whose package does not register under ComfyUI 0.33: its __init__
    uses a relative import that the loader does not satisfy, then falls back
    to a bare one that is not on the path.

    Samples in a ring of directions and asks, for each, whether the terrain
    rises enough along it to block the sky. Wrapping matters as much here as
    everywhere else in this chain: a tile darkened at its edges reads as a
    grid of shadows once it repeats.
    """

    CATEGORY = "goanna"
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "height": ("IMAGE",),
            "strength": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 4.0, "step": 0.05}),
            "radius_px": ("INT", {"default": 6, "min": 1, "max": 64}),
            "directions": ("INT", {"default": 8, "min": 4, "max": 32}),
        }}

    def run(self, height, strength, radius_px, directions):
        h = height[0].cpu().numpy().mean(axis=2).astype(np.float32)
        occ = np.zeros_like(h)
        for d in range(directions):
            ang = 2.0 * np.pi * d / directions
            dx, dy = np.cos(ang), np.sin(ang)
            horizon = np.zeros_like(h)
            for r in range(1, radius_px + 1):
                sx, sy = int(round(dx * r)), int(round(dy * r))
                shifted = np.roll(np.roll(h, -sy, axis=0), -sx, axis=1)
                # how far the neighbour rises, per unit distance
                horizon = np.maximum(horizon, (shifted - h) / float(r))
            occ += np.clip(horizon, 0.0, None)
        occ = occ / float(directions)
        ao = np.clip(1.0 - occ * strength * 4.0, 0.0, 1.0)
        return (_to_comfy(np.repeat(ao[None, ...], 3, axis=0)),)


class GoannaSaveLabPBR:
    """Write the LabPBR pair that Goanna's shader decodes.

    Not a generic channel packer, because LabPBR is a specification with
    sharp edges and getting them wrong fails quietly. Alpha 255 in the
    specular map means no emission rather than full emission. The blue
    channel is two materials sharing one range, porosity up to 64 and
    subsurface scattering from 65. Green above 229 stops being a
    reflectance and becomes an index into a metal table. Encoding that in
    one place beats rebuilding it out of general nodes each time.

    Also writes the files itself rather than handing back an image, because
    both maps carry data in alpha and ComfyUI's IMAGE is RGB, with alpha
    living separately as a MASK.

      _n   R,G tangent normal   B ambient occlusion   A height
      _s   R smoothness   G F0 or metal   B porosity/SSS   A emission
    """

    CATEGORY = "goanna"
    RETURN_TYPES = ("STRING",)
    RETURN_NAMES = ("report",)
    FUNCTION = "run"
    OUTPUT_NODE = True

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "normals": ("IMAGE",),
                "name": ("STRING", {"default": "texture"}),
                "out_dir": ("STRING", {"default": "goanna_labpbr"}),
                "smoothness": ("FLOAT", {"default": 0.2, "min": 0.0, "max": 1.0, "step": 0.01}),
                "f0": ("FLOAT", {"default": 0.04, "min": 0.0, "max": 0.9, "step": 0.01,
                                 "tooltip": "dielectric reflectance; 0.04 is ordinary"}),
                "metal": ("BOOLEAN", {"default": False}),
                "sss": ("FLOAT", {"default": 0.0, "min": 0.0, "max": 1.0, "step": 0.01,
                                  "tooltip": "leaves, ice, thin things"}),
                "porosity": ("FLOAT", {"default": 0.0, "min": 0.0, "max": 1.0, "step": 0.01,
                                       "tooltip": "ignored unless sss is 0"}),
                "emission": ("FLOAT", {"default": 0.0, "min": 0.0, "max": 1.0, "step": 0.01}),
            },
            "optional": {"height": ("IMAGE",), "ao": ("IMAGE",)},
        }

    def run(self, normals, name, out_dir, smoothness, f0, metal, sss, porosity,
            emission, height=None, ao=None):
        import folder_paths
        from PIL import Image

        base = os.path.join(folder_paths.get_output_directory(), out_dir)
        os.makedirs(base, exist_ok=True)
        n = (normals[0].cpu().numpy() * 255.0).clip(0, 255)
        h, w = n.shape[0], n.shape[1]

        def grey(img, default):
            if img is None:
                return np.full((h, w), default, dtype=np.float32)
            a = img[0].cpu().numpy()
            g = a.mean(axis=2) * 255.0
            if g.shape != (h, w):
                g = np.asarray(Image.fromarray(g.astype(np.uint8)).resize((w, h),
                        Image.LANCZOS), dtype=np.float32)
            return g

        nmap = np.zeros((h, w, 4), dtype=np.uint8)
        nmap[..., 0] = n[..., 0]
        nmap[..., 1] = n[..., 1]
        nmap[..., 2] = grey(ao, 255).clip(0, 255)          # 255 is unoccluded
        nmap[..., 3] = grey(height, 255).clip(0, 255)       # 255 is flat

        # Green: 0..229 is F0 held linearly, 230..254 name a metal, and 255
        # says to use the albedo as F0, which is what we want for a metal we
        # have no table entry for.
        g_val = 255 if metal else int(round(min(f0, 229.0 / 255.0) * 255))
        # Blue: porosity lives at or below 64, scattering from 65 up.
        if sss > 0.0:
            b_val = int(round(65 + sss * (255 - 65)))
        else:
            b_val = int(round(porosity * 64))
        # Alpha: 255 means none, so full emission is 254.
        a_val = 255 if emission <= 0.0 else int(round(min(emission, 1.0) * 254))

        smap = np.zeros((h, w, 4), dtype=np.uint8)
        smap[..., 0] = int(round(smoothness * 255))
        smap[..., 1] = g_val
        smap[..., 2] = b_val
        smap[..., 3] = a_val

        np_path = os.path.join(base, name + "_n.png")
        sp_path = os.path.join(base, name + "_s.png")
        Image.fromarray(nmap, "RGBA").save(np_path)
        Image.fromarray(smap, "RGBA").save(sp_path)
        report = ("wrote %s_n.png and %s_s.png (%dx%d) | smoothness %d, "
                "green %d (%s), blue %d (%s), alpha %d (%s)" % (
                    name, name, w, h, smap[0, 0, 0], g_val,
                    "albedo as F0" if metal else "F0",
                    b_val, "SSS" if sss > 0 else "porosity",
                    a_val, "no emission" if a_val == 255 else "emissive"))
        return {"ui": {"text": [report]}, "result": (report,)}


NODE_CLASS_MAPPINGS = {
    "GoannaTile3x3": GoannaTile3x3,
    "GoannaCropCentre": GoannaCropCentre,
    "GoannaDeepBumpNormals": GoannaDeepBumpNormals,
    "GoannaNormalsToHeight": GoannaNormalsToHeight,
    "GoannaSeamEnergy": GoannaSeamEnergy,
    "GoannaAOFromHeight": GoannaAOFromHeight,
    "GoannaSaveLabPBR": GoannaSaveLabPBR,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "GoannaTile3x3": "Goanna: tile 3x3",
    "GoannaCropCentre": "Goanna: crop centre",
    "GoannaDeepBumpNormals": "Goanna: DeepBump normals",
    "GoannaNormalsToHeight": "Goanna: normals to height",
    "GoannaSeamEnergy": "Goanna: seam energy",
    "GoannaAOFromHeight": "Goanna: AO from height",
    "GoannaSaveLabPBR": "Goanna: save LabPBR pair",
}

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]

print("[goanna_texture] registering %d nodes from %s" % (len(NODE_CLASS_MAPPINGS), __file__))
