// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// Goanna's implementations of the texture and shader interfaces the
// transplanted Luanti meshing code talks to.
//
// This file mixes Goanna original code with functions copied from Luanti
// 5.16.1: createAnimationFrames from client/wieldmesh.cpp (verbatim), the
// palette loader from client/texturesource.cpp, and getShader adapted from
// client/shader.cpp. Each is marked at its definition.

#include "goanna_textures.h"

#include <cstring>
#include <fstream>
#include <set>
#include <sstream>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include "CImage.h"
#include "client/wieldmesh.h"
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
}

void *GoannaTexture::lock(video::E_TEXTURE_LOCK_MODE, u32, u32, video::E_TEXTURE_LOCK_FLAGS) {
    return m_image ? m_image->getData() : nullptr;
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

video::ITexture *GoannaTextureSource::addArrayTexture(const std::vector<std::string> &, u32 *id) {
    if (id)
        *id = 0;
    return nullptr;
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
    std::string key = name + "|" + std::to_string(mt) + "|" + std::to_string((int)base_mat);
    auto k = m_keys.find(key);
    if (k != m_keys.end())
        return k->second;
    Entry e;
    e.info.name = name;
    e.info.base_material = base_mat;
    e.info.input_constants = input_const;
    e.material_type = (MaterialType)mt;
    u32 id = (u32)m_shaders.size();
    e.info.material = (video::E_MATERIAL_TYPE)(MATERIAL_ID_BASE + id);
    m_shaders.push_back(e);
    m_keys[key] = id;
    return id;
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

// ---------------------------------------------------------------------------
// Declared in client/wieldmesh.h and defined in wieldmesh.cpp (Irrlicht-heavy,
// not compiled by Goanna). Copied verbatim from there.
std::vector<FrameSpec> createAnimationFrames(ITextureSource *tsrc,
		const std::string &image_name, const TileAnimationParams &animation,
		int &result_frame_length_ms)
{
	result_frame_length_ms = 0;

	if (image_name.empty())
		return {};

	// Still create texture if not animated
	if (animation.type == TileAnimationType::TAT_NONE) {
		u32 id;
		video::ITexture *texture = tsrc->getTextureForMesh(image_name, &id);
		return {{id, texture}};
	}

	auto texture_size = tsrc->getTextureDimensions(image_name);
	if (!texture_size.Width || !texture_size.Height)
		return {};

	int frame_count = 1;
	animation.determineParams(texture_size, &frame_count, &result_frame_length_ms, nullptr);

	std::vector<FrameSpec> frames(frame_count);
	std::ostringstream os(std::ios::binary);
	for (int i = 0; i < frame_count; i++) {
		os.str("");
		os << image_name;
		animation.getTextureModifer(os, texture_size, i);

		u32 id;
		frames[i].texture = tsrc->getTextureForMesh(os.str(), &id);
		frames[i].texture_id = id;
	}
	return frames;
}
