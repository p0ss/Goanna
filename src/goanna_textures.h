// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Goanna's implementations of the texture and shader interfaces the
// transplanted Luanti meshing code talks to.
//
// - GoannaTexture: a video::ITexture that carries no GPU resource; it holds
//   the generated CPU image (Irrlicht CImage) and, lazily, a Godot texture.
// - GoannaTextureSource: ITextureSource over Luanti's own ImageSource (the
//   texture-modifier DSL, verbatim), with Godot decoding media bytes.
// - GoannaShaderSource: assigns ids per (material type, base material) so
//   TileLayer.shader_id maps onto Godot material variants.

#include <map>
#include <memory>
#include <string>
#include <vector>

#include <godot_cpp/classes/image_texture.hpp>

#include "client/imagesource.h"
#include "client/shader.h"
#include "client/texturesource.h"
#include "client/tile.h"

namespace goanna {

class GoannaTexture final : public video::ITexture {
public:
    GoannaTexture(const std::string &name, video::IImage *image, u32 id);
    ~GoannaTexture() override;

    void *lock(video::E_TEXTURE_LOCK_MODE mode, u32 mipmapLevel, u32 layer,
            video::E_TEXTURE_LOCK_FLAGS lockFlags) override;
    void unlock() override {}
    void regenerateMipMapLevels() override {}

    u32 id() const { return m_id; }
    video::IImage *image() const { return m_image; }
    // Godot-side texture, created on first use (main thread).
    godot::Ref<godot::ImageTexture> godotTexture();
    // Tangent-space normal map derived from the diffuse luminance ("auto
    // bump"): dark texels read as recessed, light as raised. Cached per
    // strength; regenerated when strength changes. Main thread only.
    godot::Ref<godot::ImageTexture> godotNormal(float strength);
    bool hasAlpha() const { return m_has_alpha; }

private:
    u32 m_id;
    video::IImage *m_image; // owned (ref)
    bool m_has_alpha = false;
    godot::Ref<godot::ImageTexture> m_godot;
    godot::Ref<godot::ImageTexture> m_normal;
    float m_normal_strength = -1.0f;
};

class GoannaTextureSource final : public IWritableTextureSource {
public:
    GoannaTextureSource();
    ~GoannaTextureSource() override;

    // ISimpleTextureSource / ITextureSource
    video::ITexture *getTexture(const std::string &name, u32 *id = nullptr) override;
    u32 getTextureId(const std::string &image) override;
    std::string getTextureName(u32 id) override;
    video::ITexture *getTexture(u32 id) override;
    video::ITexture *addArrayTexture(const std::vector<std::string> &images, u32 *id = nullptr) override;
    bool needFilterForMesh() const override { return false; }
    Palette *getPalette(const std::string &image) override;
    bool isKnownSourceImage(const std::string &name) override;
    core::dimension2du getTextureDimensions(const std::string &image) override;
    video::SColor getTextureAverageColor(const std::string &image) override;
    // IWritableTextureSource
    void processQueue() override {}
    void insertSourceImage(const std::string &name, video::IImage *img) override;
    void rebuildImagesAndTextures() override {}

    // Goanna: register a media file's bytes as a source image (decoded here).
    bool insertMediaImage(const std::string &name, const std::string &bytes);
    GoannaTexture *goannaTexture(u32 id);

private:
    video::IImage *getOrGenerateImage(const std::string &name);
    ImageSource m_imagesource;
    std::vector<std::unique_ptr<GoannaTexture>> m_textures; // index = id
    std::map<std::string, u32> m_name_to_id;
    std::map<std::string, Palette> m_palettes;
    std::map<std::string, bool> m_known_source;
};

class GoannaShaderSource final : public IWritableShaderSource {
public:
    GoannaShaderSource();
    const ShaderInfo &getShaderInfo(u32 id) override;
    u32 getShader(const std::string &name, const ShaderConstants &input_const,
            video::E_MATERIAL_TYPE base_mat, IShaderUniformSetterRC *setter_cb = nullptr) override;
    bool supportsSampler2DArray() const override { return false; }
    void processQueue() override {}
    void insertSourceShader(const std::string &, const std::string &, const std::string &) override {}
    void rebuildShaders() override {}
    void addShaderConstantSetter(std::unique_ptr<IShaderConstantSetter>) override {}
    void addShaderUniformSetterFactory(std::unique_ptr<IShaderUniformSetterFactory>) override {}

    // What Goanna's material builder wants to know about a shader id.
    MaterialType materialType(u32 id) const;
    video::E_MATERIAL_TYPE baseMaterial(u32 id) const;
    // Luanti stores the driver's material id for a shader in ShaderInfo::material,
    // which the mesher copies into each buffer's SMaterial.MaterialType. Goanna
    // encodes the shader id there so the Godot side can recover it.
    static constexpr u32 MATERIAL_ID_BASE = 1000;
    static bool isShaderMaterial(video::E_MATERIAL_TYPE m) { return (u32)m >= MATERIAL_ID_BASE; }
    static u32 shaderIdFromMaterial(video::E_MATERIAL_TYPE m) { return (u32)m - MATERIAL_ID_BASE; }

private:
    struct Entry {
        ShaderInfo info;
        MaterialType material_type = TILE_MATERIAL_BASIC;
    };
    std::vector<Entry> m_shaders;
    std::map<std::string, u32> m_keys;
};

} // namespace goanna
