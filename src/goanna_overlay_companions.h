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
// stack parseOverlayLayers reads.
//
// composeCompanion reads more: the texture modifier language as Luanti's
// ImageSource::generateImage evaluates it (overlays, parenthesised groups,
// [combine with escaped and nested parts, [transform, [resize, [opacity,
// [noalpha, [mask and the colour-only modifiers), and builds the companion
// the same way the albedo is built: each part's companion placed where the
// part is placed, transformed as it is transformed, covering what the part
// covers. The node path uses it for a tile string such as
// "mcl_nether_netherrack.png^crimson_nylium_side.png" or a chiseled
// bookshelf's "[combine:16x16:...", an item for
// "screwdriver.png^[transformFX", an entity for a banner's [mask cut pole
// and cloth. Anything else (a frame cut, a crack, [fill, [inventorycube) is
// not read, and the caller keeps its single image lookup.

#include <cstdint>
#include <functional>
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
//
// tangent says R and G hold a tangent space vector, which a rotation or a
// flip of the image has to turn with it (transformCompanion).
struct CompanionKind {
    uint8_t neutral[4];
    bool blend[4];
    bool tangent = false;
};
constexpr CompanionKind kNormalKind{{128, 128, 255, 255}, {true, true, true, true}, true};
constexpr CompanionKind kSpecKind{{0, 10, 0, 255}, {true, false, false, false}, false};

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

// Luanti's [transform argument (a digit 0 to 7 or names such as "FXR90",
// concatenated names multiplied in order) as the transform number 0 to 7:
// 0 identity, 1 R90, 2 R180, 3 R270 (rotations counter-clockwise), 4 FX,
// 5 FXR90, 6 FY, 7 FYR90. The same reading as imagesource.cpp's
// parseImageTransform.
int parseImageTransform(const std::string &s);

// `img` transformed as [transform<t> transforms an image: texel (dx, dy) of
// the result is the source texel imagesource.cpp's imageTransform picks.
// With `tangent`, R and G are a tangent vector (R toward +x of the image, G
// toward its top, the way the shaders decode _n against Godot's binormal)
// and turn with the image. 255 - v negates a channel exactly about the
// 127.5 the decode v / 255 * 2 - 1 treats as zero (so a flat 128 comes
// back 127, a lean of 1/255), and:
//   FX (4)     R = 255 - R
//   FY (6)     G = 255 - G
//   R180 (2)   both negated
//   R90 (1)    R = 255 - G, G = R    (counter-clockwise: right turns to up)
//   R270 (3)   R = G, G = 255 - R
//   FXR90 (5)  R = 255 - G, G = 255 - R
//   FYR90 (7)  R = G, G = R          (a reflection in the diagonal)
// B (occlusion) and A (height) are scalars and only move.
Rgba8 transformCompanion(const Rgba8 &img, int transform, bool tangent);

// Where composeCompanion reads a plain image ("x.png", never a modifier).
// Either may return an empty image: an unknown albedo makes the texture
// unreadable, a missing companion makes that part neutral.
struct CompanionSources {
    std::function<Rgba8(const std::string &)> albedo;
    std::function<Rgba8(const std::string &)> companion;
};

enum class Composed {
    Unsupported, // uses something this does not read; keep the plain lookup
    NoCompanion, // read, but no part has a companion of this kind
    Done,        // `out` holds the composed companion
};

// The companion of kind `kind` for `texture`, built the way Luanti builds
// the texture itself (see the top of this file). Resolution: every value
// carries its companion at its own scale over its art, and placing one in
// another takes the finer of the two, so an eight times map stays eight
// times when it is laid into a sixteen texel [combine canvas. Where a part
// covers (its albedo alpha, the mask), its companion mixes over what is
// under it as compositeCompanions mixes a layer; a part with no companion
// of its own is the kind's neutral there, and canvas nothing covers is
// neutral too.
//
// Depth without colour. A part covers by its albedo's alpha, so a part can
// only carry relief where it also paints over the colour beneath. A carving
// wants the opposite: the stone's own colour on the floor of the cut, one
// level down. So an image that is transparent in every texel and has an _n
// of its own is a cut. Its _n is laid in where it is transparent (which is
// everywhere) by cutTexel rather than by its alpha: the lower of the two
// heights, the cut's normal where the cut is the lower or where it leans
// (its lip), and the two occlusions multiplied. A flat uncut texel (128,
// 128, 255, 255) changes nothing. A value such an image is placed into
// (a [combine canvas of cut glyphs, the group around it) carries the cut on
// into whatever it is placed over, through its own transparent texels. The
// colour of the result is the albedo's, untouched, since a transparent
// image blits nothing. _s is not affected: a cut changes no material, and
// a transparent part mixes no _s. A vanilla client draws a transparent
// image as nothing, so a pack (or a server) can ship cut glyphs without
// changing what any other client sees. [noalpha ends it.
Composed composeCompanion(const std::string &texture, const CompanionKind &kind,
        const CompanionSources &src, Rgba8 &out);

} // namespace goanna
