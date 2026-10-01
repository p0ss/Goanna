// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_overlay_companions.h"

#include <algorithm>
#include <cmath>

namespace goanna {

namespace {

bool startsWith(const std::string &s, const char *prefix) {
    return s.compare(0, std::char_traits<char>::length(prefix), prefix) == 0;
}

// Splits at '^' outside parentheses. False on unbalanced parentheses.
bool splitTopLevel(const std::string &s, std::vector<std::string> &parts) {
    parts.clear();
    int depth = 0;
    std::string cur;
    for (char c : s) {
        if (c == '(')
            ++depth;
        else if (c == ')' && --depth < 0)
            return false;
        if (c == '^' && depth == 0) {
            parts.push_back(cur);
            cur.clear();
        } else {
            cur += c;
        }
    }
    parts.push_back(cur);
    return depth == 0;
}

// The modifiers that recolour what they apply to and leave its alpha alone.
bool colourOnly(const std::string &part) {
    return part == "[brighten" || startsWith(part, "[colorize:") ||
            startsWith(part, "[multiply:") || startsWith(part, "[screen:") ||
            startsWith(part, "[hsl:") || startsWith(part, "[colorizehsl:") ||
            startsWith(part, "[contrast:");
}

bool plainImage(const std::string &part) {
    return !part.empty() && part.find_first_of("[]():") == std::string::npos;
}

} // namespace

bool parseOverlayLayers(const std::string &texture, std::vector<OverlayLayer> &out) {
    out.clear();
    // An escaped character means a name or argument holding one of the
    // separators; rare in skins and not worth reading here.
    if (texture.empty() || texture.find('\\') != std::string::npos)
        return false;
    std::vector<std::string> parts;
    if (!splitTopLevel(texture, parts))
        return false;
    for (const std::string &part : parts) {
        if (plainImage(part)) {
            out.push_back({part, 1.0f});
        } else if (part.size() > 2 && part.front() == '(' && part.back() == ')') {
            std::vector<std::string> inner;
            const std::string body = part.substr(1, part.size() - 2);
            if (body.find_first_of("()") != std::string::npos || !splitTopLevel(body, inner) ||
                    !plainImage(inner[0])) {
                out.clear();
                return false;
            }
            OverlayLayer layer{inner[0], 1.0f};
            for (size_t i = 1; i < inner.size(); ++i) {
                if (startsWith(inner[i], "[opacity:")) {
                    // Luanti reads the ratio with mystoi(.., 0, 255).
                    const std::string arg = inner[i].substr(9);
                    if (arg.empty() || arg.find_first_not_of("0123456789") != std::string::npos) {
                        out.clear();
                        return false;
                    }
                    layer.opacity *= std::min(std::stoi(arg), 255) / 255.0f;
                } else if (!colourOnly(inner[i])) {
                    out.clear();
                    return false;
                }
            }
            out.push_back(layer);
        } else if (!out.empty() && colourOnly(part)) {
            // Recolours the stack so far; coverage is unchanged.
        } else {
            out.clear();
            return false;
        }
    }
    return !out.empty();
}

std::vector<std::string> companionNames(const std::string &image, const char *suffix) {
    const size_t dot = image.rfind('.');
    const std::string stem = dot == std::string::npos ? image : image.substr(0, dot);
    const std::string ext = dot == std::string::npos ? std::string() : image.substr(dot);
    std::vector<std::string> names{stem + suffix + ext};
    static const std::string mask = "_mask";
    if (stem.size() > mask.size() &&
            stem.compare(stem.size() - mask.size(), mask.size(), mask) == 0)
        names.push_back(stem.substr(0, stem.size() - mask.size()) + suffix + ext);
    return names;
}

Rgba8 compositeCompanions(const std::vector<CompanionLayer> &layers, const CompanionKind &kind) {
    Rgba8 out;
    if (layers.empty())
        return out;
    for (const CompanionLayer &l : layers)
        for (const Rgba8 *img : {l.albedo, l.companion})
            if (img && !img->empty()) {
                out.w = std::max(out.w, img->w);
                out.h = std::max(out.h, img->h);
            }
    if (out.w <= 0 || out.h <= 0) {
        out.w = out.h = 0;
        return out;
    }
    out.px.resize((size_t)out.w * out.h * 4);
    // Nearest sample of `img` at output texel (x, y).
    auto at = [&](const Rgba8 &img, int x, int y) -> const uint8_t * {
        const int sx = std::min(img.w - 1, (int)((int64_t)x * img.w / out.w));
        const int sy = std::min(img.h - 1, (int)((int64_t)y * img.h / out.h));
        return &img.px[((size_t)sy * img.w + sx) * 4];
    };
    for (size_t li = 0; li < layers.size(); ++li) {
        const CompanionLayer &l = layers[li];
        const bool has_comp = l.companion && !l.companion->empty();
        const bool has_mask = l.albedo && !l.albedo->empty();
        if (li > 0 && !has_mask)
            continue;
        const float opacity = std::clamp(l.opacity, 0.0f, 1.0f);
        for (int y = 0; y < out.h; ++y)
            for (int x = 0; x < out.w; ++x) {
                uint8_t *dst = &out.px[((size_t)y * out.w + x) * 4];
                const uint8_t *src = has_comp ? at(*l.companion, x, y) : kind.neutral;
                if (li == 0) {
                    std::copy(src, src + 4, dst);
                    continue;
                }
                const float m = at(*l.albedo, x, y)[3] / 255.0f * opacity;
                if (m <= 0.0f)
                    continue;
                for (int c = 0; c < 4; ++c) {
                    if (kind.blend[c])
                        dst[c] = (uint8_t)std::lround(dst[c] + (src[c] - dst[c]) * m);
                    else if (m >= 0.5f)
                        dst[c] = src[c];
                }
            }
    }
    return out;
}

} // namespace goanna
