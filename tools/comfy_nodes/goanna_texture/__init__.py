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
        return (seam, "seam %.2f (%s)" % (seam, verdict))


NODE_CLASS_MAPPINGS = {
    "GoannaTile3x3": GoannaTile3x3,
    "GoannaCropCentre": GoannaCropCentre,
    "GoannaDeepBumpNormals": GoannaDeepBumpNormals,
    "GoannaNormalsToHeight": GoannaNormalsToHeight,
    "GoannaSeamEnergy": GoannaSeamEnergy,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "GoannaTile3x3": "Goanna: tile 3x3",
    "GoannaCropCentre": "Goanna: crop centre",
    "GoannaDeepBumpNormals": "Goanna: DeepBump normals",
    "GoannaNormalsToHeight": "Goanna: normals to height",
    "GoannaSeamEnergy": "Goanna: seam energy",
}

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
