// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
#include "goanna_flame.h"

#include "IImage.h"

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <algorithm>
#include <cmath>

namespace goanna {
using namespace godot;

std::vector<std::string> flameTextureWords(const std::string &texture) {
    // The first image only: what follows a '^' is a modifier or an overlay,
    // and a bracket opens a group whose first image is the base.
    size_t start = texture.find_first_not_of('(');
    if (start == std::string::npos)
        return {};
    size_t end = texture.find_first_of("^)", start);
    std::string base = texture.substr(start, end == std::string::npos ? std::string::npos : end - start);
    const size_t dot = base.rfind('.');
    if (dot != std::string::npos)
        base = base.substr(0, dot);
    std::vector<std::string> words;
    std::string word;
    for (char c : base) {
        const char l = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
        if ((l >= 'a' && l <= 'z') || (l >= '0' && l <= '9')) {
            word += l;
        } else if (!word.empty()) {
            words.push_back(word);
            word.clear();
        }
    }
    if (!word.empty())
        words.push_back(word);
    return words;
}

bool flameTextureName(const std::string &texture) {
    for (const std::string &w : flameTextureWords(texture))
        if (w == "fire" || w == "flame" || w == "flames")
            return true;
    return false;
}

bool flameTile(NodeDrawType drawtype, u8 light_source, const std::string &texture,
        bool animated) {
    if (drawtype == NDT_FIRELIKE)
        return !texture.empty();
    if (light_source == 0 || !animated)
        return false;
    switch (drawtype) {
    case NDT_MESH:
    case NDT_PLANTLIKE:
    case NDT_NODEBOX:
        return flameTextureName(texture);
    default:
        return false;
    }
}

bool flameSpriteTexture(const std::string &texture) {
    return flameTextureName(texture);
}

static float toLinear(u32 c) {
    const float v = c / 255.0f;
    return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
}

FlameRamp measureFlameRamp(const std::vector<video::IImage *> &frames) {
    struct Texel { float lum, r, g, b; };
    std::vector<Texel> texels;
    for (video::IImage *image : frames) {
        if (!image)
            continue;
        const auto size = image->getDimension();
        // A frame is small (8 to 32 texels across); cap a pack's large
        // one at 64 samples a side, as the lava measure does.
        const u32 nx = std::min(64u, size.Width), ny = std::min(64u, size.Height);
        for (u32 y = 0; y < ny; ++y)
            for (u32 x = 0; x < nx; ++x) {
                const auto c = image->getPixel(x * size.Width / nx, y * size.Height / ny);
                if (c.getAlpha() < 128)
                    continue;
                Texel t;
                t.r = toLinear(c.getRed());
                t.g = toLinear(c.getGreen());
                t.b = toLinear(c.getBlue());
                t.lum = 0.2126f * t.r + 0.7152f * t.g + 0.0722f * t.b;
                texels.push_back(t);
            }
    }
    FlameRamp ramp;
    ramp.texels = (int)texels.size();
    if (texels.size() < 4)
        return ramp;
    std::sort(texels.begin(), texels.end(),
            [](const Texel &a, const Texel &b) { return a.lum < b.lum; });
    auto at = [&](float p) { return texels[(size_t)(p * (texels.size() - 1))].lum; };
    ramp.lum_low = at(0.10f);
    ramp.lum_high = std::max(ramp.lum_low + 0.02f, at(0.92f));
    // The mean colour of the brightest sixth and the darkest quarter.
    auto mean = [&](size_t from, size_t to, float out[3]) {
        double r = 0, g = 0, b = 0;
        for (size_t i = from; i < to; ++i) {
            r += texels[i].r;
            g += texels[i].g;
            b += texels[i].b;
        }
        const double n = std::max<size_t>(1, to - from);
        out[0] = (float)(r / n);
        out[1] = (float)(g / n);
        out[2] = (float)(b / n);
    };
    const size_t n = texels.size();
    mean(n - std::max<size_t>(1, n / 6), n, ramp.core);
    mean(0, std::max<size_t>(1, n / 4), ramp.tip);
    return ramp;
}

void configureFlameMaterial(const Ref<ShaderMaterial> &material, const FlameRamp &ramp,
        float light_level) {
    material->set_shader_parameter("heat_range", Vector2(ramp.lum_low, ramp.lum_high));
    material->set_shader_parameter("core_colour", Color(ramp.core[0], ramp.core[1], ramp.core[2]));
    material->set_shader_parameter("tip_colour", Color(ramp.tip[0], ramp.tip[1], ramp.tip[2]));
    // A candle (light 3) is as hot a flame as a bonfire, only smaller; the
    // light level moves the brightness a little, not to nothing.
    const float level = std::clamp(light_level / 14.0f, 0.0f, 1.0f);
    material->set_shader_parameter("flame_energy", 0.8f + 0.4f * level);
}

} // namespace goanna
