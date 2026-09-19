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

#include <atomic>
#include <map>
#include <set>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/texture2d_array.hpp>

#include "client/imagesource.h"
#include "client/shader.h"
#include "client/texturesource.h"
#include "client/tile.h"
#include "goanna_materials.h"

class NodeDefManager;

namespace goanna {

class GoannaTextureSource;

// Whether a tile of this material type can be drawn from an array texture by
// nodes_array.gdshader. That shader culls back faces and has no wind, liquid
// or blending logic, so a double sided tile, a waving one, any liquid and a
// culled alpha blended tile (glass) each keep their own shader and a single
// image. GoannaClient::keyForIrr applies it per mesh buffer, and the
// animation arrays below are built only for tiles it admits.
inline bool arrayPathTile(MaterialType mtype, bool backface_culling) {
    if (!backface_culling)
        return false;
    switch (mtype) {
    case TILE_MATERIAL_WAVING_LEAVES:
    case TILE_MATERIAL_WAVING_PLANTS:
    case TILE_MATERIAL_LIQUID_OPAQUE:
    case TILE_MATERIAL_WAVING_LIQUID_OPAQUE:
    case TILE_MATERIAL_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_BASIC:
    case TILE_MATERIAL_ALPHA:
    case TILE_MATERIAL_PLAIN_ALPHA:
        return false;
    default:
        return true;
    }
}

// An animated node tile, as Luanti's node_visuals prepared it: the frames
// (one texture each, cut from the tile's strip or sheet by createAnimationFrames)
// and the length of one frame. Keyed by the first frame's texture id, which is
// the texture the mesher puts on every buffer of the tile.
struct NodeAnimation {
    // A copy of TileLayer::frames, so upstream's AnimationInfo can pick the
    // frame for a time exactly as MapBlockMesh::animate does.
    std::vector<FrameSpec> frames;
    u16 frame_length_ms = 0;
    // The animation array holding every frame as consecutive layers, from
    // base_layer on, or 0 if the tile is not drawn from one (see
    // GoannaTextureSource::buildNodeAnimations).
    u32 array_id = 0;
    u16 base_layer = 0;
};

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
    // What each layer's LabPBR _s map averages out to, in the units the
    // shader ends up using, so a far surface can converge to the mean
    // material response of its tile instead of to an arbitrary constant.
    //
    // Averaged after the conversion, not before: roughness is (1-smoothness)
    // squared and metalness is a threshold, so the mean of the inputs is not
    // the input of the mean. Filled while the _s array is built, which is
    // also where a layer with nothing authored gets its class-derived flat
    // map, so generated layers are counted the same as authored ones.
    struct LayerSpec {
        float rough = 1.0f;  // Godot ROUGHNESS
        float metal = 0.0f;  // Godot METALLIC
        float spec = 0.2f;   // Godot SPECULAR, before specular_strength
    };
    const std::vector<LayerSpec> &layerSpecMeans() const { return m_layer_spec; }
    // How far each layer's normal map departs from flat, as the mean of
    // dot(xy, xy) over its texels, where xy is the tangent pair the shader
    // decodes from RG. That is the squared tangent deviation, and it is
    // exactly the quantity the far field throws away when it flattens the
    // relief. Handed to the shader so it can come back as roughness: detail
    // going sub-pixel does not make a surface smoother, it makes it rougher
    // at a scale the highlight can no longer resolve. Without it a distant
    // surface is flat and still shiny, which is what reads as plastic.
    const std::vector<float> &layerNormalVariance() const { return m_layer_normal_var; }
    // A gain for this array's authored normal maps, worked out from how much
    // relief they actually carry rather than from a constant.
    //
    // A pack whose authored maps are all shallow is flat as a pack and can be
    // scaled as one. A pack with real relief must not be touched, or its
    // steep textures become noise, so this only ever raises and only when the
    // measurement says the whole set is compressed. 1.0 means leave it alone,
    // which is also what a pack with no authored normals gets, because the
    // inference has its own strength.
    float normalGain() const { return m_normal_gain; }
    // The relief depth each authored normal layer implies, as a fraction of
    // a node: the normal's tangent slope in height units per texel over the
    // height byte's gradient, at the median of the texels that have a
    // gradient, over the tile's width in texels. The two come from one
    // height field, so their ratio is that field's depth, and the parallax
    // march then agrees with the shading about how deep the surface is. 0
    // for a layer with no authored height, which the shader gives its
    // class's depth.
    const std::vector<float> &layerDepths() const { return m_layer_depth; }
    // Alpha is tracked per array layer as well as for the whole texture. A
    // solid stone layer may share an array with cut-out leaves, and treating
    // the whole array as transparent prevents the stone from being a safe
    // terrain occluder.
    bool layerHasAlpha(u16 layer) const {
        return layer >= m_layer_alpha.size() || m_layer_alpha[layer];
    }
    // Animation arrays only: for the first layer of each tile, how many
    // frames follow from it and how long each lasts, which the array shader
    // reads as layer_anim to pick the frame for the clock. Every other layer,
    // and every layer of an ordinary array, has zero frames and never moves.
    struct LayerAnim {
        u16 frames = 0;
        u16 frame_ms = 0;
    };
    const std::vector<LayerAnim> &layerAnim() const { return m_layer_anim; }
    void setLayerAnim(std::vector<LayerAnim> anim) { m_layer_anim = std::move(anim); }
    // Tangent-space normal map derived from the diffuse luminance ("auto
    // bump"): dark texels read as recessed, light as raised. Cached per
    // strength; regenerated when strength changes. Main thread only.
    godot::Ref<godot::ImageTexture> godotNormal(float strength);
    // Emission mask derived from the diffuse texture's own luminance: a
    // torch's flame or a lantern's glass is the brightest thing in its
    // tile, the handle and cage are not, so thresholding luminance picks out
    // the lit part on its own with no authored data. Cached; built once,
    // main thread only.
    godot::Ref<godot::ImageTexture> godotEmissionMask();
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
    std::vector<bool> m_layer_alpha;
    std::vector<LayerAnim> m_layer_anim;
    godot::Ref<godot::Texture2DArray> m_godot_array;
    std::map<std::string, godot::Ref<godot::Texture2DArray>> m_godot_suffixed;
    std::vector<LayerSpec> m_layer_spec;
    std::vector<float> m_layer_normal_var;
    std::vector<float> m_layer_depth;
    float m_normal_gain = 1.0f;
    std::map<std::string, bool> m_suffixed_missing;
    godot::Ref<godot::ImageTexture> m_godot;
    godot::Ref<godot::ImageTexture> m_normal;
    float m_normal_strength = -1.0f;
    godot::Ref<godot::ImageTexture> m_emission_mask;
    bool m_emission_mask_built = false;
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
    // How much of a tile's variance sits in features larger than a texel or
    // two: near 0 for an even grain like sand or stone, high for a tile whose
    // point is a few big shapes, like an ore's blobs or a cracked brick. The
    // per node tiling reads it to decide whether a tile is a field to break
    // up or a picture to leave alone. Cached: it opens the image to answer.
    float textureCoarseness(const std::string &image);
    // How much of a tile is actually there: the fraction of texels the near
    // mesh's alpha test keeps. 1.0 for an ordinary opaque tile, 0.64 to 0.82
    // for Mineclonia's leaves, near 0 for an overlay.
    //
    // The far tiers draw a leaf cell as a solid box of the leaf tile, where
    // the near mesh draws alpha tested faces you see through, so the same
    // canopy integrates brighter and more saturated at range than it does up
    // close. getTextureAverageColor answers what colour the leaf material is;
    // this is what fraction of the surface is leaf at all, which is the other
    // half of what a distant canopy should converge to. Cached: it opens the
    // image to answer.
    float textureCoverage(const std::string &image);
    // IWritableTextureSource
    void processQueue() override {}
    void insertSourceImage(const std::string &name, video::IImage *img) override;
    void rebuildImagesAndTextures() override {}

    // Goanna: register a media file's bytes as a source image (decoded here).
    bool insertMediaImage(const std::string &name, const std::string &bytes);
    // Register an explicitly selected client-pack image. Unlike server media,
    // its bytes are already the preferred local source and need no second
    // filesystem override lookup.
    bool insertLocalImage(const std::string &name, const std::string &bytes);
    GoannaTexture *goannaTexture(u32 id);
    // The real image name behind a tile: an array texture's own name is not a
    // loadable image, so anything building a texture-modifier string (crack
    // overlays, inventory cubes) must resolve the layer first.
    std::string imageName(u32 texture_id, u16 layer = 0);
    // The LabPBR companion a pack supplies for a tile (suffix "_n" or "_s"),
    // as an image name to generate, or empty when there is none. The
    // companion belongs to the base image, the part before the first
    // modifier. A tile that is one frame of a strip or sheet ("x.png^[verticalframe:8:3",
    // which is how node_visuals names an animation frame) gets the same frame
    // cut from the companion when the companion is laid out like the base,
    // and the whole companion otherwise, which is what a pack with one still
    // map for an animated tile means.
    std::string companionImage(const std::string &tile, const char *suffix);

    // Animated node tiles (docs/node-animation.md). Built once node visuals
    // are filled, on the thread that filled them, before anything is meshed
    // with them: collects every animated TileLayer and packs the frames of
    // the tiles the array shader can draw (arrayPathTile) into animation
    // arrays, each tile's frames consecutive, grouped by frame size and by
    // whether any frame has alpha. Read without a lock afterwards, from the
    // main thread and from far mesh workers, so the finished table is
    // published once through an atomic pointer and never changed.
    void buildNodeAnimations(const NodeDefManager *ndef);
    // The animation whose first frame is this texture, or nullptr. Also
    // nullptr for every tile while animation is switched off
    // (setNodeAnimationEnabled), which puts each animated tile back on its
    // first frame exactly as before animation existed: the one switch for
    // the array path, the per material frame swap and the far tiers.
    const NodeAnimation *nodeAnimation(u32 first_frame_texture_id) const {
        const auto *table = m_node_anim.load(std::memory_order_acquire);
        if (!table || !m_node_anim_enabled.load(std::memory_order_relaxed))
            return nullptr;
        auto it = table->find(first_frame_texture_id);
        return it == table->end() ? nullptr : &it->second;
    }
    using NodeAnimationTable = std::unordered_map<u32, NodeAnimation>;
    const NodeAnimationTable *nodeAnimations() const {
        return m_node_anim.load(std::memory_order_acquire);
    }
    // A kill switch and an A/B lever, off from the start with
    // GOANNA_NO_NODE_ANIM=1. Meshes and materials built before a change keep
    // what they were built with; GoannaClient::set_node_animation_enabled
    // rebuilds them.
    void setNodeAnimationEnabled(bool on) { m_node_anim_enabled.store(on); }
    bool nodeAnimationEnabled() const { return m_node_anim_enabled.load(); }

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
    std::map<std::string, float> m_coarseness;
    std::map<std::string, float> m_coverage_cache;
    ImageSource m_imagesource;
    std::vector<std::unique_ptr<GoannaTexture>> m_textures; // index = id
    std::map<std::string, u32> m_name_to_id;
    std::map<std::string, Palette> m_palettes;
    std::map<std::string, bool> m_known_source;
    // Every table ever built stays alive with the source, so a reader holding
    // a pointer from an earlier build cannot have it freed underneath it.
    std::vector<std::unique_ptr<NodeAnimationTable>> m_node_anim_tables;
    std::atomic<const NodeAnimationTable *> m_node_anim{nullptr};
    std::atomic<bool> m_node_anim_enabled{true};
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
