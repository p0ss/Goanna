// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_entities.h"

#include "goanna_materials.h"

#include <algorithm>
#include <set>
#include <variant>
#include <vector>
#include <godot_cpp/variant/utility_functions.hpp>

#include <godot_cpp/classes/geometry_instance3d.hpp>

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/skin.hpp>

#include "transplant/client/content_cao.h"
#include "transplant/localplayer.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include <IMeshManipulator.h>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <S3DVertex.h>
#include "inventory.h"
#include "client/mesh.h"
#include "transplant/client/wieldmesh.h"
#include "goanna_luanti_client.h"
#include "constants.h"
#include "light.h"
#include "nodedef.h"

using namespace godot;

namespace goanna {

EntityRenderer::~EntityRenderer() {
    // Entity nodes are children of the client node and are freed with it.
}

Ref<StandardMaterial3D> EntityRenderer::materialForTexture(GoannaSession &session,
        const std::string &texture, bool alpha, bool double_sided) {
    std::string key = texture + (alpha ? "|a" : "|o") + (double_sided ? "|d" : "|s");
    auto it = m_materials.find(key);
    if (it != m_materials.end())
        return it->second;
    Ref<StandardMaterial3D> mat;
    mat.instantiate();
    mat->set_roughness(1.0f);
    mat->set_texture_filter(BaseMaterial3D::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS);
    mat->set_cull_mode(double_sided ? BaseMaterial3D::CULL_DISABLED : BaseMaterial3D::CULL_BACK);
    u32 tid = session.tsrc()->getTextureId(texture);
    GoannaTexture *gt = session.tsrc()->goannaTexture(tid);
    if (gt) {
        Ref<ImageTexture> tex = gt->godotTexture();
        if (tex.is_valid())
            mat->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, tex);
        if (alpha) {
            mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
            mat->set_depth_draw_mode(BaseMaterial3D::DEPTH_DRAW_ALWAYS);
        } else if (gt->hasAlpha()) {
            mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR);
            mat->set_alpha_scissor_threshold(0.5f);
        }
    } else {
        mat->set_albedo(Color(0.8, 0.3, 0.8));
    }
    m_materials[key] = mat;
    return mat;
}

// `image`'s LabPBR companion, under the first of its names a pack or the
// server has (companionNames), or null.
static GoannaTexture *findCompanion(GoannaSession &session, const std::string &image,
        const char *suffix) {
    for (const std::string &name : companionNames(image, suffix)) {
        if (!session.tsrc()->isKnownSourceImage(name))
            continue;
        if (auto *cgt = dynamic_cast<GoannaTexture *>(session.tsrc()->getTexture(name)))
            return cgt;
    }
    return nullptr;
}

static Rgba8 toRgba8(video::IImage *img) {
    Rgba8 out;
    if (!img)
        return out;
    out.w = (int)img->getDimension().Width;
    out.h = (int)img->getDimension().Height;
    out.px.resize((size_t)out.w * out.h * 4);
    for (int y = 0; y < out.h; ++y)
        for (int x = 0; x < out.w; ++x) {
            const video::SColor c = img->getPixel(x, y);
            uint8_t *d = &out.px[((size_t)y * out.w + x) * 4];
            d[0] = c.getRed();
            d[1] = c.getGreen();
            d[2] = c.getBlue();
            d[3] = c.getAlpha();
        }
    return out;
}

Ref<Texture2D> EntityRenderer::companionTexture(GoannaSession &session,
        const std::string &image, const char *suffix) {
    GoannaTexture *cgt = findCompanion(session, image, suffix);
    return cgt ? Ref<Texture2D>(cgt->godotTexture()) : Ref<Texture2D>();
}

Ref<Texture2D> EntityRenderer::compositeCompanion(GoannaSession &session,
        const std::string &texture, const std::vector<OverlayLayer> &layers, const char *suffix) {
    const std::string key = texture + "|" + suffix;
    auto it = m_composite_companions.find(key);
    if (it != m_composite_companions.end())
        return it->second;
    Ref<Texture2D> result;
    // Kept alive until the composite is built; CompanionLayer points into them.
    std::vector<Rgba8> albedos(layers.size()), comps(layers.size());
    std::vector<CompanionLayer> inputs(layers.size());
    bool any = false;
    for (size_t i = 0; i < layers.size(); ++i) {
        GoannaTexture *cgt = findCompanion(session, layers[i].image, suffix);
        if (cgt && cgt->image()) {
            comps[i] = toRgba8(cgt->image());
            any = true;
        }
        auto *agt = dynamic_cast<GoannaTexture *>(session.tsrc()->getTexture(layers[i].image));
        if (agt)
            albedos[i] = toRgba8(agt->image());
        inputs[i] = {&albedos[i], &comps[i], layers[i].opacity};
    }
    // With nothing authored in any layer there is nothing to composite, and
    // the caller's fallbacks (inferred relief, the class) apply as before.
    if (any) {
        const bool normal = suffix[1] == 'n';
        Rgba8 out = compositeCompanions(inputs, normal ? kNormalKind : kSpecKind);
        if (!out.empty()) {
            PackedByteArray data;
            data.resize((int64_t)out.px.size());
            std::copy(out.px.begin(), out.px.end(), data.ptrw());
            Ref<Image> img = Image::create_from_data(out.w, out.h, false, Image::FORMAT_RGBA8, data);
            if (img.is_valid()) {
                img->generate_mipmaps();
                result = ImageTexture::create_from_image(img);
            }
        }
    }
    m_composite_companions[key] = result;
    return result;
}

Ref<Material> EntityRenderer::materialForMeshTexture(GoannaSession &session,
        const std::string &texture, bool alpha, bool double_sided, bool item) {
    std::string key = texture + (alpha ? "|a" : "|o") + (double_sided ? "|d" : "|s") +
            (item ? "|i" : "|m");
    auto it = m_mesh_materials.find(key);
    if (it != m_mesh_materials.end())
        return it->second;

    u32 tid = session.tsrc()->getTextureId(texture);
    GoannaTexture *gt = session.tsrc()->goannaTexture(tid);
    // LabPBR companions and auto-bump both assume a surface Goanna is free to
    // relight; alpha and alpha-scissor entities keep materialForTexture's
    // plain material unchanged (see the declaration in goanna_entities.h for
    // why that means a separate function and cache rather than a mode on it).
    Ref<Texture2D> normal_tex, spec_tex;
    int composite_layers = 0;
    if (gt && !alpha) {
        const char *no_pbr_env = getenv("GOANNA_NO_PBR");
        if (!no_pbr_env || !*no_pbr_env) {
            // A plain overlay stack (a villager's base, biome, profession and
            // badge; a golem's crack) gets companions composited the same
            // way, so each layer's own maps show where it covers
            // (goanna_overlay_companions.h). Anything else, or a single
            // image, takes the base image's companions: a texture modifier
            // (transform, combine, mask) is baked into the rendered image and
            // has no file of its own to look a companion up for.
            std::vector<OverlayLayer> layers;
            if (parseOverlayLayers(texture, layers) && layers.size() > 1) {
                normal_tex = compositeCompanion(session, texture, layers, "_n");
                spec_tex = compositeCompanion(session, texture, layers, "_s");
                composite_layers = (int)layers.size();
            } else {
                std::string base = layers.size() == 1 ? layers[0].image
                        : texture.substr(0, texture.find('^'));
                normal_tex = companionTexture(session, base, "_n");
                spec_tex = companionTexture(session, base, "_s");
            }
        }
    }

    // No authored relief: the same inference the node array path makes for
    // an unauthored layer, in the convention entity.gdshader decodes.
    if (gt && !alpha && !normal_tex.is_valid() && m_auto_bump > 0.0f)
        normal_tex = gt->godotCompanionNormal(m_auto_bump);

    Ref<Material> result;
    // Every opaque mesh surface goes through entity.gdshader, companions or
    // not: it is where the node light reaches an entity (the node_light
    // instance uniform EntityRenderer::sync sets), which StandardMaterial3D
    // has no way to take.
    const int diamond_mode = gemTextureCode(texture);
    if (gt && !alpha && (!double_sided || diamond_mode != 0)) {
        if (!m_sh_entity.is_valid())
            m_sh_entity = m_root->call("load_view_shader", "res://shaders/entity.gdshader");
        if (!m_sh_entity_scissor.is_valid())
            m_sh_entity_scissor = m_root->call("load_view_shader", "res://shaders/entity_scissor.gdshader");
        Ref<ShaderMaterial> sm;
        sm.instantiate();
        // Most mob skins have transparent texels, so the cut out variant is
        // the common case; see entity_scissor.gdshader.
        sm->set_shader(gt->hasAlpha() ? m_sh_entity_scissor : m_sh_entity);
        // Only gem items enter the blended pipeline. Holes in their
        // art are discarded; wood and armour joins remain fully opaque.
        if (diamond_mode != 0) {
            Ref<Shader> &shader = double_sided ? m_sh_diamond_double : m_sh_diamond;
            if (!shader.is_valid())
                shader = m_root->call("load_view_shader", double_sided ?
                        "res://shaders/entity_diamond_double_sided.gdshader" :
                        "res://shaders/entity_diamond.gdshader");
            sm->set_shader(shader);
        }
        sm->set_shader_parameter("albedo", gt->godotTexture());
        // What this thing is made of. The node path learns that from the
        // classifier and carries it in a generated _s (goanna_textures.cpp),
        // but an item, a tool, a piece of armour or a mob skin is a texture
        // rather than a node: it has no footstep, no groups and no drawtype,
        // so nothing ever reached it and every one of them shaded as the flat
        // rough dielectric this shader falls back to. Mineclonia ships no _s
        // for any of them either. Ask the table first, in case the texture is
        // also a node tile, then fall back to the name.
        // GOANNA_NO_CLASS=1 withholds it, the same A/B switch GOANNA_NO_NORMAL
        // gives the node path: two runs of one scene, one variable, rather
        // than an argument about a screenshot.
        std::string cbase = texture.substr(0, texture.find('^'));
        MaterialClass cls = MaterialClass::None;
        if (!getenv("GOANNA_NO_CLASS")) {
            cls = session.materialTable().textureClass(tileBaseName(cbase));
            // The name is a fair guess for an item ("iron" in a pickaxe's)
            // and a poor one for a skin: Mineclonia's iron golem became
            // wholly metallic, which has no diffuse, so where only the moon
            // and sky fill reached it, it drew black.
            if (cls == MaterialClass::None && item)
                cls = classifyName(cbase);
        }
        const ClassSpec &csp = classSpec(cls);
        sm->set_shader_parameter("mat_class", (int)cls);
        sm->set_shader_parameter("class_smoothness", csp.smoothness);
        sm->set_shader_parameter("class_f0", csp.f0);
        sm->set_shader_parameter("class_metal", csp.metal ? 1.0f : 0.0f);
        sm->set_shader_parameter("class_sss", csp.sss);
        sm->set_shader_parameter("diamond_mode", diamond_mode);
        // Wearable armour uses the player atlas; inventory art and tools
        // use one tile. Companions may upscale either without adding facets.
        const bool armour_atlas = texture.find("armor") != std::string::npos &&
                texture.find("_inv_") == std::string::npos;
        sm->set_shader_parameter("diamond_texels",
                armour_atlas ? Vector2(64, 32) : Vector2(16, 16));
        if (getenv("GOANNA_DEBUG_ENTITY_PBR"))
            UtilityFunctions::print("entity class: ", String::utf8(cbase.c_str()),
                    " -> ", String(className(cls)));
        sm->set_shader_parameter("has_normal", normal_tex.is_valid());
        sm->set_shader_parameter("has_spec", spec_tex.is_valid());
        if (normal_tex.is_valid())
            sm->set_shader_parameter("normal_tex", normal_tex);
        if (spec_tex.is_valid())
            sm->set_shader_parameter("spec_tex", spec_tex);
        result = sm;
    } else {
        // Blended surfaces and non-diamond double sided surfaces retain
        // their existing material path.
        result = materialForTexture(session, texture, alpha, double_sided);
    }
    if (getenv("GOANNA_DEBUG_ENTITY_PBR"))
        UtilityFunctions::print("entity pbr: ", String::utf8(texture.c_str()),
                " normal=", normal_tex.is_valid(), " spec=", spec_tex.is_valid(),
                " layers=", composite_layers);
    m_mesh_materials[key] = result;
    return result;
}

std::shared_ptr<GodotModel> EntityRenderer::modelFor(GoannaSession &session, const std::string &name) {
    auto it = m_models.find(name);
    if (it != m_models.end())
        return it->second;
    std::shared_ptr<GodotModel> model;
    // GenericCAO::addToScene: shared (cached) mesh, normals recalculated if
    // the file has none.
    if (scene::IAnimatedMesh *mesh = session.models().getMesh(name, true)) {
        if (!checkMeshNormals(mesh))
            session.models().manipulator()->recalculateNormals(mesh, true, false);
        model = buildGodotModel(mesh);
        mesh->drop();
    }
    // Only a success is remembered. Caching the failure meant one lookup that
    // ran before the model's media had arrived condemned that model to the
    // placeholder for the rest of the session, and for the local player the
    // placeholder is a capsule at the lens.
    if (model)
        m_models[name] = model;
    return model;
}

// Godot wants unique bone names; models may repeat them (and the extra
// rigid-attachment bones have none). Lookups use indices.
static std::vector<String> modelBoneNames(const GodotModel &model) {
    const auto &joints = model.skinned->getAllJoints();
    std::vector<String> names;
    std::set<std::string> used;
    for (int i = 0; i < model.bone_count; ++i) {
        std::string name = (i < model.joint_count && joints[i]->Name) ? *joints[i]->Name : "";
        if (name.empty() || used.count(name))
            name += "#" + std::to_string(i);
        used.insert(name);
        names.push_back(String::utf8(name.c_str()));
    }
    return names;
}

// A skinned mesh instance under its own Skeleton3D with identity binds, so
// the bone poses ModelAnimator writes are the skin matrices themselves.
static Skeleton3D *skinUnderSkeleton(const GodotModel &model,
        const std::vector<String> &bone_names, MeshInstance3D *m, Node3D *parent) {
    Skeleton3D *sk = memnew(Skeleton3D);
    for (const String &n : bone_names)
        sk->add_bone(n);
    Ref<Skin> skin;
    skin.instantiate();
    for (int i = 0; i < model.bone_count; ++i)
        skin->add_bind(i, Transform3D());
    m->set_skin(skin);
    sk->add_child(m);
    m->set_skeleton_path(NodePath(".."));
    parent->add_child(sk);
    return sk;
}

// OBJECTVISUAL_MESH: the model under a node scaled from mesh units (BS) by
// visual_size; skinned models get a Skeleton3D with identity binds whose
// bone poses are the skin matrices, so Godot does the skinning.
bool EntityRenderer::buildMeshVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en,
        scene::IAnimatedMesh **source) {
    const ObjectProperties &p = obj.props();
    std::shared_ptr<GodotModel> model = modelFor(session, p.mesh);
    if (!model)
        return false;
    *source = model->source;
    Node3D *holder = memnew(Node3D);
    holder->set_scale(Vector3(p.visual_size.X, p.visual_size.Y, p.visual_size.Z) / BS);
    auto build_instance = [&]() {
        MeshInstance3D *m = memnew(MeshInstance3D);
        m->set_mesh(model->mesh);
        for (int i = 0; i < (int)model->texture_slots.size(); ++i) {
            u32 slot = model->texture_slots[i];
            std::string tex;
            if (slot < p.textures.size())
                tex = p.textures[slot];
            if (tex.empty())
                continue; // upstream: empty string means leave the material alone
            tex += obj.textureModifier();
            m->set_surface_override_material(i,
                    materialForMeshTexture(session, tex, p.use_texture_alpha, !p.backface_culling));
        }
        return m;
    };
    MeshInstance3D *mi = build_instance();
    en.animator.reset();
    en.skeleton = nullptr;
    en.shadow_skeleton = nullptr;
    if (model->animated) {
        std::vector<String> bone_names = modelBoneNames(*model);
        auto skin_under_skeleton = [&](MeshInstance3D *m) {
            return skinUnderSkeleton(*model, bone_names, m, holder);
        };
        en.skeleton = skin_under_skeleton(mi);
        en.animator = std::make_unique<ModelAnimator>(model);
        if (obj.isLocalPlayer()) {
            en.animator->setShrinkJoint("Head");
            // The head is shrunk out of the lens, which also took it out of
            // the shadow: one skinned mesh cannot be headless to the camera
            // and whole to the light. So the local player gets a second copy
            // of the same mesh on its own skeleton, posed without the shrink
            // and drawn into the shadow pass only, and the copy the camera
            // sees stops casting. The cost is one extra skinned draw for one
            // entity.
            MeshInstance3D *shadow_mi = build_instance();
            en.shadow_skeleton = skin_under_skeleton(shadow_mi);
            shadow_mi->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_SHADOWS_ONLY);
            mi->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
        }
    } else {
        holder->add_child(mi);
    }
    en.visual = holder;
    return true;
}

// GUIScene::setTexture: nearest filtered, alpha tested at 0.5 and drawn from
// both sides. Unshaded because upstream's GUI scene manager holds no lights,
// so the preview is the flat texture and nothing else, whatever the time of
// day is doing to the world behind the formspec.
Ref<StandardMaterial3D> EntityRenderer::materialForPreviewTexture(GoannaSession &session,
        const std::string &texture) {
    std::string key = "model[]|" + texture;
    auto it = m_materials.find(key);
    if (it != m_materials.end())
        return it->second;
    Ref<StandardMaterial3D> mat;
    mat.instantiate();
    mat->set_shading_mode(BaseMaterial3D::SHADING_MODE_UNSHADED);
    mat->set_texture_filter(BaseMaterial3D::TEXTURE_FILTER_NEAREST);
    mat->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
    mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR);
    mat->set_alpha_scissor_threshold(0.5f);
    u32 tid = session.tsrc()->getTextureId(texture);
    if (GoannaTexture *gt = session.tsrc()->goannaTexture(tid)) {
        Ref<ImageTexture> tex = gt->godotTexture();
        if (tex.is_valid())
            mat->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, tex);
    } else {
        mat->set_albedo(Color(0.8, 0.3, 0.8));
    }
    m_materials[key] = mat;
    return mat;
}

// The formspec model[] element. Upstream builds a whole second scene manager
// for this (guiScene.cpp); here the UI hangs the returned node under a
// SubViewport of its own and orbits a camera round it, so all that is needed
// is the mesh, its textures and the pose.
Node3D *EntityRenderer::buildModelPreview(GoannaSession &session, const std::string &mesh,
        const std::vector<std::string> &textures, float frame_begin, float frame_end,
        float speed, AABB *out_aabb) {
    std::shared_ptr<GodotModel> model = modelFor(session, mesh);
    if (!model || model->mesh.is_null() || model->mesh->get_surface_count() == 0)
        return nullptr;
    Node3D *holder = memnew(Node3D);
    MeshInstance3D *mi = memnew(MeshInstance3D);
    mi->set_mesh(model->mesh);
    for (int i = 0; i < (int)model->texture_slots.size(); ++i) {
        u32 slot = model->texture_slots[i];
        // Upstream warns "Not enough textures" and leaves the surface with
        // whatever the loader gave it.
        if (slot >= textures.size() || textures[slot].empty())
            continue;
        mi->set_surface_override_material(i, materialForPreviewTexture(session, textures[slot]));
    }
    if (out_aabb)
        *out_aabb = model->mesh->get_aabb();
    if (!model->animated) {
        holder->add_child(mi);
        return holder;
    }
    // Skinned: the rest pose the loader leaves in the vertex data is not
    // necessarily the pose the element asked for, so build the skeleton and
    // step the animator once to land on the first frame of the loop. That is
    // what upstream shows too, since animation speed defaults to zero.
    std::vector<String> bone_names = modelBoneNames(*model);
    Skeleton3D *sk = skinUnderSkeleton(*model, bone_names, mi, holder);
    Preview preview;
    preview.animator = std::make_unique<ModelAnimator>(model);
    // GUIScene::setFrameLoop and setAnimationSpeed, which play track 0 and,
    // unlike an active object's tracks, do not clamp the range to the
    // track's length: an end past the last frame holds the last frame.
    auto &track = preview.anim.tracks[0];
    track.setFrameRange(frame_begin, frame_end);
    track.cur_frame = track.fps >= 0 ? frame_begin : frame_end;
    track.fps = speed;
    std::map<std::string, BoneOverride> no_overrides;
    preview.animator->step(0.0f, preview.anim, no_overrides, sk);
    if (speed != 0.0f)
        m_previews[(uint64_t)sk->get_instance_id()] = std::move(preview);
    return holder;
}

void EntityRenderer::stepModelPreviews(float dt) {
    if (m_previews.empty())
        return;
    std::map<std::string, BoneOverride> no_overrides;
    for (auto it = m_previews.begin(); it != m_previews.end();) {
        Skeleton3D *sk = Object::cast_to<Skeleton3D>(
                UtilityFunctions::instance_from_id((int64_t)it->first));
        if (!sk) {
            // The formspec that owned it has been closed.
            it = m_previews.erase(it);
            continue;
        }
        it->second.animator->step(dt, it->second.anim, no_overrides, sk);
        ++it;
    }
}

// OBJECTVISUAL_ITEM / OBJECTVISUAL_WIELDITEM: build the item's wield mesh with
// Luanti's own wieldmesh code and convert it to an ArrayMesh. Vertex colours
// carry the item/tile colour (setColor bakes them), so the material reads
// albedo from vertex colour.
Ref<ArrayMesh> EntityRenderer::buildItemMesh(GoannaSession &session, const ItemStack &item,
        bool check_wield_image, v3f *out_scale, bool relit) {
    WieldMesh wm;
    wm.setItem(item, session.meshClient(), check_wield_image);
    scene::IMesh *mesh = wm.getMesh();
    if (out_scale)
        *out_scale = wm.getScale() / BS;
    if (!mesh || mesh->getMeshBufferCount() == 0)
        return Ref<ArrayMesh>();

    Ref<ArrayMesh> am;
    am.instantiate();
    for (u32 b = 0; b < mesh->getMeshBufferCount(); ++b) {
        scene::IMeshBuffer *buf = mesh->getMeshBuffer(b);
        if (buf->getVertexType() != video::EVT_STANDARD)
            continue;
        const video::S3DVertex *v = (const video::S3DVertex *)buf->getVertices();
        const u16 *idxs = (const u16 *)buf->getIndices();
        u32 nv = buf->getVertexCount(), ni = buf->getIndexCount();
        if (!nv || !ni)
            continue;
        PackedVector3Array verts, norms;
        PackedVector2Array uvs;
        PackedColorArray cols;
        PackedInt32Array idx;
        verts.resize(nv); norms.resize(nv); uvs.resize(nv); cols.resize(nv);
        for (u32 i = 0; i < nv; ++i) {
            verts[i] = Vector3(v[i].Pos.X, v[i].Pos.Y, -v[i].Pos.Z);
            norms[i] = Vector3(v[i].Normal.X, v[i].Normal.Y, -v[i].Normal.Z);
            uvs[i] = Vector2(v[i].TCoords.X, v[i].TCoords.Y);
            cols[i] = Color(v[i].Color.getRed() / 255.0f, v[i].Color.getGreen() / 255.0f,
                    v[i].Color.getBlue() / 255.0f, v[i].Color.getAlpha() / 255.0f);
        }
        idx.resize(ni);
        for (u32 i = 0; i < ni; ++i)
            idx[i] = idxs[i];
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = verts;
        arrays[Mesh::ARRAY_NORMAL] = norms;
        arrays[Mesh::ARRAY_TEX_UV] = uvs;
        arrays[Mesh::ARRAY_COLOR] = cols;
        arrays[Mesh::ARRAY_INDEX] = idx;
        am->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
        // Node tiles may be array textures now; an entity material wants a
        // plain 2D image, so resolve this buffer's layer back to its own
        // image or the item renders as an untextured white cube.
        GoannaTexture *gt = dynamic_cast<GoannaTexture *>(buf->getMaterial().getTexture(0));
        std::string tname;
        if (gt && gt->isArray()) {
            u16 aux = nv ? v[0].Aux : 0;
            const auto &names = gt->layerNames();
            if (aux < names.size())
                tname = names[aux];
        } else if (gt) {
            tname = session.tsrc()->getTextureName(gt->id());
        }
        // An item in the world (held in a hand, dropped on the ground) is
        // lit as a mob is: the entity shader, with the pack's _n and _s and
        // the node light where it stands. The plain material had neither,
        // so a held tool or block ignored the pack its placed twin used.
        // Inventory icons keep the plain one; they are drawn in their own
        // small scene, not the world's light.
        if (relit) {
            Ref<ShaderMaterial> sm = materialForMeshTexture(session, tname, false, false, true);
            if (sm.is_valid()) {
                Ref<ShaderMaterial> s2 = sm->duplicate();
                s2->set_shader_parameter("vertex_tint", true);
                am->surface_set_material(am->get_surface_count() - 1, s2);
                continue;
            }
        }
        Ref<StandardMaterial3D> mat = materialForTexture(session, tname, false, true);
        Ref<StandardMaterial3D> m2 = mat->duplicate();
        m2->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
        am->surface_set_material(am->get_surface_count() - 1, m2);
    }
    if (am->get_surface_count() == 0)
        return Ref<ArrayMesh>();
    return am;
}

bool EntityRenderer::buildItemVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en) {
    const ObjectProperties &p = obj.props();
    IItemDefManager *idef = session.getItemDefManager();
    ItemStack item;
    if (p.wield_item.empty()) {
        if (!p.textures.empty())
            item = ItemStack(p.textures[0], 1, 0, idef);
    } else {
        item.deSerialize(p.wield_item, idef);
    }
    v3f wield_scale(1, 1, 1);
    Ref<ArrayMesh> am = buildItemMesh(session, item, p.visual == OBJECTVISUAL_WIELDITEM, &wield_scale,
            true);
    if (am.is_null())
        return false;
    MeshInstance3D *mi = memnew(MeshInstance3D);
    mi->set_mesh(am);
    // content_cao: the wield node is scaled by visual_size/2 on top of the
    // wield mesh's own scale (already in Godot units from buildItemMesh).
    v3f sc = p.visual_size / 2.0f * wield_scale;
    Node3D *holder = memnew(Node3D);
    holder->set_scale(Vector3(sc.X, sc.Y, sc.Z));
    holder->add_child(mi);
    en.visual = holder;
    return true;
}

void EntityRenderer::rebuildVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en) {
    if (en.visual) {
        en.visual->queue_free();
        en.visual = nullptr;
    }
    en.skeleton = nullptr;
    en.shadow_skeleton = nullptr;
    // The new meshes start at node_light's default; sync sets it again.
    en.light_known = false;
    std::unique_ptr<ModelAnimator> previous = std::move(en.animator);
    scene::IAnimatedMesh *source = nullptr;
    const ObjectProperties &p = obj.props();
    std::string tex0 = p.textures.empty() ? "" : p.textures[0];
    if (!obj.textureModifier().empty() && !tex0.empty())
        tex0 += obj.textureModifier();
    Vector3 vs(p.visual_size.X, p.visual_size.Y, p.visual_size.Z);
    switch (p.visual) {
    case OBJECTVISUAL_SPRITE:
    case OBJECTVISUAL_UPRIGHT_SPRITE: {
        // A billboard quad; textures[0] is a sprite sheet divided by spritediv.
        MeshInstance3D *mi = memnew(MeshInstance3D);
        Ref<QuadMesh> qm;
        qm.instantiate();
        qm->set_size(Vector2(vs.x, vs.y));
        mi->set_mesh(qm);
        Ref<StandardMaterial3D> mat = materialForTexture(session, tex0, p.use_texture_alpha, true);
        Ref<StandardMaterial3D> m2 = mat->duplicate();
        if (p.visual == OBJECTVISUAL_SPRITE)
            m2->set_billboard_mode(BaseMaterial3D::BILLBOARD_ENABLED);
        else
            m2->set_billboard_mode(BaseMaterial3D::BILLBOARD_FIXED_Y);
        m2->set_shading_mode(BaseMaterial3D::SHADING_MODE_PER_PIXEL);
        // sprite sheet: show frame (0,0) of spritediv; frames step in sync()
        m2->set_uv1_scale(Vector3(1.0f / std::max<int>(1, p.spritediv.X), 1.0f / std::max<int>(1, p.spritediv.Y), 1));
        mi->set_material_override(m2);
        en.visual = mi;
        break;
    }
    case OBJECTVISUAL_CUBE: {
        MeshInstance3D *mi = memnew(MeshInstance3D);
        Ref<BoxMesh> bm;
        bm.instantiate();
        bm->set_size(vs);
        mi->set_mesh(bm);
        mi->set_material_override(materialForTexture(session, tex0, p.use_texture_alpha, false));
        en.visual = mi;
        break;
    }
    case OBJECTVISUAL_MESH:
        if (buildMeshVisual(session, obj, en, &source))
            break;
        // The placeholder below stands where the entity is, which for anything
        // else is helpful and for the local player is a magenta capsule around
        // the camera: it is your own collision box, so you are inside it, and
        // in fly mode it fills the frame. Nothing at all is better; the body
        // comes back on the next visual version once the model loads.
        if (obj.isLocalPlayer())
            break;
        [[fallthrough]];
    case OBJECTVISUAL_ITEM:
    case OBJECTVISUAL_WIELDITEM:
        if (buildItemVisual(session, obj, en))
            break;
        [[fallthrough]];
    case OBJECTVISUAL_NODE:
    default: {
        // Placeholder for item/node visuals (and models that failed to load):
        // a capsule sized by the collision box, tinted with the first texture.
        MeshInstance3D *mi = memnew(MeshInstance3D);
        Ref<CapsuleMesh> cm;
        cm.instantiate();
        aabb3f cb = p.collisionbox;
        float h = std::max(0.3f, cb.MaxEdge.Y - cb.MinEdge.Y);
        float r = std::max(0.15f, (cb.MaxEdge.X - cb.MinEdge.X) * 0.5f);
        cm->set_height(h);
        cm->set_radius(std::min(r, h * 0.5f));
        mi->set_mesh(cm);
        mi->set_position(Vector3(0, (cb.MinEdge.Y + cb.MaxEdge.Y) * 0.5f, 0));
        mi->set_material_override(materialForTexture(session, tex0, false, false));
        en.visual = mi;
        break;
    }
    }
    if (en.visual)
        en.root->add_child(en.visual);
    // What GenericCAO::addToScene, or its visual expiry, does for animation:
    // the object's tracks now resolve against this mesh, and carry on from
    // the frames they had reached if the mesh changed.
    obj.setAnimatedMesh(source);
    if (en.animator && previous)
        en.animator->inheritPose(*previous);
    // nametag
    if (!p.nametag.empty()) {
        if (!en.nametag) {
            en.nametag = memnew(Label3D);
            en.nametag->set_billboard_mode(BaseMaterial3D::BILLBOARD_ENABLED);
            en.nametag->set_draw_flag(Label3D::FLAG_FIXED_SIZE, true);
            en.nametag->set_pixel_size(0.004f);
            en.nametag->set_font_size(24);
            en.nametag->set_outline_size(8);
            en.root->add_child(en.nametag);
        }
        en.nametag->set_text(String::utf8(p.nametag.c_str()));
        en.nametag->set_modulate(Color(p.nametag_color.getRed() / 255.0f, p.nametag_color.getGreen() / 255.0f,
                p.nametag_color.getBlue() / 255.0f, p.nametag_color.getAlpha() / 255.0f));
        en.nametag->set_position(Vector3(0, p.collisionbox.MaxEdge.Y + 0.3f, 0));
    } else if (en.nametag) {
        en.nametag->queue_free();
        en.nametag = nullptr;
    }
    en.visual_version = obj.visualVersion();
}

PackedVector4Array EntityRenderer::grass_interactors(GoannaSession &session) const {
    std::vector<std::pair<float,Vector4>> nearby;
    const auto &objects=session.objects();
    Vector3 eye;
    if (session.player()) {
        const auto p=session.player()->getPosition();
        eye=Vector3(p.X/BS,p.Y/BS,-p.Z/BS);
        // The local body is hidden in first person. Its physical footprint
        // still parts the grass, independently of the rendered actor list.
        const auto &box=session.player()->getCollisionbox();
        const auto size=box.getExtent()/BS;
        const float radius=std::clamp(std::max(size.X,size.Z)*0.5f+0.4f,0.45f,1.8f);
        nearby.emplace_back(-1.0f,Vector4(eye.x,eye.y+box.MinEdge.Y/BS,eye.z,radius));
    }
    for (const auto &kv : m_nodes) {
        if (!kv.second.root || !kv.second.root->is_visible()) continue;
        auto it=objects.find(kv.first);
        if (it==objects.end()) continue;
        const auto &obj=*it->second;
        if (obj.isLocalPlayer()) continue; // Already reserved above, also in third person.
        const auto &props=obj.props();
        if (!props.physical && !obj.isLocalPlayer() && obj.name().empty()) continue;
        if (props.visual==OBJECTVISUAL_WIELDITEM) continue;
        Vector3 foot=kv.second.root->get_position();
        foot.y+=props.collisionbox.MinEdge.Y;
        const float distance=foot.distance_squared_to(eye);
        if (distance>48.0f*48.0f) continue;
        const auto size=props.collisionbox.getExtent();
        const float radius=std::clamp(std::max(size.X,size.Z)*0.5f+0.4f,0.45f,1.8f);
        nearby.emplace_back(distance,Vector4(foot.x,foot.y,foot.z,radius));
    }
    std::sort(nearby.begin(),nearby.end(),[](const auto &a,const auto &b){ return a.first<b.first; });
    PackedVector4Array result;
    for (size_t i=0;i<std::min<size_t>(8,nearby.size());++i) result.push_back(nearby[i].second);
    return result;
}

Array EntityRenderer::takeStrokeEvents() {
    Array out = m_stroke_events;
    m_stroke_events = Array();
    return out;
}

Array EntityRenderer::positions() const {
    Array a;
    for (auto &kv : m_nodes)
        if (kv.second.root && kv.second.root->is_visible())
            a.push_back(kv.second.root->get_position());
    return a;
}

Array EntityRenderer::list(GoannaSession &session) const {
    Array a;
    auto &objects = session.objects();
    for (auto &kv : m_nodes) {
        if (!kv.second.root || !kv.second.root->is_visible())
            continue;
        auto oit = objects.find(kv.first);
        if (oit == objects.end())
            continue;
        const GoannaActiveObject &obj = *oit->second;
        Dictionary d;
        d["id"] = (int)kv.first;
        d["name"] = String::utf8(obj.name().c_str());
        d["position"] = kv.second.root->get_position();
        d["rotation_y"] = kv.second.root->get_rotation_degrees().y;
        d["visual"] = (int)obj.props().visual;
        d["mesh"] = String::utf8(obj.props().mesh.c_str());
        float frame = -1.0f;
        if (const scene::AnimSpec *anim = obj.meshAnimation(); anim && kv.second.animator) {
            auto track = anim->tracks.find(0);
            if (track != anim->tracks.end())
                frame = track->second.cur_frame;
        }
        d["frame"] = frame;
        d["local"] = obj.isLocalPlayer();
        // A body with knees and elbows (goanna_limbs.h): its hands and feet
        // in the world, and what it is doing in the water, for wake.gd's
        // stroke splashes.
        const ModelAnimator *an = kv.second.animator.get();
        if (an && an->limbCount() && kv.second.visual && kv.second.visual->is_inside_tree()) {
            const Transform3D xf = kv.second.visual->get_global_transform();
            Array hands, feet;
            for (size_t i = 0; i < an->limbCount(); ++i) {
                Vector3 end;
                if (!an->limbEnd(i, end))
                    continue;
                (an->limb(i).kind == LimbKind::Arm ? hands : feet).push_back(xf.xform(end));
            }
            d["hands"] = hands;
            d["feet"] = feet;
            d["water_pose"] = kv.second.water_pose;
            // The movement poses now, for status and live checks.
            d["landing"] = an->landing();
            d["lean"] = an->lean();
            d["bank"] = an->bank();
        }
        a.push_back(d);
    }
    return a;
}

// One animation track for the diagnostic, numbered from 1 as the Lua API
// numbers them.
static Dictionary trackInfo(u16 track_nr, const scene::TrackAnimSpec &t) {
    Dictionary d;
    d["track"] = (int)track_nr + 1;
    d["min_frame"] = t.min_frame;
    d["max_frame"] = t.max_frame;
    d["frame"] = t.cur_frame;
    d["fps"] = t.fps;
    d["loop"] = t.loop;
    d["priority"] = t.priority;
    d["blend"] = t.blend_duration;
    d["blend_progress"] = t.blend_progress;
    return d;
}

static Array trackList(const scene::AnimSpec &anim) {
    std::vector<u16> order;
    for (const auto &kv : anim.tracks)
        order.push_back(kv.first);
    std::sort(order.begin(), order.end());
    Array a;
    for (u16 nr : order)
        a.push_back(trackInfo(nr, anim.tracks.at(nr)));
    return a;
}

// A joint's local transform in the mesh's own (Irrlicht) terms: translation
// in mesh units, rotation as the stored quaternion's euler angles in degrees.
static void putTransform(Dictionary &d, const char *prefix, const core::Transform &t) {
    v3f euler;
    t.rotation.toEuler(euler);
    euler *= core::RADTODEG;
    d[String(prefix) + "position"] = Vector3(t.translation.X, t.translation.Y, t.translation.Z);
    d[String(prefix) + "rotation"] = Vector3(euler.X, euler.Y, euler.Z);
    d[String(prefix) + "scale"] = Vector3(t.scale.X, t.scale.Y, t.scale.Z);
}

static bool sameTransform(const core::Transform &a, const core::Transform &b) {
    const float eps = 1e-4f;
    // q and -q are the same rotation
    return a.translation.getDistanceFrom(b.translation) < eps &&
            a.scale.getDistanceFrom(b.scale) < eps &&
            std::fabs(std::fabs(a.rotation.dotProduct(b.rotation)) - 1.0f) < eps;
}

Dictionary EntityRenderer::anchor(GoannaSession &session, u16 id) const {
    Dictionary d;
    auto it = m_nodes.find(id);
    auto oit = session.objects().find(id);
    if (it == m_nodes.end() || !it->second.root || oit == session.objects().end())
        return d;
    d["transform"] = it->second.root->get_transform();
    d["local"] = oit->second->isLocalPlayer();
    return d;
}

Dictionary EntityRenderer::animation(GoannaSession &session, u16 id) const {
    Dictionary d;
    auto oit = session.objects().find(id);
    if (oit == session.objects().end())
        return d;
    const GoannaActiveObject &obj = *oit->second;
    d["id"] = (int)id;
    d["mesh"] = String::utf8(obj.props().mesh.c_str());
    d["added_to_scene"] = obj.addedToScene();
    d["queued_commands"] = (int)obj.deferredAnimationCount();
    d["local_player_animation"] = obj.localPlayerAnimationActive();
    d["server_tracks"] = trackList(obj.serverAnimation());
    const scene::AnimSpec *anim = obj.meshAnimation();
    d["tracks"] = anim ? trackList(*anim) : Array();
    Array joints;
    auto nit = m_nodes.find(id);
    if (nit != m_nodes.end() && nit->second.animator && nit->second.animator->model().skinned) {
        const ModelAnimator &animator = *nit->second.animator;
        const auto &mesh_joints = animator.model().skinned->getAllJoints();
        const OldJointTransforms &posed = animator.animatedLocals();
        for (size_t i = 0; i < mesh_joints.size(); ++i) {
            Dictionary j;
            const auto &name = mesh_joints[i]->Name;
            j["name"] = String::utf8(name ? name->c_str() : "");
            const auto *rest = std::get_if<core::Transform>(&mesh_joints[i]->transform);
            if (rest)
                putTransform(j, "rest_", *rest);
            if (i < posed.size() && posed[i]) {
                putTransform(j, "", *posed[i]);
                j["at_rest"] = rest && sameTransform(*posed[i], *rest);
            }
            joints.push_back(j);
        }
    }
    d["joints"] = joints;
    return d;
}

// Which of the model's arms is the one a first-person player thinks of as
// theirs. The game itself answers this: it hangs the wield item off a bone in
// that hand, so the arm nearest that bone is the one holding the tool. Only
// when nothing is attached does this fall back to the older guess, the arm
// that projects furthest to the camera's right, which is wrong for any model
// whose arms are not laid out the way Luanti's character is.
std::string EntityRenderer::chooseArmBone(GoannaSession &session, u16 self_id, const EntityNode &en,
        float yaw) const {
    // Pitch control first on each side: it is the bone Luanti's own character
    // model gives games to aim the arm with, and turning it turns the whole
    // arm rather than bending it at the elbow.
    static const char *sides[2][2] = {{"Arm_Right_Pitch_Control", "Arm_Right"},
            {"Arm_Left_Pitch_Control", "Arm_Left"}};

    Transform3D wield_xf;
    bool have_wield = false, wield_shown = false;
    for (auto &kv : session.objects()) {
        const GoannaActiveObject &o = *kv.second;
        if (o.attachmentParent() != self_id || o.attachmentBone().empty())
            continue;
        if (o.props().visual != OBJECTVISUAL_WIELDITEM && o.props().visual != OBJECTVISUAL_ITEM)
            continue;
        // A game may hang one of these off each hand (Mineclonia gives the
        // offhand its own), and the one holding something is the main hand.
        if (have_wield && (wield_shown || !o.props().is_visible))
            continue;
        Transform3D j;
        if (!en.animator->jointGlobal(o.attachmentBone(), j))
            continue;
        wield_xf = j;
        have_wield = true;
        wield_shown = o.props().is_visible;
    }

    float yr = yaw * core::DEGTORAD;
    const Vector3 cam_right(std::cos(yr), 0, -std::sin(yr));
    const Transform3D body = en.skeleton->get_global_transform();
    int best_side = -1;
    float best_score = 0.0f;
    for (int s = 0; s < 2; ++s) {
        for (const char *name : sides[s]) {
            Transform3D j;
            if (!en.animator->jointGlobal(name, j))
                continue;
            float score;
            if (have_wield) {
                score = -j.origin.distance_to(wield_xf.origin);
            } else {
                score = (body.xform(j.origin) - body.origin).dot(cam_right);
                // An unstepped skeleton is all identity, so every joint sits
                // at the origin and every side scores the same; wait rather
                // than lock in a coin toss.
                if (std::fabs(score) <= 0.02f)
                    continue;
            }
            if (best_side < 0 || score > best_score) {
                best_side = s;
                best_score = score;
            }
        }
    }
    if (best_side < 0)
        return std::string();
    for (const char *name : sides[best_side]) {
        Transform3D j;
        if (en.animator->jointGlobal(name, j))
            return name;
    }
    return std::string();
}

void EntityRenderer::sync(GoannaSession &session, float dt, const Vector3 &camera_pos) {
    stepModelPreviews(dt);
    auto &objects = session.objects();
    // remove gone
    for (auto it = m_nodes.begin(); it != m_nodes.end();) {
        if (objects.find(it->first) == objects.end()) {
            if (it->second.root)
                it->second.root->queue_free();
            it = m_nodes.erase(it);
        } else {
            ++it;
        }
    }
    for (auto &kv : objects) {
        GoannaActiveObject &obj = *kv.second;
        EntityNode &en = m_nodes[kv.first];
        if (!en.root) {
            en.root = memnew(Node3D);
            m_root->add_child(en.root);
        }
        // First-person body: draw our own model too (mesh visuals only; a
        // billboard self would just block the lens). The CAO init marks the
        // local player invisible for first person, so gate on the property's
        // own is_visible rather than isVisible() there.
        bool is_self = obj.isLocalPlayer();
        bool visible = is_self
                ? (obj.props().visual == OBJECTVISUAL_MESH && obj.props().is_visible)
                : obj.isVisible();
        en.root->set_visible(visible);
        if (!visible)
            continue;
        // An object the renderer has not added to the scene yet is rebuilt
        // even if its visual version matches the node's: a removed object's
        // id can come back as a new object before the next sync.
        if (en.visual_version != obj.visualVersion() || !obj.addedToScene())
            rebuildVisual(session, obj, en);
        // The animation commands processMessage queued, which needed the
        // mesh this visual was built from to resolve their tracks.
        obj.applyDeferredAnimation(session.player());
        // "Show own body" hides the copy the camera sees, not the whole
        // entity: the shadow-only copy stays, so a player who does not want
        // to see their own legs still has a shadow to judge the sun by.
        if (is_self && en.skeleton)
            en.skeleton->set_visible(m_show_body || m_third_person);
        else if (is_self && en.visual)
            en.visual->set_visible(m_show_body || m_third_person);
        // pose: Luanti BS units, z mirrored; rotation.Y is yaw about Y
        v3f pos = obj.position();
        v3f rot = obj.rotation();
        Vector3 gp(pos.X / BS, pos.Y / BS, -pos.Z / BS);
        if (obj.attachmentParent() != 0) {
            auto pit = objects.find(obj.attachmentParent());
            if (pit != objects.end()) {
                v3f pp = pit->second->position();
                v3f ap = obj.attachmentPosition();
                // attachment offset is in the parent's local space (BS units), rotated by parent yaw
                v3f off = ap;
                off.rotateXZBy(pit->second->rotation().Y);
                gp = Vector3((pp.X + off.X) / BS, (pp.Y + off.Y) / BS, -(pp.Z + off.Z) / BS);
                rot = pit->second->rotation() + obj.attachmentRotation();
            }
        }
        en.root->set_position(gp);
        // Luanti yaw maps to Godot yaw directly, same as the local player's
        // body below: negating it here mirrored the facing across Z instead
        // of rotating it, which only happened to look right for north/south
        // movement and put every east/west-facing mob backwards.
        en.root->set_rotation_degrees(Vector3(rot.X, rot.Y, -rot.Z));
        // The node light where the entity stands, for entity.gdshader's
        // node_light, read at about eye height so a mob standing in a lit
        // doorway takes the doorway's light. Read every sync rather than
        // only when the entity enters another node: a mob standing still
        // kept whatever light its node had when it first arrived, so a
        // lantern placed beside it, or a block whose light came after the
        // mob, never reached it.
        const int vis = obj.props().visual;
        if (en.visual && (vis == OBJECTVISUAL_MESH || vis == OBJECTVISUAL_ITEM
                || vis == OBJECTVISUAL_WIELDITEM)) {
            const v3s16 np((s16)std::floor(pos.X / BS + 0.5f), (s16)std::floor(pos.Y / BS + 1.0f),
                    (s16)std::floor(pos.Z / BS + 0.5f));
            float sky = en.light_sky, block = en.light_block;
            bool known = false;
            const NodeDefManager *ndef = session.nodeDefs();
            MapNode n = session.map().getNode(np);
            if (ndef && n.getContent() != CONTENT_IGNORE) {
                const ContentFeatures &f = ndef->get(n);
                if (f.param_type == CPT_LIGHT) {
                    ContentLightingFlags lf = f.getLightingFlags();
                    sky = decode_light(n.getLight(LIGHTBANK_DAY, lf)) / 255.0f;
                    block = decode_light(n.getLight(LIGHTBANK_NIGHT, lf)) / 255.0f;
                    known = true;
                }
            }
            if (known && (!en.light_known || np != en.light_pos ||
                    sky != en.light_sky || block != en.light_block)) {
                en.light_pos = np;
                en.light_sky = sky;
                en.light_block = block;
                en.light_known = true;
                // Every mesh drawn for the entity. A skinned model's mesh
                // sits under a Skeleton3D under the holder, and an item's
                // under the holder that carries its scale; looking only at
                // the visual and its first child found no mesh for any
                // animated mob, so node_light stayed at its default, full
                // sky and no block light, for every one of them.
                std::vector<Node *> todo{en.visual};
                const Vector2 nl(en.light_block, en.light_sky);
                while (!todo.empty()) {
                    Node *cur = todo.back();
                    todo.pop_back();
                    if (auto *gi = Object::cast_to<GeometryInstance3D>(cur))
                        gi->set_instance_shader_parameter("node_light", nl);
                    for (int c = 0; c < cur->get_child_count(); ++c)
                        todo.push_back(cur->get_child(c));
                }
            }
        }
        // attached at a bone: follow the parent's joint from its last step
        if (obj.attachmentParent() != 0 && !obj.attachmentBone().empty()) {
            auto pit = m_nodes.find(obj.attachmentParent());
            auto pobj = objects.find(obj.attachmentParent());
            Transform3D bone_xf;
            if (pit != m_nodes.end() && pobj != objects.end() && pit->second.animator &&
                    pit->second.animator->jointGlobal(obj.attachmentBone(), bone_xf)) {
                const ObjectProperties &pp = pobj->second->props();
                Transform3D scale_xf;
                scale_xf.basis.scale(Vector3(pp.visual_size.X, pp.visual_size.Y, pp.visual_size.Z) / BS);
                v3f ap = obj.attachmentPosition(), ar = obj.attachmentRotation();
                Transform3D attach_xf(Basis::from_euler(Vector3(Math::deg_to_rad(ar.X), Math::deg_to_rad(-ar.Y),
                        Math::deg_to_rad(-ar.Z))), Vector3(ap.X, ap.Y, -ap.Z));
                Transform3D xf = pit->second.root->get_transform() * scale_xf * bone_xf * attach_xf;
                en.root->set_transform(Transform3D(xf.basis.orthonormalized(), xf.origin));
            }
        }
        if (is_self) {
            // Pin the body to the predicted local player, not the
            // server-interpolated CAO, or it trails the camera; body yaw
            // follows the look yaw, pitch stays level.
            if (LocalPlayer *lp = session.player()) {
                // Standing where the player stands, not nudged back along the
                // look. The nudge was 1.2 BS, which is 0.12 nodes, and it was
                // there to keep the shoulders out of the lens; with the head
                // shrunk there is nothing at eye height to keep out, and the
                // nudge only put the legs and the shadow 12 cm behind the
                // feet, where a player looking down can see the mismatch.
                const v3f pp = lp->getPosition();
                en.root->set_position(Vector3(pp.X / BS, pp.Y / BS, -pp.Z / BS));
                // Unlike CAO rotations, the player yaw maps to Godot yaw
                // directly; mirroring it made the body counter-rotate. No half
                // turn: the model already faces the way the player looks, and
                // adding one put the arm behind the camera.
                en.root->set_rotation_degrees(Vector3(0, lp->getYaw(), 0));
            }
        }
        if (is_self && en.animator) {
            // The local mining clock poses the wield arm. Other interactions
            // keep the game's animation and the existing fallback swing.
            float yaw = 0.0f, pitch = 0.0f;
            if (LocalPlayer *lp = session.player()) {
                yaw = lp->getYaw();
                pitch = lp->getPitch();
            }
            if (en.arm_bone.empty() && en.skeleton)
                en.arm_bone = chooseArmBone(session, kv.first, en, yaw);
            if (!en.arm_bone.empty() && getenv("GOANNA_DEBUG_ARM")) {
                static std::string last;
                if (last != en.arm_bone) {
                    last = en.arm_bone;
                    godot::UtilityFunctions::print("arm bone chosen: ", String(en.arm_bone.c_str()));
                }
            }
            if (!en.arm_bone.empty()) {
                // Degrees about the joint's pitch axis at the top of the
                // swing, and how much of the look pitch the arm takes with it
                // there, so a chop aimed at the ground lands on the ground.
                // Both come from Mineclonia's own rule for this bone: an
                // absolute (look pitch, 0, 0) while punching against a resting
                // (20, 0, 0) while holding an item, so the swing is a relative
                // (pitch - 20). Tunable: GOANNA_ARM="chop,pitch_follow".
                static float A[2] = {-20.0f, 1.0f};
                static bool arm_env = [] {
                    if (const char *e = std::getenv("GOANNA_ARM"))
                        sscanf(e, "%f,%f", &A[0], &A[1]);
                    return true;
                }();
                (void)arm_env;
                // Everything scales with the swing, so at rest the arm is
                // exactly where the model and the server left it.
                const auto &dig = session.interactState();
                const bool mining = (dig.digging && dig.dig_time_complete < 100000) || dig.dig_impact;
                const bool aimed = obj.boneOverrides().count(en.arm_bone) != 0;
                float swing = aimed ? 0.0f : m_arm_swing * (A[0] + A[1] * pitch);
                if (mining) {
                    // The game owns aiming/rest scales; we own the single
                    // lift/downstroke while mining. Contact is the aimed pose.
                    swing = (aimed ? 0.0f : dig.swing * (A[0] + A[1] * pitch))
                            + 90.0f + 45.0f * (1.0f - dig.swing);
                }
                en.animator->setJointRotationOverride(en.arm_bone, v3f(swing, 0, 0), mining);
            }
        }
        // The local player's own idle, walk and dig animations, which the
        // vanilla client plays whenever it shows the player's model.
        if (is_self)
            obj.stepLocalPlayerAnimation(session.player());
        // The water strokes (goanna_limbs.h): swimming while the game has the
        // body lying in the water, treading water while it is upright in
        // water with nothing under its feet. The local player from its own
        // physics, others from the map where they are.
        if (en.animator && en.animator->limbCount()) {
            const v3f here = is_self && session.player() ? session.player()->getPosition() : pos;
            if (en.limb_have_pos && dt > 0.0f) {
                const float across = std::hypot(here.X - en.limb_last_pos.X, here.Z - en.limb_last_pos.Z) / BS / dt;
                en.limb_speed += (std::min(across, 12.0f) - en.limb_speed) * (1.0f - std::exp(-dt / 0.2f));
            }
            const v3f prev_pos = en.limb_last_pos;
            const bool had_pos = en.limb_have_pos;
            en.limb_last_pos = here;
            en.limb_have_pos = true;
            bool in_water = false, grounded = true, alive = true, climbing = false;
            v3f vel;
            float yaw = obj.rotation().Y;
            if (is_self && session.player()) {
                LocalPlayer *lp = session.player();
                in_water = lp->in_liquid;
                grounded = lp->touching_ground;
                alive = lp->hp > 0;
                climbing = lp->is_climbing;
                vel = lp->getSpeed() / BS;
                yaw = lp->getYaw();
            } else if (const NodeDefManager *ndef = session.nodeDefs()) {
                auto node_at = [&](float up) -> const ContentFeatures & {
                    return ndef->get(session.map().getNode(v3s16((s16)std::floor(here.X / BS + 0.5f),
                            (s16)std::floor(here.Y / BS + up + 0.5f), (s16)std::floor(here.Z / BS + 0.5f))));
                };
                in_water = node_at(0.9f).isLiquid();
                climbing = node_at(0.5f).climbable;
                // Others' velocity from where they were last sync, eased:
                // their positions arrive in steps.
                if (had_pos && dt > 0.0f) {
                    const v3f raw = (here - prev_pos) / BS / dt;
                    if (raw.getLength() < 30.0f)
                        en.motion_vel += (raw - en.motion_vel) * (1.0f - std::exp(-dt / 0.1f));
                }
                vel = en.motion_vel;
                grounded = node_at(-0.2f).walkable && std::fabs(vel.Y) < 1.0f;
            }
            en.in_water = in_water;
            // Lying in the water is the game's swim pose, but a body lying
            // still on the bottom is not swimming: Mineclonia's drowned
            // player lies there in its die animation, and was seen doing
            // the crawl. So swimming wants the body off the bottom or on
            // the move, and never a dead local player.
            WaterPose wp = WaterPose::None;
            if (in_water && alive) {
                if (en.animator->bodyLying())
                    wp = (!grounded || en.limb_speed > 0.3f) ? WaterPose::Swim : WaterPose::None;
                else if (!grounded)
                    wp = en.limb_speed > 0.6f ? WaterPose::Paddle : WaterPose::Tread;
            }
            // Holding jump in water bobs a body at the surface, out of the
            // water for a moment at the top of each bob; seen live, the
            // pose dropped out every bob and the arms would flap between
            // the stroke and rest. So a water pose holds 0.8 s past the
            // last moment it applied, unless the body is dead.
            if (wp != WaterPose::None) {
                en.water_pose_age = 0.0f;
            } else {
                en.water_pose_age += dt;
                if (alive && en.water_pose != 0 && en.water_pose != (int)WaterPose::Climb
                        && en.water_pose_age < 0.8f)
                    wp = (WaterPose)en.water_pose;
            }
            // Climbing a ladder or vine, out of the water: hand over hand,
            // paced by how fast the body goes up or down.
            float pose_speed = en.limb_speed;
            if (wp == WaterPose::None && climbing && alive && (!grounded || std::fabs(vel.Y) > 0.3f)) {
                wp = WaterPose::Climb;
                pose_speed = vel.Y;
            }
            en.water_pose = (int)wp;
            en.animator->setWaterPose(wp, pose_speed);
            // How the body moves, for landing, falling, stepping up and
            // leaning into starts, stops and turns.
            BodyMotion mo;
            mo.known = true;
            mo.y = here.Y / BS;
            mo.vy = vel.Y;
            mo.grounded = grounded;
            const float speed = std::hypot(vel.X, vel.Z);
            mo.speed = speed;
            if (en.motion_have && dt > 0.0f) {
                const float ease = 1.0f - std::exp(-dt / 0.1f);
                en.motion_accel += ((speed - en.motion_speed) / dt - en.motion_accel) * ease;
                float dyaw = yaw - en.motion_yaw;
                while (dyaw > 180.0f)
                    dyaw -= 360.0f;
                while (dyaw < -180.0f)
                    dyaw += 360.0f;
                en.motion_yaw_rate += (dyaw / dt - en.motion_yaw_rate) * ease;
            }
            en.motion_speed = speed;
            en.motion_yaw = yaw;
            en.motion_have = true;
            mo.accel = std::clamp(en.motion_accel, -30.0f, 30.0f);
            mo.yaw_rate = std::clamp(en.motion_yaw_rate, -720.0f, 720.0f);
            en.animator->setMotion(mo);
        }
        // skeletal animation: AnimatedMeshSceneNode::OnAnimate on the tracks
        // playing on the object's mesh
        if (en.animator) {
            if (is_self) {
                en.animator->setShrinkEnabled(!m_third_person);
                en.animator->setFirstPerson(!m_third_person);
            }
            scene::AnimSpec none;
            scene::AnimSpec *anim = obj.meshAnimation();
            en.animator->step(dt, anim ? *anim : none, obj.boneOverridesMut(), en.skeleton,
                    en.shadow_skeleton);
            // Hands and feet crossing the water's surface this step: the
            // splash of a stroke, a kick breaking the surface.
            const size_t limbs = en.animator->limbCount();
            if (limbs && en.visual && en.visual->is_inside_tree() && (en.in_water || !en.limb_wet.empty())) {
                const NodeDefManager *ndef = session.nodeDefs();
                const Transform3D xf = en.visual->get_global_transform();
                if (en.limb_wet.size() != limbs) {
                    en.limb_wet.assign(limbs, -1);
                    en.limb_last_end.assign(limbs, Vector3());
                }
                for (size_t i = 0; i < limbs; ++i) {
                    Vector3 local_end;
                    if (!en.animator->limbEnd(i, local_end))
                        continue;
                    const Vector3 end = xf.xform(local_end);
                    const MapNode n = session.map().getNode(v3s16((s16)std::floor(end.x + 0.5f),
                            (s16)std::floor(end.y + 0.5f), (s16)std::floor(-end.z + 0.5f)));
                    const char wet = (ndef && n.getContent() != CONTENT_IGNORE && ndef->get(n).isLiquid()) ? 1 : 0;
                    if (en.limb_wet[i] >= 0 && wet != en.limb_wet[i] && dt > 0.0f && m_stroke_events.size() < 64) {
                        Dictionary ev;
                        ev["id"] = (int)kv.first;
                        ev["local"] = is_self;
                        ev["pos"] = end;
                        ev["limb"] = en.animator->limb(i).kind == LimbKind::Arm ? "hand" : "foot";
                        ev["into"] = wet != 0;
                        ev["speed"] = end.distance_to(en.limb_last_end[i]) / dt;
                        m_stroke_events.push_back(ev);
                    }
                    en.limb_wet[i] = en.in_water ? wet : -1;
                    en.limb_last_end[i] = end;
                }
                if (!en.in_water)
                    en.limb_wet.clear();
            }
        }
        // sprite frame animation
        const ObjectProperties &p = obj.props();
        if ((p.visual == OBJECTVISUAL_SPRITE || p.visual == OBJECTVISUAL_UPRIGHT_SPRITE) && en.visual) {
            int frames = std::max(1, obj.spriteFrames());
            en.sprite_time += dt;
            if (obj.spriteFrameLength() > 0 && en.sprite_time >= obj.spriteFrameLength()) {
                en.sprite_time = 0;
                en.sprite_frame = (en.sprite_frame + 1) % frames;
            }
            MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(en.visual);
            if (mi) {
                Ref<StandardMaterial3D> m = mi->get_material_override();
                if (m.is_valid()) {
                    v2s16 base = obj.spriteBasepos();
                    int sx = std::max<int>(1, p.spritediv.X), sy = std::max<int>(1, p.spritediv.Y);
                    m->set_uv1_offset(Vector3((base.X % sx) / (float)sx, ((base.Y + en.sprite_frame) % sy) / (float)sy, 0));
                }
            }
        }
        (void)camera_pos;
    }
}

} // namespace goanna
