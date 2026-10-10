// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
#pragma once

// Which tiles and sprites are flames, and the measure of a flame's own art
// that flame.gdshader ramps its colour along. docs/systems/fire-material.md.
#include <string>
#include <vector>

#include <godot_cpp/classes/shader_material.hpp>

#include "nodedef.h"

namespace video { class IImage; }

namespace goanna {

// The words of a texture's first image, lower case, split at anything that
// is not a letter or a digit: "mcl_campfires_campfire_fire.png^[opacity:9"
// gives mcl, campfires, campfire, fire.
std::vector<std::string> flameTextureWords(const std::string &texture);

// A name that says flame: the word fire, flame or flames. Not "firefly",
// "campfires" or "fireflies", which are other words.
bool flameTextureName(const std::string &texture);

// One tile of a node is a flame when the node draws as fire (the firelike
// drawtype, every tile of it), or when a glowing node of a shape that can
// hold a flame (a mesh, a plant, a node box) shows an animated tile named
// for one: Mineclonia's campfire and candle flames, x_farming's candles.
// The animation rules out fire coral, Ethereal's fire flower and Kythen's
// lamp faces, which are still images; the shape rules out a cube face.
bool flameTile(NodeDrawType drawtype, u8 light_source, const std::string &texture,
        bool animated);

// An entity sprite that is a flame: an upright sprite (Mineclonia's and
// VoxeLibre's burning entity) whose texture is named for one.
bool flameSpriteTexture(const std::string &texture);

// The art's own ramp, measured in linear colour over its opaque texels in
// every frame given: the luminance range the heat is spread over, and the
// mean colour of its brightest and darkest texels, which become the core
// and the tips. Soul fire's art is cyan, so its ramp is.
struct FlameRamp {
    float lum_low = 0.05f, lum_high = 0.6f;
    float core[3] = {1.0f, 0.85f, 0.45f};
    float tip[3] = {0.6f, 0.12f, 0.02f};
    int texels = 0;
};
FlameRamp measureFlameRamp(const std::vector<video::IImage *> &frames);
void configureFlameMaterial(const godot::Ref<godot::ShaderMaterial> &material,
        const FlameRamp &ramp, float light_level);

} // namespace goanna
