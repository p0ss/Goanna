// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_overlay_companions.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>

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

// One texel of a layer over what is under it, by mask m (0 to 1), as
// CompanionKind describes.
void mixTexel(uint8_t *dst, const uint8_t *src, float m, const CompanionKind &kind) {
    if (m <= 0.0f)
        return;
    for (int c = 0; c < 4; ++c) {
        if (kind.blend[c])
            dst[c] = (uint8_t)std::lround(dst[c] + (src[c] - dst[c]) * m);
        else if (m >= 0.5f)
            dst[c] = src[c];
    }
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
                mixTexel(dst, src, at(*l.albedo, x, y)[3] / 255.0f * opacity, kind);
            }
    }
    return out;
}

int parseImageTransform(const std::string &s) {
    // imagesource.cpp's parseImageTransform: each step is a digit or a
    // name, and the steps multiply in the dihedral group of the square.
    static const char *names[8] = {"i", "r90", "r180", "r270", "fx", nullptr, "fy", nullptr};
    int total = 0;
    size_t pos = 0;
    while (pos < s.size()) {
        int t = -1;
        for (int i = 0; i <= 7; ++i) {
            if (s[pos] == '0' + i) {
                t = i;
                pos++;
                break;
            }
            if (!names[i])
                continue;
            const size_t n = std::char_traits<char>::length(names[i]);
            std::string word = s.substr(pos, n);
            for (char &c : word)
                c = (char)std::tolower((unsigned char)c);
            if (word == names[i]) {
                t = i;
                pos += n;
                break;
            }
        }
        if (t < 0)
            break;
        int next = t < 4 ? (t + total) % 4 : (t - total + 8) % 4;
        if ((t >= 4) != (total >= 4))
            next += 4;
        total = next;
    }
    return total;
}

Rgba8 transformCompanion(const Rgba8 &img, int transform, bool tangent) {
    if (img.empty() || transform <= 0 || transform > 7)
        return img;
    // imagesource.cpp's imageTransform: the source texel of destination
    // texel (dx, dy) is entries[sxn], entries[syn] of
    // {dx, W-1-dx, dy, H-1-dy}, W and H the destination's size.
    static const int sxn_of[8] = {0, 3, 1, 2, 1, 2, 0, 3};
    static const int syn_of[8] = {2, 0, 3, 1, 2, 0, 3, 1};
    const int sxn = sxn_of[transform], syn = syn_of[transform];
    Rgba8 out;
    const bool swap = transform % 2 == 1;
    out.w = swap ? img.h : img.w;
    out.h = swap ? img.w : img.h;
    out.px.resize((size_t)out.w * out.h * 4);
    // The same map's linear part: d(source)/d(dest) as a signed
    // permutation, row 0 for x and row 1 for y. A vector at the source
    // texel turns by its transpose (the inverse, since it is orthogonal).
    auto row = [](int n, int &cx, int &cy) {
        cx = n == 0 ? 1 : n == 1 ? -1 : 0;
        cy = n == 2 ? 1 : n == 3 ? -1 : 0;
    };
    int a00, a01, a10, a11;
    row(sxn, a00, a01);
    row(syn, a10, a11);
    for (int dy = 0; dy < out.h; ++dy)
        for (int dx = 0; dx < out.w; ++dx) {
            const int entries[4] = {dx, out.w - 1 - dx, dy, out.h - 1 - dy};
            const int sx = entries[sxn], sy = entries[syn];
            const uint8_t *src = &img.px[((size_t)sy * img.w + sx) * 4];
            uint8_t *dst = &out.px[((size_t)dy * out.w + dx) * 4];
            std::copy(src, src + 4, dst);
            if (!tangent)
                continue;
            // In image axes (x right, y down) the vector is (r, -g), each
            // about 127.5; negating one is 255 - v.
            const float vx = src[0] - 127.5f, vy = -(src[1] - 127.5f);
            const float ox = a00 * vx + a10 * vy, oy = a01 * vx + a11 * vy;
            dst[0] = (uint8_t)std::lround(127.5f + ox);
            dst[1] = (uint8_t)std::lround(127.5f - oy);
        }
    return out;
}

namespace {

// A value of the texture language as composeCompanion carries it: the art,
// whose alpha is what masks a part, and its companion at whatever scale
// over the art the companion has, or nothing (neutral throughout).
struct Value {
    Rgba8 albedo;
    Rgba8 comp;
    bool any() const { return !comp.empty(); }
};

// Irrlicht's copyToScaling, which Luanti's [resize and its overlay
// upscaling use: nearest, source texel x * srcW / dstW.
Rgba8 scaled(const Rgba8 &img, int w, int h) {
    if (img.w == w && img.h == h)
        return img;
    Rgba8 out;
    out.w = w;
    out.h = h;
    out.px.resize((size_t)w * h * 4);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            const int sx = std::min(img.w - 1, (int)((int64_t)x * img.w / w));
            const int sy = std::min(img.h - 1, (int)((int64_t)y * img.h / h));
            const uint8_t *src = &img.px[((size_t)sy * img.w + sx) * 4];
            std::copy(src, src + 4, &out.px[((size_t)y * w + x) * 4]);
        }
    return out;
}

// `v` at art size w x h, its companion keeping its scale over the art.
void resizeValue(Value &v, int w, int h) {
    if (v.albedo.w == w && v.albedo.h == h)
        return;
    if (v.any()) {
        const int cw = std::max(1, (int)std::lround((double)w * v.comp.w / v.albedo.w));
        const int ch = std::max(1, (int)std::lround((double)h * v.comp.h / v.albedo.h));
        v.comp = scaled(v.comp, cw, ch);
    }
    v.albedo = scaled(v.albedo, w, h);
}

// The alpha imagesource.cpp's blit_pixel leaves in its plain (not
// overlay) mode, which both "^" and [combine blit with; colour is lerped
// as there.
void blitTexel(const uint8_t *src, uint8_t *dst) {
    const int sa = src[3], da = dst[3];
    if (sa == 0)
        return;
    if (sa == 255 || da == 0) {
        std::copy(src, src + 4, dst);
        return;
    }
    for (int c = 0; c < 3; ++c)
        dst[c] = (uint8_t)((dst[c] * (255 - sa) + src[c] * sa) / 255);
    if (da != 255)
        dst[3] = (uint8_t)(da + (255 - da) * sa * sa / (255 * 255));
}

// `top` placed into `base` with its top left corner at art texel (ox, oy),
// clipped to `base`: the albedo blitted, the companions mixed by `top`'s
// alpha at the finer of the two companion scales.
void place(Value &base, const Value &top, int ox, int oy, const CompanionKind &kind) {
    if (base.any() || top.any()) {
        auto scale = [](const Value &v, bool x) {
            if (!v.any())
                return 1.0;
            return x ? (double)v.comp.w / v.albedo.w : (double)v.comp.h / v.albedo.h;
        };
        const double kx = std::max(scale(base, true), scale(top, true));
        const double ky = std::max(scale(base, false), scale(top, false));
        Rgba8 out;
        out.w = std::max(1, (int)std::lround(base.albedo.w * kx));
        out.h = std::max(1, (int)std::lround(base.albedo.h * ky));
        out.px.resize((size_t)out.w * out.h * 4);
        auto sample = [&](const Value &v, double u, double t) -> const uint8_t * {
            if (!v.any())
                return kind.neutral;
            const int x = std::clamp((int)(u * v.comp.w / v.albedo.w), 0, v.comp.w - 1);
            const int y = std::clamp((int)(t * v.comp.h / v.albedo.h), 0, v.comp.h - 1);
            return &v.comp.px[((size_t)y * v.comp.w + x) * 4];
        };
        for (int cy = 0; cy < out.h; ++cy)
            for (int cx = 0; cx < out.w; ++cx) {
                // The art position of this companion texel's centre.
                const double u = (cx + 0.5) * base.albedo.w / out.w;
                const double t = (cy + 0.5) * base.albedo.h / out.h;
                uint8_t *dst = &out.px[((size_t)cy * out.w + cx) * 4];
                const uint8_t *under = sample(base, u, t);
                std::copy(under, under + 4, dst);
                const double tu = u - ox, tt = t - oy;
                if (tu < 0.0 || tt < 0.0 || tu >= top.albedo.w || tt >= top.albedo.h)
                    continue;
                const uint8_t *a = &top.albedo.px[((size_t)(int)tt * top.albedo.w + (int)tu) * 4];
                mixTexel(dst, sample(top, tu, tt), a[3] / 255.0f, kind);
            }
        base.comp = std::move(out);
    }
    for (int y = 0; y < top.albedo.h; ++y) {
        const int by = oy + y;
        if (by < 0 || by >= base.albedo.h)
            continue;
        for (int x = 0; x < top.albedo.w; ++x) {
            const int bx = ox + x;
            if (bx < 0 || bx >= base.albedo.w)
                continue;
            blitTexel(&top.albedo.px[((size_t)y * top.albedo.w + x) * 4],
                    &base.albedo.px[((size_t)by * base.albedo.w + bx) * 4]);
        }
    }
}

// imagesource.cpp's unescape_string: each escape character is dropped and
// the character after it kept.
std::string unescape(const std::string &s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '\\') {
            if (++i >= s.size())
                break;
        }
        out += s[i];
    }
    return out;
}

// Luanti's Strfnd, the two calls [combine is parsed with.
struct Fields {
    const std::string &str;
    size_t pos = 0;
    bool atEnd() const { return pos >= str.size(); }
    std::string next(const std::string &sep) {
        if (pos >= str.size())
            return std::string();
        size_t n = sep.empty() ? std::string::npos : str.find(sep, pos);
        if (n == std::string::npos)
            n = str.size();
        std::string ret = str.substr(pos, n - pos);
        pos = n + sep.size();
        return ret;
    }
    // Up to the next `sep` that no escape character precedes.
    std::string nextEsc(const std::string &sep) {
        if (pos >= str.size())
            return std::string();
        const size_t old = pos;
        size_t n;
        do {
            n = str.find(sep, pos);
            if (n == std::string::npos) {
                pos = n = str.size();
                break;
            }
            pos = n + sep.size();
        } while (n > 0 && str[n - 1] == '\\');
        return str.substr(old, n - old);
    }
};

constexpr int kMaxDim = 4096;

class Composer {
public:
    Composer(const CompanionKind &kind, const CompanionSources &src) : m_kind(kind), m_src(src) {}

    // generateImage: false for anything not read. `have` is false where
    // Luanti would leave no image (an empty name).
    bool image(const std::string &name, Value &out, bool &have, int depth) {
        if (depth > 32)
            return false;
        // The last '^' outside parentheses, scanning from the end and
        // passing over any character an escape precedes, as generateImage
        // does.
        long last = -1;
        int bal = 0;
        for (long i = (long)name.size() - 1; i >= 0; --i) {
            if (i > 0 && name[i - 1] == '\\')
                continue;
            const char c = name[i];
            if (c == '^' && bal == 0) {
                last = i;
                break;
            } else if (c == '(') {
                if (bal == 0)
                    return false;
                --bal;
            } else if (c == ')') {
                ++bal;
            }
        }
        if (bal > 0)
            return false;
        have = false;
        if (last >= 0 && !image(name.substr(0, last), out, have, depth + 1))
            return false;
        const std::string part = name.substr(last + 1);
        if (part.empty())
            return true;
        if (part.front() == '(' && part.back() == ')') {
            Value inner;
            bool inner_have = false;
            if (!image(part.substr(1, part.size() - 2), inner, inner_have, depth + 1) ||
                    !inner_have)
                return false;
            // A group is blitted into the corner at its own size, unscaled.
            if (have)
                place(out, inner, 0, 0, m_kind);
            else
                out = std::move(inner);
            have = true;
            return true;
        }
        return modifier(part, out, have, depth);
    }

private:
    bool modifier(const std::string &part, Value &base, bool &have, int depth) {
        if (part[0] != '[') {
            Value leaf;
            leaf.albedo = m_src.albedo(part);
            if (leaf.albedo.empty())
                return false;
            leaf.comp = m_src.companion(part);
            if (!have) {
                base = std::move(leaf);
                have = true;
                return true;
            }
            // blitBaseImage: the smaller of the two by area is scaled up
            // to the other's size, then blitted into the corner.
            if (base.albedo.w != leaf.albedo.w || base.albedo.h != leaf.albedo.h) {
                if ((int64_t)base.albedo.w * base.albedo.h <
                        (int64_t)leaf.albedo.w * leaf.albedo.h)
                    resizeValue(base, leaf.albedo.w, leaf.albedo.h);
                else
                    resizeValue(leaf, base.albedo.w, base.albedo.h);
            }
            place(base, leaf, 0, 0, m_kind);
            return true;
        }
        if (startsWith(part, "[combine")) {
            Fields sf{part};
            sf.next(":");
            const int w0 = std::atoi(sf.next("x").c_str());
            const int h0 = std::atoi(sf.next(":").c_str());
            if (!have) {
                if (w0 <= 0 || h0 <= 0 || w0 > kMaxDim || h0 > kMaxDim)
                    return false;
                base = Value();
                base.albedo.w = w0;
                base.albedo.h = h0;
                base.albedo.px.assign((size_t)w0 * h0 * 4, 0);
                have = true;
            }
            while (!sf.atEnd()) {
                const int x = std::atoi(sf.next(",").c_str());
                const int y = std::atoi(sf.next("=").c_str());
                const std::string file = unescape(sf.nextEsc(":"));
                if (x > base.albedo.w || y > base.albedo.h)
                    continue;
                Value v;
                bool part_have = false;
                if (!image(file, v, part_have, depth + 1))
                    return false;
                if (!part_have || x + v.albedo.w <= 0 || y + v.albedo.h <= 0)
                    continue;
                place(base, v, x, y, m_kind);
            }
            return true;
        }
        if (!have)
            return false;
        if (startsWith(part, "[transform")) {
            const int t = parseImageTransform(part.substr(10));
            base.albedo = transformCompanion(base.albedo, t, false);
            if (base.any())
                base.comp = transformCompanion(base.comp, t, m_kind.tangent);
            return true;
        }
        if (startsWith(part, "[resize")) {
            Fields sf{part};
            sf.next(":");
            const int w = std::atoi(sf.next("x").c_str());
            const int h = std::atoi(sf.next("").c_str());
            if (w <= 0 || h <= 0 || w > kMaxDim || h > kMaxDim)
                return false;
            resizeValue(base, w, h);
            return true;
        }
        if (startsWith(part, "[opacity:")) {
            // Integer division, then the + 0.5 floors away, as there.
            const int ratio = std::clamp(std::atoi(part.c_str() + 9), 0, 255);
            for (size_t i = 3; i < base.albedo.px.size(); i += 4)
                base.albedo.px[i] = (uint8_t)(base.albedo.px[i] * ratio / 255);
            return true;
        }
        if (part == "[noalpha") {
            for (size_t i = 3; i < base.albedo.px.size(); i += 4)
                base.albedo.px[i] = 255;
            return true;
        }
        return colourOnly(part);
    }

    const CompanionKind &m_kind;
    const CompanionSources &m_src;
};

} // namespace

Composed composeCompanion(const std::string &texture, const CompanionKind &kind,
        const CompanionSources &src, Rgba8 &out) {
    out = Rgba8();
    Composer composer(kind, src);
    Value v;
    bool have = false;
    if (!composer.image(texture, v, have, 0) || !have)
        return Composed::Unsupported;
    if (!v.any())
        return Composed::NoCompanion;
    out = std::move(v.comp);
    return Composed::Done;
}

} // namespace goanna
