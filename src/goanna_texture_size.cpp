// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_texture_size.h"

#include <algorithm>
#include <cmath>

namespace goanna {

static bool endsWith(const std::string &s, const char *tail) {
    const size_t n = std::char_traits<char>::length(tail);
    return s.size() >= n && s.compare(s.size() - n, n, tail) == 0;
}

MapKind mapKindOf(const std::string &name) {
    if (endsWith(name, "_n.png"))
        return MapKind::Normal;
    if (endsWith(name, "_s.png"))
        return MapKind::Spec;
    return MapKind::Albedo;
}

std::string artNameOf(const std::string &name) {
    if (mapKindOf(name) == MapKind::Albedo)
        return name;
    return name.substr(0, name.size() - 6) + ".png";
}

bool cappedSize(uint32_t w, uint32_t h, uint32_t art_w, uint32_t art_h, uint32_t cap,
        uint32_t &tw, uint32_t &th) {
    tw = w;
    th = h;
    if (!cap || !w || !h || !art_w || !art_h)
        return false;
    // Pixels per texel along each axis; the larger decides, so a single
    // still map shipped for an animation strip is held by its width.
    const double r = std::max((double)w / art_w, (double)h / art_h);
    if (r <= (double)cap + 1e-9)
        return false;
    const double s = (double)cap / r;
    tw = std::max<uint32_t>(1, (uint32_t)std::lround(w * s));
    th = std::max<uint32_t>(1, (uint32_t)std::lround(h * s));
    return tw < w || th < h;
}

namespace {

// The source pixels one output pixel covers along an axis, with weights.
struct Span {
    int first = 0;
    std::vector<double> weight;
};

std::vector<Span> spans(int src, int dst) {
    std::vector<Span> out((size_t)dst);
    const double scale = (double)src / dst;
    for (int o = 0; o < dst; ++o) {
        const double a = o * scale, b = (o + 1) * scale;
        Span &sp = out[(size_t)o];
        sp.first = (int)std::floor(a);
        const int last = std::min(src - 1, (int)std::ceil(b) - 1);
        for (int i = sp.first; i <= last; ++i) {
            const double w = std::min(b, (double)i + 1) - std::max(a, (double)i);
            sp.weight.push_back(std::max(0.0, w));
        }
    }
    return out;
}

uint8_t toByte(double v) {
    return (uint8_t)std::clamp((int)std::lround(v), 0, 255);
}

} // namespace

std::vector<uint8_t> downscaleRgba8(const uint8_t *src, int w, int h, int tw, int th,
        MapKind kind) {
    std::vector<uint8_t> out((size_t)tw * th * 4);
    const std::vector<Span> sx = spans(w, tw), sy = spans(h, th);
    struct Sample {
        const uint8_t *p;
        double w;
    };
    std::vector<Sample> samples;
    for (int oy = 0; oy < th; ++oy)
        for (int ox = 0; ox < tw; ++ox) {
            samples.clear();
            const Span &yy = sy[(size_t)oy], &xx = sx[(size_t)ox];
            for (size_t j = 0; j < yy.weight.size(); ++j)
                for (size_t i = 0; i < xx.weight.size(); ++i) {
                    const double wt = yy.weight[j] * xx.weight[i];
                    if (wt > 0.0)
                        samples.push_back({src + ((size_t)(yy.first + (int)j) * w
                                + (size_t)(xx.first + (int)i)) * 4, wt});
                }
            uint8_t *d = &out[((size_t)oy * tw + ox) * 4];
            // A block of one value is that value, exactly: nothing a
            // renormalisation or a rounding could move.
            bool same = true;
            for (const Sample &s : samples)
                if (!std::equal(s.p, s.p + 4, samples[0].p)) {
                    same = false;
                    break;
                }
            if (same) {
                std::copy(samples[0].p, samples[0].p + 4, d);
                continue;
            }
            double total = 0.0;
            for (const Sample &s : samples)
                total += s.w;
            if (kind == MapKind::Albedo) {
                double a = 0.0, r = 0.0, g = 0.0, b = 0.0, pr = 0.0, pg = 0.0, pb = 0.0;
                for (const Sample &s : samples) {
                    const double al = s.p[3] / 255.0;
                    a += s.w * al;
                    pr += s.w * al * s.p[0];
                    pg += s.w * al * s.p[1];
                    pb += s.w * al * s.p[2];
                    r += s.w * s.p[0];
                    g += s.w * s.p[1];
                    b += s.w * s.p[2];
                }
                // Colour weighted by coverage, so a cut-out's hidden colour
                // does not bleed into the edge it shares with drawn texels.
                if (a > 1e-6) {
                    d[0] = toByte(pr / a);
                    d[1] = toByte(pg / a);
                    d[2] = toByte(pb / a);
                } else {
                    d[0] = toByte(r / total);
                    d[1] = toByte(g / total);
                    d[2] = toByte(b / total);
                }
                d[3] = toByte(255.0 * a / total);
            } else if (kind == MapKind::Normal) {
                double vx = 0.0, vy = 0.0, vz = 0.0, ao = 0.0, ht = 0.0;
                for (const Sample &s : samples) {
                    const double x = s.p[0] / 255.0 * 2.0 - 1.0;
                    const double y = s.p[1] / 255.0 * 2.0 - 1.0;
                    const double z = std::sqrt(std::max(0.0, 1.0 - x * x - y * y));
                    const double len = std::sqrt(x * x + y * y + z * z);
                    vx += s.w * x / len;
                    vy += s.w * y / len;
                    vz += s.w * z / len;
                    ao += s.w * s.p[2];
                    ht += s.w * s.p[3];
                }
                const double len = std::sqrt(vx * vx + vy * vy + vz * vz);
                if (len > 1e-9) {
                    vx /= len;
                    vy /= len;
                } else {
                    vx = vy = 0.0;
                }
                d[0] = toByte((vx * 0.5 + 0.5) * 255.0);
                d[1] = toByte((vy * 0.5 + 0.5) * 255.0);
                d[2] = toByte(ao / total);
                d[3] = toByte(ht / total);
            } else {
                double sm = 0.0;
                for (const Sample &s : samples)
                    sm += s.w * s.p[0];
                d[0] = toByte(sm / total);
                for (int c = 1; c < 4; ++c) {
                    // The value covering the most of this pixel, the first
                    // one met (top left) on a tie.
                    uint8_t best = samples[0].p[c];
                    double best_w = -1.0;
                    for (const Sample &s : samples) {
                        double cover = 0.0;
                        for (const Sample &t : samples)
                            if (t.p[c] == s.p[c])
                                cover += t.w;
                        if (cover > best_w + 1e-12) {
                            best_w = cover;
                            best = s.p[c];
                        }
                    }
                    d[c] = best;
                }
            }
        }
    return out;
}

float tileReliefDepth(const uint8_t *px, int w, int h) {
    if (w < 8 || h < 8)
        return 0.0f;
    auto at = [&](int x, int y, int c) {
        return px[((size_t)y * w + x) * 4 + c] / 255.0f;
    };
    std::vector<float> ratios;
    ratios.reserve((size_t)(w * h / 4));
    for (int y = 0; y < h; y += 2)
        for (int x = 0; x < w; x += 2) {
            const float nx = at(x, y, 0) * 2.0f - 1.0f;
            const float ny = at(x, y, 1) * 2.0f - 1.0f;
            const float nz = std::sqrt(std::clamp(1.0f - nx * nx - ny * ny, 1e-4f, 1.0f));
            const float gx = (at((x + 1) % w, y, 3) - at((x + w - 1) % w, y, 3)) * 0.5f;
            const float gy = (at(x, (y + 1) % h, 3) - at(x, (y + h - 1) % h, 3)) * 0.5f;
            const float g = std::fabs(gx) + std::fabs(gy);
            if (g > 0.01f)
                ratios.push_back((std::fabs(nx) + std::fabs(ny)) / nz / g);
        }
    if (ratios.size() < 100)
        return 0.0f;
    std::nth_element(ratios.begin(), ratios.begin() + (ptrdiff_t)(ratios.size() / 2),
            ratios.end());
    return ratios[ratios.size() / 2] / (float)w;
}

} // namespace goanna
