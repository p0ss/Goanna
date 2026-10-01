// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// LabPBR companions for a texture that is a stack of overlays.
//
// Mob skins are often built on the server as overlays: Mineclonia draws a
// villager as "mobs_mc_villager_base.png^mobs_mc_villager_plains.png^
// mobs_mc_villager_profession_farmer.png^mobs_mc_stone.png" and a damaged
// iron golem as "mobs_mc_iron_golem.png^(mobs_mc_iron_golem_crack_low.png^
// [opacity:180)". The companions for such a texture have to be composited
// the same way, or the base layer's relief and smoothness show through the
// clothes laid over it. This file holds the parts of that which need no
// Godot: reading the stack out of the texture string, and compositing
// companion images with each layer's albedo alpha as the mask.
//
// Only a plain stack is read: image names, a parenthesised group of one
// image with [opacity, and modifiers that change colour only ([brighten,
// [colorize, [multiply, [screen, [hsl, [colorizehsl, [contrast), which leave
// every layer's shape and coverage alone. Anything else ([combine,
// [transform, [mask, [resize, a frame cut, nested groups, escapes) is not a
// stack this can composite, and the caller keeps its single image lookup.

#include <cstdint>
#include <string>
#include <vector>

namespace goanna {

// One layer of an overlay stack: the image and the opacity a [opacity in its
// group applied to it, 0 to 1.
struct OverlayLayer {
    std::string image;
    float opacity = 1.0f;
};

// The layers of `texture`, bottom first, into `out`. False (with `out`
// empty) for a texture that is not a plain stack as described above. A
// single image, with or without colour modifiers, is a stack of one.
bool parseOverlayLayers(const std::string &texture, std::vector<OverlayLayer> &out);

// The names `image`'s LabPBR companion may go by, in the order to try them:
// "x.png" with suffix "_n" is "x_n.png". A colouring mask also tries the
// part it colours: Mineclonia's player skins draw each part as
// "(mcl_skins_hair_3_mask.png^[colorize:#rrggbb:alpha)^mcl_skins_hair_3.png"
// (its first person hand without the brackets), the mask coloured to the
// player's choice and the part's shading laid over it. Colour is not
// material, so the mask takes "mcl_skins_hair_3_mask_n.png" when a pack
// has one, and "mcl_skins_hair_3_n.png" otherwise. The part's name is the
// one to author: the shading layer over the mask takes it as well, where a
// mask's own companion would leave the shading layer flat.
std::vector<std::string> companionNames(const std::string &image, const char *suffix);

// A plain RGBA8 image, rows top to bottom. Empty (w == 0) means none.
struct Rgba8 {
    int w = 0, h = 0;
    std::vector<uint8_t> px;
    bool empty() const { return w <= 0 || h <= 0; }
};

// How one kind of companion composites. neutral is what a layer with no
// companion of its own contributes where it covers: for _n a flat normal
// with no occlusion and full height, for _s a rough dielectric at LabPBR's
// plain F0 (10), no porosity or scattering, and 255 in A, which is LabPBR's
// "no emission". A clothes layer with nothing authored is therefore flat and
// rough, not the relief of the skin under it.
//
// blend says which channels mix by the mask. The rest are categorical and
// are taken whole from the layer that dominates the texel (mask 0.5 or
// more): _s green is F0 below 230 and a metal from 230, blue is porosity
// below 65 and scattering from 65, alpha is emission below 255 and none at
// 255. Mixing them invents a material in neither layer: a golem's crack
// (a dielectric _s at 180/255 opacity) over its metal blended green to about
// 84, which the shader reads as a dielectric with the largest specular it
// has. So _s mixes smoothness only; _n mixes everything.
struct CompanionKind {
    uint8_t neutral[4];
    bool blend[4];
};
constexpr CompanionKind kNormalKind{{128, 128, 255, 255}, {true, true, true, true}};
constexpr CompanionKind kSpecKind{{0, 10, 0, 255}, {true, false, false, false}};

// One layer's inputs: its albedo (whose alpha, times opacity, is the mask)
// and its companion, either of which may be empty. A layer whose albedo is
// empty covers nothing.
struct CompanionLayer {
    const Rgba8 *albedo = nullptr;
    const Rgba8 *companion = nullptr;
    float opacity = 1.0f;
};

// Composite companions bottom to top: the first layer's companion (or the
// kind's neutral) everywhere, then each later layer's companion (or the
// neutral) over it by that layer's mask, as `kind` says per channel. Every
// input is sampled nearest at the largest width and largest height among
// them, the way Luanti scales the smaller image of an overlay up to the
// larger, so a companion authored at eight map texels per art texel keeps
// its resolution. Empty if `layers` is.
Rgba8 compositeCompanions(const std::vector<CompanionLayer> &layers, const CompanionKind &kind);

} // namespace goanna
