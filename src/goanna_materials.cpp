#include "goanna_materials.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "goanna_session.h"
#include "log.h"

using namespace godot;

namespace goanna {

std::string baseTextureName(const std::string &tile) {
    // "a.png^b.png^[colorize:#fff" -> "a.png"; "(a.png^b.png)" -> "a.png"
    std::string t = tile;
    size_t start = 0;
    while (start < t.size() && (t[start] == '(' || t[start] == ' '))
        ++start;
    size_t end = t.find_first_of("^)", start);
    std::string base = t.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (base.empty() || base[0] == '[')
        return "";
    return base;
}

Ref<ImageTexture> MaterialCache::loadTexture(GoannaSession &session, const std::string &tile,
        bool &has_alpha, int &w, int &h) {
    has_alpha = false;
    w = h = 0;
    std::string base = baseTextureName(tile);
    if (base.empty())
        return Ref<ImageTexture>();
    auto it = m_textures.find(base);
    if (it != m_textures.end()) {
        Ref<Image> img = it->second->get_image();
        if (img.is_valid()) {
            has_alpha = img->detect_alpha() != Image::ALPHA_NONE;
            w = img->get_width();
            h = img->get_height();
        }
        return it->second;
    }
    std::string bytes;
    if (!session.getMedia(base, bytes))
        return Ref<ImageTexture>();
    PackedByteArray pba;
    pba.resize(bytes.size());
    memcpy(pba.ptrw(), bytes.data(), bytes.size());
    Ref<Image> img;
    img.instantiate();
    Error err;
    std::string ext = base.size() > 4 ? base.substr(base.size() - 4) : "";
    for (auto &c : ext) c = tolower(c);
    if (ext == ".png") err = img->load_png_from_buffer(pba);
    else if (ext == ".jpg" || ext == "jpeg") err = img->load_jpg_from_buffer(pba);
    else if (ext == ".tga") err = img->load_tga_from_buffer(pba);
    else if (ext == ".bmp") err = img->load_bmp_from_buffer(pba);
    else err = ERR_UNAVAILABLE;
    if (err != OK || img->is_empty()) {
        warningstream << "goanna: could not decode texture " << base << std::endl;
        m_textures[base] = Ref<ImageTexture>();
        return Ref<ImageTexture>();
    }
    if (img->get_format() != Image::FORMAT_RGBA8)
        img->convert(Image::FORMAT_RGBA8);
    has_alpha = img->detect_alpha() != Image::ALPHA_NONE;
    w = img->get_width();
    h = img->get_height();
    img->generate_mipmaps();
    Ref<ImageTexture> tex = ImageTexture::create_from_image(img);
    m_textures[base] = tex;
    return tex;
}

Ref<Material> MaterialCache::get(GoannaSession &session, const SurfaceData &s) {
    std::string key = s.tex + (s.double_sided ? "|x" : "|c") + std::to_string((int)s.alpha);
    auto it = m_materials.find(key);
    if (it != m_materials.end() && it->second.resolved)
        return it->second.mat;

    bool has_alpha = false;
    int w = 0, h = 0;
    Ref<ImageTexture> tex = loadTexture(session, s.tex, has_alpha, w, h);
    if (tex.is_null()) {
        if (m_fallback.is_null()) {
            m_fallback.instantiate();
            m_fallback->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
            m_fallback->set_albedo(Color(0.8, 0.5, 0.8));
            m_fallback->set_roughness(1.0);
        }
        // remember as unresolved so we retry once media arrives
        Entry e;
        e.mat = m_fallback;
        e.resolved = false;
        m_materials[key] = e;
        return m_fallback;
    }
    Ref<StandardMaterial3D> mat;
    mat.instantiate();
    mat->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, tex);
    mat->set_texture_filter(BaseMaterial3D::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS);
    mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat->set_roughness(1.0);
    mat->set_metallic(0.0);
    mat->set_cull_mode(s.double_sided ? BaseMaterial3D::CULL_DISABLED : BaseMaterial3D::CULL_BACK);
    if (s.alpha == ALPHAMODE_BLEND) {
        mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
        mat->set_depth_draw_mode(BaseMaterial3D::DEPTH_DRAW_ALWAYS);
    } else if (has_alpha) {
        mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR);
        mat->set_alpha_scissor_threshold(0.5);
    }
    // Vertically stacked animation frames: show the first frame.
    if (s.animation.type == TileAnimationType::TAT_VERTICAL_FRAMES && w > 0 && h > 0) {
        int aw = s.animation.vertical_frames.aspect_w, ah = s.animation.vertical_frames.aspect_h;
        if (aw > 0 && ah > 0) {
            float frame_h = (float)w * ah / aw;
            if (frame_h > 0 && frame_h < h)
                mat->set_uv1_scale(Vector3(1, frame_h / h, 1));
        }
    } else if (s.animation.type == TileAnimationType::TAT_SHEET_2D) {
        int fw = s.animation.sheet_2d.frames_w, fh = s.animation.sheet_2d.frames_h;
        if (fw > 0 && fh > 0)
            mat->set_uv1_scale(Vector3(1.0f / fw, 1.0f / fh, 1));
    }
    Entry e;
    e.mat = mat;
    e.resolved = true;
    m_materials[key] = e;
    return mat;
}

void MaterialCache::clear() {
    m_materials.clear();
    m_textures.clear();
}

} // namespace goanna
