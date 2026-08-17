// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// Goanna's implementations of the texture and shader interfaces the
// transplanted Luanti meshing code talks to.
//
// This file mixes Goanna original code with functions copied from Luanti
// 5.16.1: the palette loader from client/texturesource.cpp, and getShader
// adapted from client/shader.cpp. Each is marked at its definition.

#include "goanna_textures.h"

#include <cmath>
#include <cstring>
#include <fstream>
#include <set>
#include <sstream>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include "CImage.h"
#include "client/imagefilters.h"
#include "goanna_image_hooks.h"
#include "log.h"

using namespace godot;

// ---------------------------------------------------------------------------
// Image hooks (used by the transplanted imagesource.cpp)

video::IImage *goanna_create_image(video::ECOLOR_FORMAT format, const core::dimension2du &dim) {
    return new video::CImage(format, dim);
}

static video::IImage *imageFromGodot(const Ref<Image> &img) {
    if (img.is_null() || img->is_empty())
        return nullptr;
    Ref<Image> rgba = img;
    if (rgba->get_format() != Image::FORMAT_RGBA8) {
        rgba = img->duplicate();
        rgba->convert(Image::FORMAT_RGBA8);
    }
    const int w = rgba->get_width(), h = rgba->get_height();
    auto *out = new video::CImage(video::ECF_A8R8G8B8, core::dimension2du(w, h));
    PackedByteArray data = rgba->get_data();
    const uint8_t *src = data.ptr();
    u8 *dst = (u8 *)out->getData();
    // Godot RGBA8 -> Irrlicht A8R8G8B8 (little-endian: B G R A in memory)
    for (int i = 0; i < w * h; ++i) {
        dst[i * 4 + 0] = src[i * 4 + 2];
        dst[i * 4 + 1] = src[i * 4 + 1];
        dst[i * 4 + 2] = src[i * 4 + 0];
        dst[i * 4 + 3] = src[i * 4 + 3];
    }
    return out;
}

video::IImage *goanna_decode_image_memory(const std::string &bytes, const std::string &name) {
    PackedByteArray pba;
    pba.resize(bytes.size());
    memcpy(pba.ptrw(), bytes.data(), bytes.size());
    Ref<Image> img;
    img.instantiate();
    std::string ext = name.size() > 4 ? name.substr(name.size() - 4) : "";
    for (auto &c : ext) c = tolower(c);
    Error err;
    if (ext == ".png") err = img->load_png_from_buffer(pba);
    else if (ext == ".jpg" || ext == "jpeg") err = img->load_jpg_from_buffer(pba);
    else if (ext == ".tga") err = img->load_tga_from_buffer(pba);
    else if (ext == ".bmp") err = img->load_bmp_from_buffer(pba);
    else {
        // sniff PNG signature as a fallback
        static const unsigned char sig[4] = {0x89, 'P', 'N', 'G'};
        if (bytes.size() > 4 && memcmp(bytes.data(), sig, 4) == 0)
            err = img->load_png_from_buffer(pba);
        else
            err = ERR_UNAVAILABLE;
    }
    if (err != OK)
        return nullptr;
    return imageFromGodot(img);
}

video::IImage *goanna_load_image_file(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return nullptr;
    std::stringstream ss;
    ss << f.rdbuf();
    return goanna_decode_image_memory(ss.str(), path);
}

namespace goanna {

// ---------------------------------------------------------------------------
// GoannaTexture

GoannaTexture::GoannaTexture(const std::string &name, video::IImage *image, u32 id)
    : video::ITexture(name.c_str(), video::ETT_2D), m_id(id), m_image(image) {
    if (m_image) {
        m_image->grab();
        Size = OriginalSize = m_image->getDimension();
        ColorFormat = m_image->getColorFormat();
        // alpha scan
        const u32 w = Size.Width, h = Size.Height;
        for (u32 y = 0; y < h && !m_has_alpha; ++y)
            for (u32 x = 0; x < w; ++x)
                if (m_image->getPixel(x, y).getAlpha() < 255) { m_has_alpha = true; break; }
    }
}

GoannaTexture::~GoannaTexture() {
    if (m_image)
        m_image->drop();
    for (video::IImage *layer : m_layers)
        layer->drop();
}

void *GoannaTexture::lock(video::E_TEXTURE_LOCK_MODE, u32, u32, video::E_TEXTURE_LOCK_FLAGS) {
    return m_image ? m_image->getData() : nullptr;
}

Ref<Image> goanna_image_to_godot(video::IImage *src);

GoannaTexture::GoannaTexture(const std::string &name, const std::vector<video::IImage *> &images,
        const std::vector<std::string> &layer_names, u32 id)
    : video::ITexture(name.c_str(), video::ETT_2D_ARRAY), m_id(id),
      m_image(nullptr), m_layer_names(layer_names) {
    m_layers.reserve(images.size());
    for (video::IImage *img : images) {
        img->grab();
        m_layers.push_back(img);
        for (u32 y = 0; y < img->getDimension().Height && !m_has_alpha; ++y)
            for (u32 x = 0; x < img->getDimension().Width; ++x)
                if (img->getPixel(x, y).getAlpha() < 255) { m_has_alpha = true; break; }
    }
    if (!m_layers.empty()) {
        Size = OriginalSize = m_layers[0]->getDimension();
        ColorFormat = m_layers[0]->getColorFormat();
    }
}

Ref<Image> goanna_image_to_godot(video::IImage *src) {
    const u32 w = src->getDimension().Width, h = src->getDimension().Height;
    PackedByteArray data;
    data.resize(w * h * 4);
    uint8_t *dst = data.ptrw();
    for (u32 y = 0; y < h; ++y)
        for (u32 x = 0; x < w; ++x) {
            video::SColor c = src->getPixel(x, y);
            size_t i = (y * w + x) * 4;
            dst[i + 0] = c.getRed();
            dst[i + 1] = c.getGreen();
            dst[i + 2] = c.getBlue();
            dst[i + 3] = c.getAlpha();
        }
    return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, data);
}

Ref<Texture2DArray> GoannaTexture::godotArray() {
    if (m_godot_array.is_valid() || m_layers.empty())
        return m_godot_array;
    TypedArray<Image> imgs;
    for (video::IImage *layer : m_layers) {
        Ref<Image> img = goanna_image_to_godot(layer);
        if (img.is_null())
            return m_godot_array;
        img->generate_mipmaps();
        imgs.push_back(img);
    }
    Ref<Texture2DArray> tex;
    tex.instantiate();
    if (tex->create_from_images(imgs) == OK)
        m_godot_array = tex;
    return m_godot_array;
}

Ref<Texture2DArray> GoannaTexture::godotArraySuffixed(GoannaTextureSource &src, const char *suffix) {
    std::string key(suffix);
    auto miss = m_suffixed_missing.find(key);
    if (miss != m_suffixed_missing.end() && miss->second)
        return Ref<Texture2DArray>();
    auto have = m_godot_suffixed.find(key);
    if (have != m_godot_suffixed.end())
        return have->second;
    // Layer indices must line up with the base array, so every layer needs an
    // image; but a pack covering only some textures is the normal case, so a
    // missing companion becomes a neutral layer (flat normal, fully rough,
    // no emission) rather than abandoning the whole bunch. Only if nothing at
    // all is authored is the companion reported as absent.
    const bool is_normal = key == "_n";
    TypedArray<Image> imgs;
    bool any = false;
    int authored = 0;
    for (const std::string &base : m_layer_names) {
        size_t dotpos = base.rfind('.');
        std::string name = (dotpos == std::string::npos ? base : base.substr(0, dotpos)) + suffix +
                (dotpos == std::string::npos ? std::string() : base.substr(dotpos));
        Ref<Image> img;
        if (src.isKnownSourceImage(name)) {
            GoannaTexture *gt = dynamic_cast<GoannaTexture *>(src.getTexture(name));
            if (gt && gt->image() && gt->image()->getDimension() == Size) {
                img = goanna_image_to_godot(gt->image());
                if (img.is_valid()) {
                    any = true;
                    ++authored;
                }
            }
        }
        if (img.is_null()) {
            img = Image::create_empty(Size.Width, Size.Height, false, Image::FORMAT_RGBA8);
            // flat tangent normal with full ambient light, or a rough
            // dielectric with no emission
            img->fill(is_normal ? Color(0.5f, 0.5f, 1.0f, 0.0f) : Color(0.0f, 0.04f, 0.0f, 1.0f));
        }
        img->generate_mipmaps();
        imgs.push_back(img);
    }
    if (getenv("GOANNA_DEBUG_PBR")) {
        // has_normal being true only means SOME layer of the bunch had a
        // companion. The rest are neutral fallbacks carrying no material at
        // all, so this is the number that says how much of a scene is
        // actually dressed.
        UtilityFunctions::print("pbr coverage ", suffix, " ", authored, "/",
                (int)m_layer_names.size());
    }
    if (!any) {
        m_suffixed_missing[key] = true;
        return Ref<Texture2DArray>();
    }
    Ref<Texture2DArray> tex;
    tex.instantiate();
    if (tex->create_from_images(imgs) == OK) {
        m_godot_suffixed[key] = tex;
        return tex;
    }
    m_suffixed_missing[key] = true;
    return Ref<Texture2DArray>();
}

Ref<ImageTexture> GoannaTexture::godotTexture() {
    if (m_godot.is_valid() || !m_image)
        return m_godot;
    const u32 w = m_image->getDimension().Width, h = m_image->getDimension().Height;
    PackedByteArray data;
    data.resize(w * h * 4);
    uint8_t *dst = data.ptrw();
    for (u32 y = 0; y < h; ++y)
        for (u32 x = 0; x < w; ++x) {
            video::SColor c = m_image->getPixel(x, y);
            size_t i = (y * w + x) * 4;
            dst[i + 0] = c.getRed();
            dst[i + 1] = c.getGreen();
            dst[i + 2] = c.getBlue();
            dst[i + 3] = c.getAlpha();
        }
    Ref<Image> img = Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, data);
    if (img.is_valid()) {
        img->generate_mipmaps();
        m_godot = ImageTexture::create_from_image(img);
    }
    return m_godot;
}

Ref<ImageTexture> GoannaTexture::godotNormal(float strength) {
    if (m_normal.is_valid() && m_normal_strength == strength)
        return m_normal;
    if (!m_image || strength <= 0.0f) {
        m_normal = Ref<ImageTexture>();
        m_normal_strength = strength;
        return m_normal;
    }
    const int w = (int)m_image->getDimension().Width, h = (int)m_image->getDimension().Height;
    if (w < 2 || h < 2) {
        m_normal_strength = strength;
        return m_normal; // too small to derive relief
    }
    // Height from luminance, then a Sobel gradient to a tangent-space normal.
    // Textures tile, so sample neighbours with wraparound for seamless relief.
    std::vector<float> lum(w * h);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            video::SColor c = m_image->getPixel(x, y);
            lum[y * w + x] = (0.299f * c.getRed() + 0.587f * c.getGreen() + 0.114f * c.getBlue()) / 255.0f;
        }
    auto at = [&](int x, int y) -> float {
        return lum[((y + h) % h) * w + ((x + w) % w)];
    };
    PackedByteArray data;
    data.resize(w * h * 4);
    uint8_t *dst = data.ptrw();
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            // Sobel
            float gx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1))
                     - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1));
            float gy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1))
                     - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1));
            // dark in / light out: higher luminance should bulge towards the
            // viewer, so the surface normal tilts away from bright neighbours.
            float nx = -gx * strength;
            float ny = -gy * strength;
            float nz = 1.0f;
            float inv = 1.0f / std::sqrt(nx * nx + ny * ny + nz * nz);
            nx *= inv; ny *= inv; nz *= inv;
            size_t i = (y * w + x) * 4;
            // Godot uses OpenGL-style tangent normals (+Y up); the mesh UV V
            // runs downward, so flip Y.
            dst[i + 0] = (uint8_t)std::clamp((nx * 0.5f + 0.5f) * 255.0f, 0.0f, 255.0f);
            dst[i + 1] = (uint8_t)std::clamp((-ny * 0.5f + 0.5f) * 255.0f, 0.0f, 255.0f);
            dst[i + 2] = (uint8_t)std::clamp((nz * 0.5f + 0.5f) * 255.0f, 0.0f, 255.0f);
            dst[i + 3] = 255;
        }
    Ref<Image> img = Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, data);
    if (img.is_valid()) {
        img->generate_mipmaps();
        m_normal = ImageTexture::create_from_image(img);
    }
    m_normal_strength = strength;
    return m_normal;
}

// ---------------------------------------------------------------------------
// GoannaTextureSource

GoannaTextureSource::GoannaTextureSource() {
    // id 0 is "no texture" like Luanti's TextureSource
    m_textures.push_back(std::make_unique<GoannaTexture>("", nullptr, 0));
    m_name_to_id[""] = 0;
}

GoannaTextureSource::~GoannaTextureSource() = default;

video::IImage *GoannaTextureSource::getOrGenerateImage(const std::string &name) {
    std::set<std::string> unused;
    return m_imagesource.generateImage(name, unused);
}

u32 GoannaTextureSource::getTextureId(const std::string &image) {
    auto it = m_name_to_id.find(image);
    if (it != m_name_to_id.end())
        return it->second;
    video::IImage *img = getOrGenerateImage(image);
    if (!img) {
        // Unknown: map to id 0 but remember the name so we don't retry endlessly.
        m_name_to_id[image] = 0;
        return 0;
    }
    u32 id = (u32)m_textures.size();
    m_textures.push_back(std::make_unique<GoannaTexture>(image, img, id));
    img->drop();
    m_name_to_id[image] = id;
    return id;
}

std::string GoannaTextureSource::getTextureName(u32 id) {
    if (id >= m_textures.size())
        return "";
    return m_textures[id]->getName().getPath().c_str();
}

video::ITexture *GoannaTextureSource::getTexture(u32 id) {
    if (id == 0 || id >= m_textures.size())
        return nullptr;
    return m_textures[id].get();
}

video::ITexture *GoannaTextureSource::getTexture(const std::string &name, u32 *id) {
    u32 i = getTextureId(name);
    if (id)
        *id = i;
    return getTexture(i);
}

video::ITexture *GoannaTextureSource::addArrayTexture(const std::vector<std::string> &images, u32 *id) {
    // node_visuals has already grouped these by size, but a generated image can
    // still come back a different size or fail, and every layer of a Godot
    // Texture2DArray must match, so verify before committing to the bunch.
    std::vector<video::IImage *> layers;
    core::dimension2du dim;
    for (const std::string &name : images) {
        video::IImage *img = getOrGenerateImage(name);
        if (!img)
            break;
        if (layers.empty())
            dim = img->getDimension();
        else if (img->getDimension() != dim) {
            img->drop();
            break;
        }
        layers.push_back(img);
    }
    bool ok = layers.size() == images.size() && layers.size() > 1;
    video::ITexture *result = nullptr;
    if (ok) {
        u32 new_id = (u32)m_textures.size();
        std::string name = "[array:" + std::to_string(new_id);
        m_textures.push_back(std::make_unique<GoannaTexture>(name, layers, images, new_id));
        m_name_to_id[name] = new_id;
        if (id)
            *id = new_id;
        result = m_textures.back().get();
    } else if (id) {
        *id = 0;
    }
    for (video::IImage *img : layers)
        img->drop();
    return result;
}

std::string GoannaTextureSource::imageName(u32 texture_id, u16 layer) {
    GoannaTexture *gt = goannaTexture(texture_id);
    if (!gt)
        return std::string();
    if (!gt->isArray())
        return getTextureName(texture_id);
    const auto &names = gt->layerNames();
    if (names.empty())
        return std::string();
    return names[layer < names.size() ? layer : 0];
}

GoannaTexture *GoannaTextureSource::goannaTexture(u32 id) {
    if (id == 0 || id >= m_textures.size())
        return nullptr;
    return m_textures[id].get();
}

// Copied from TextureSource::getPalette (texturesource.cpp), minus threading.
Palette *GoannaTextureSource::getPalette(const std::string &name) {
    if (name.empty())
        return nullptr;
    auto it = m_palettes.find(name);
    if (it == m_palettes.end()) {
        video::IImage *img = getOrGenerateImage(name);
        if (!img) {
            warningstream << "GoannaTextureSource::getPalette(): palette \"" << name
                          << "\" could not be loaded." << std::endl;
            return nullptr;
        }
        Palette new_palette;
        u32 w = img->getDimension().Width;
        u32 h = img->getDimension().Height;
        u32 area = h * w;
        if (area == 0) {
            img->drop();
            return nullptr;
        }
        if (area > 256)
            area = 256;
        u32 step = 256 / area;
        for (u32 i = 0; i < area; i++) {
            video::SColor c = img->getPixel(i % w, i / w);
            for (u32 j = 0; j < step; j++)
                new_palette.push_back(c);
        }
        img->drop();
        while (new_palette.size() < 256)
            new_palette.emplace_back(0xFFFFFFFF);
        m_palettes[name] = new_palette;
        it = m_palettes.find(name);
    }
    return &it->second;
}

bool GoannaTextureSource::isKnownSourceImage(const std::string &name) {
    auto it = m_known_source.find(name);
    if (it != m_known_source.end())
        return it->second;
    // Ask ImageSource by trying to generate; cache the answer.
    video::IImage *img = getOrGenerateImage(name);
    bool known = img != nullptr;
    if (img)
        img->drop();
    m_known_source[name] = known;
    return known;
}

core::dimension2du GoannaTextureSource::getTextureDimensions(const std::string &image) {
    u32 id = getTextureId(image);
    if (id == 0)
        return core::dimension2du(0, 0);
    return m_textures[id]->getSize();
}

video::SColor GoannaTextureSource::getTextureAverageColor(const std::string &name) {
    if (name.empty())
        return {0, 0, 0, 0};
    video::IImage *image = getOrGenerateImage(name);
    if (!image)
        return {0, 0, 0, 0};
    video::SColor c = imageAverageColor(image);
    image->drop();
    return c;
}

void GoannaTextureSource::insertSourceImage(const std::string &name, video::IImage *img) {
    m_imagesource.insertSourceImage(name, img, true);
    m_known_source[name] = true;
}

bool GoannaTextureSource::insertMediaImage(const std::string &name, const std::string &bytes) {
    video::IImage *img = goanna_decode_image_memory(bytes, name);
    if (!img)
        return false;
    m_imagesource.insertSourceImage(name, img, false);
    img->drop();
    m_known_source[name] = true;
    return true;
}

// ---------------------------------------------------------------------------
// GoannaShaderSource

GoannaShaderSource::GoannaShaderSource() {
    // id 0: default/basic
    Entry e;
    e.info.name = "default";
    e.info.base_material = video::EMT_SOLID;
    e.info.material = (video::E_MATERIAL_TYPE)MATERIAL_ID_BASE;
    m_shaders.push_back(e);
}

const ShaderInfo &GoannaShaderSource::getShaderInfo(u32 id) {
    if (id >= m_shaders.size())
        id = 0;
    return m_shaders[id].info;
}

u32 GoannaShaderSource::getShader(const std::string &name, const ShaderConstants &input_const,
        video::E_MATERIAL_TYPE base_mat, IShaderUniformSetterRC *) {
    int mt = TILE_MATERIAL_BASIC;
    auto it = input_const.find("MATERIAL_TYPE");
    if (it != input_const.end() && std::holds_alternative<int>(it->second))
        mt = std::get<int>(it->second);
    bool arr = false;
    auto ait = input_const.find("USE_ARRAY_TEXTURE");
    if (ait != input_const.end())
        arr = true;
    std::string key = name + "|" + std::to_string(mt) + "|" + std::to_string((int)base_mat) +
            (arr ? "|arr" : "");
    auto k = m_keys.find(key);
    if (k != m_keys.end())
        return k->second;
    Entry e;
    e.info.name = name;
    e.info.base_material = base_mat;
    e.info.input_constants = input_const;
    e.material_type = (MaterialType)mt;
    e.array_texture = arr;
    u32 id = (u32)m_shaders.size();
    e.info.material = (video::E_MATERIAL_TYPE)(MATERIAL_ID_BASE + id);
    m_shaders.push_back(e);
    m_keys[key] = id;
    return id;
}

bool GoannaShaderSource::usesArrayTexture(u32 id) const {
    return id < m_shaders.size() && m_shaders[id].array_texture;
}

MaterialType GoannaShaderSource::materialType(u32 id) const {
    if (id >= m_shaders.size())
        return TILE_MATERIAL_BASIC;
    return m_shaders[id].material_type;
}

video::E_MATERIAL_TYPE GoannaShaderSource::baseMaterial(u32 id) const {
    if (id >= m_shaders.size())
        return video::EMT_SOLID;
    return m_shaders[id].info.base_material;
}

} // namespace goanna

// ---------------------------------------------------------------------------
// Non-virtual helper declared in client/shader.h and defined in shader.cpp,
// which Goanna does not compile. Copied from there, minus the skinning query.
u32 IShaderSource::getShader(const std::string &name, MaterialType material_type,
        NodeDrawType drawtype, bool array_texture, bool skinning) {
    ShaderConstants input_const;
    input_const["MATERIAL_TYPE"] = (int)material_type;
    (void)drawtype;
    if (array_texture)
        input_const["USE_ARRAY_TEXTURE"] = 1;
    (void)skinning;
    video::E_MATERIAL_TYPE base_mat = video::EMT_SOLID;
    switch (material_type) {
    case TILE_MATERIAL_ALPHA:
    case TILE_MATERIAL_PLAIN_ALPHA:
    case TILE_MATERIAL_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT:
        base_mat = video::EMT_TRANSPARENT_ALPHA_CHANNEL;
        break;
    case TILE_MATERIAL_BASIC:
    case TILE_MATERIAL_PLAIN:
    case TILE_MATERIAL_WAVING_LEAVES:
    case TILE_MATERIAL_WAVING_PLANTS:
    case TILE_MATERIAL_WAVING_LIQUID_BASIC:
        base_mat = video::EMT_TRANSPARENT_ALPHA_CHANNEL_REF;
        break;
    default:
        break;
    }
    return getShader(name, input_const, base_mat);
}

