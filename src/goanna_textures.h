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
#include <set>
#include <memory>
#include <string>
#include <vector>

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/texture2d_array.hpp>

#include "client/imagesource.h"
#include "client/shader.h"
#include "client/texturesource.h"
#include "client/tile.h"
#include "goanna_materials.h"

namespace goanna {

class GoannaTextureSource;

class GoannaTexture final : public video::ITexture {
public:
    GoannaTexture(const std::string &name, video::IImage *image, u32 id);
    // Array texture: several same-sized images addressed by layer index, so a
    // whole bunch of node tiles can share one material and one draw call.
    GoannaTexture(const std::string &name, const std::vector<video::IImage *> &images,
            const std::vector<std::string> &layer_names, u32 id);
    ~GoannaTexture() override;

    void *lock(video::E_TEXTURE_LOCK_MODE mode, u32 mipmapLevel, u32 layer,
            video::E_TEXTURE_LOCK_FLAGS lockFlags) override;
    void unlock() override {}
    void regenerateMipMapLevels() override {}

    u32 id() const { return m_id; }
    video::IImage *image() const { return m_image; }
    // Godot-side texture, created on first use (main thread).
    godot::Ref<godot::ImageTexture> godotTexture();
    // Array textures: the Godot side (built on first use, main thread) and the
    // source image names, so a caller that cannot use an array (a special
    // shader, an animated or cracked tile) can fall back to a single layer.
    bool isArray() const { return !m_layers.empty(); }
    godot::Ref<godot::Texture2DArray> godotArray();
    // LabPBR companion arrays: the same layers with a "_n" (normal, AO,
    // height) or "_s" (smoothness, F0, porosity, emission) suffix, built only
    // if a pack supplies one for every layer. Null when it does not.
    godot::Ref<godot::Texture2DArray> godotArraySuffixed(GoannaTextureSource &src, const char *suffix);
    // Forget the companion arrays, so the next use rebuilds them: the
    // classifier table or the relief strength changed under them.
    void dropCompanions() { m_godot_suffixed.clear(); m_suffixed_missing.clear(); }
    const std::vector<std::string> &layerNames() const { return m_layer_names; }
    // Tangent-space normal map derived from the diffuse luminance ("auto
    // bump"): dark texels read as recessed, light as raised. Cached per
    // strength; regenerated when strength changes. Main thread only.
    godot::Ref<godot::ImageTexture> godotNormal(float strength);
    // The same inferred relief in LabPBR's convention (Y down, B is ambient
    // occlusion), for entity.gdshader, which decodes _n the way the node
    // array shader does. Cached per strength.
    godot::Ref<godot::ImageTexture> godotCompanionNormal(float strength);
    bool hasAlpha() const { return m_has_alpha; }

private:
    u32 m_id;
    video::IImage *m_image; // owned (ref)
    bool m_has_alpha = false;
    std::vector<video::IImage *> m_layers; // owned (ref); empty unless an array
    std::vector<std::string> m_layer_names;
    godot::Ref<godot::Texture2DArray> m_godot_array;
    std::map<std::string, godot::Ref<godot::Texture2DArray>> m_godot_suffixed;
    std::map<std::string, bool> m_suffixed_missing;
    godot::Ref<godot::ImageTexture> m_godot;
    godot::Ref<godot::ImageTexture> m_normal;
    float m_normal_strength = -1.0f;
    godot::Ref<godot::ImageTexture> m_companion_normal;
    float m_companion_strength = -1.0f;
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
    // The real image name behind a tile: an array texture's own name is not a
    // loadable image, so anything building a texture-modifier string (crack
    // overlays, inventory cubes) must resolve the layer first.
    std::string imageName(u32 texture_id, u16 layer = 0);

    // The classifier's table (docs/pbr-plan.md step 2), owned by the session,
    // read when an array's companion layers are synthesised for textures a
    // pack does not cover. Setting it drops every cached companion array.
    void setMaterialTable(const MaterialTable *table);
    const MaterialTable *materialTable() const { return m_material_table; }
    // Strength of the relief inferred from a texture's own brightness for
    // layers with no authored _n; 0 turns inference off. The same value the
    // auto bump slider sets. Changing it drops every cached companion array.
    void setInferredReliefStrength(float strength);
    float inferredReliefStrength() const { return m_relief_strength; }
    void dropCompanions();

private:
    const MaterialTable *m_material_table = nullptr;
    float m_relief_strength = 0.35f;
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
    bool supportsSampler2DArray() const override { return true; }
    void processQueue() override {}
    void insertSourceShader(const std::string &, const std::string &, const std::string &) override {}
    void rebuildShaders() override {}
    void addShaderConstantSetter(std::unique_ptr<IShaderConstantSetter>) override {}
    void addShaderUniformSetterFactory(std::unique_ptr<IShaderUniformSetterFactory>) override {}

    // What Goanna's material builder wants to know about a shader id.
    MaterialType materialType(u32 id) const;
    video::E_MATERIAL_TYPE baseMaterial(u32 id) const;
    // True if node_visuals asked for the array-texture variant of this shader.
    bool usesArrayTexture(u32 id) const;
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
        bool array_texture = false;
    };
    std::vector<Entry> m_shaders;
    std::map<std::string, u32> m_keys;
};

} // namespace goanna
