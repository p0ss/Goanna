// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_entities.h"

#include "goanna_materials.h"

#include <set>
#include <vector>
#include <godot_cpp/variant/utility_functions.hpp>

#include <godot_cpp/classes/geometry_instance3d.hpp>

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
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

Ref<Material> EntityRenderer::materialForMeshTexture(GoannaSession &session,
        const std::string &texture, bool alpha, bool double_sided) {
    std::string key = texture + (alpha ? "|a" : "|o") + (double_sided ? "|d" : "|s");
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
    if (gt && !alpha) {
        // A texture modifier (colourise, crack overlay, transform) is baked
        // into the rendered image and has no file of its own to look a
        // companion up for; only the base name before the first ^ does.
        std::string base = texture.substr(0, texture.find('^'));
        size_t dotpos = base.rfind('.');
        std::string stem = dotpos == std::string::npos ? base : base.substr(0, dotpos);
        std::string ext = dotpos == std::string::npos ? std::string() : base.substr(dotpos);
        auto lookup = [&](const char *suffix) -> Ref<Texture2D> {
            std::string name = stem + suffix + ext;
            if (!session.tsrc()->isKnownSourceImage(name))
                return Ref<Texture2D>();
            GoannaTexture *cgt = dynamic_cast<GoannaTexture *>(session.tsrc()->getTexture(name));
            if (!cgt)
                return Ref<Texture2D>();
            return Ref<Texture2D>(cgt->godotTexture());
        };
        normal_tex = lookup("_n");
        spec_tex = lookup("_s");
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
    if (gt && !alpha && !double_sided) {
        if (!m_sh_entity.is_valid())
            m_sh_entity = ResourceLoader::get_singleton()->load("res://shaders/entity.gdshader");
        if (!m_sh_entity_scissor.is_valid())
            m_sh_entity_scissor = ResourceLoader::get_singleton()->load("res://shaders/entity_scissor.gdshader");
        Ref<ShaderMaterial> sm;
        sm.instantiate();
        // Most mob skins have transparent texels, so the cut out variant is
        // the common case; see entity_scissor.gdshader.
        sm->set_shader(gt->hasAlpha() ? m_sh_entity_scissor : m_sh_entity);
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
            if (cls == MaterialClass::None)
                cls = classifyName(cbase);
        }
        const ClassSpec &csp = classSpec(cls);
        sm->set_shader_parameter("mat_class", (int)cls);
        sm->set_shader_parameter("class_smoothness", csp.smoothness);
        sm->set_shader_parameter("class_f0", csp.f0);
        sm->set_shader_parameter("class_metal", csp.metal ? 1.0f : 0.0f);
        sm->set_shader_parameter("class_sss", csp.sss);
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
        // Alpha blended and double sided surfaces keep the plain material;
        // the entity shaders are back face culled on purpose (see their
        // headers).
        result = materialForTexture(session, texture, alpha, double_sided);
    }
    if (getenv("GOANNA_DEBUG_ENTITY_PBR"))
        UtilityFunctions::print("entity pbr: ", String::utf8(texture.c_str()),
                " normal=", normal_tex.is_valid(), " spec=", spec_tex.is_valid());
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
bool EntityRenderer::buildMeshVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en) {
    const ObjectProperties &p = obj.props();
    std::shared_ptr<GodotModel> model = modelFor(session, p.mesh);
    if (!model)
        return false;
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
        en.anim_range = Vector2(-1, -1); // apply the frame loop on the next sync
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
    auto animator = std::make_unique<ModelAnimator>(model);
    animator->setAnimationSpeed(speed);
    animator->setFrameLoop(frame_begin, frame_end);
    std::map<std::string, BoneOverride> no_overrides;
    animator->step(0.0f, no_overrides, sk);
    if (speed != 0.0f)
        m_previews[(uint64_t)sk->get_instance_id()] = std::move(animator);
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
        it->second->step(dt, no_overrides, sk);
        ++it;
    }
}

// OBJECTVISUAL_ITEM / OBJECTVISUAL_WIELDITEM: build the item's wield mesh with
// Luanti's own wieldmesh code and convert it to an ArrayMesh. Vertex colours
// carry the item/tile colour (setColor bakes them), so the material reads
// albedo from vertex colour.
Ref<ArrayMesh> EntityRenderer::buildItemMesh(GoannaSession &session, const ItemStack &item,
        bool check_wield_image, v3f *out_scale) {
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
    Ref<ArrayMesh> am = buildItemMesh(session, item, p.visual == OBJECTVISUAL_WIELDITEM, &wield_scale);
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
    en.animator.reset();
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
        if (buildMeshVisual(session, obj, en))
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
        d["frame"] = kv.second.animator ? kv.second.animator->frame() : -1.0f;
        a.push_back(d);
    }
    return a;
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
        if (en.visual_version != obj.visualVersion())
            rebuildVisual(session, obj, en);
        // "Show own body" hides the copy the camera sees, not the whole
        // entity: the shadow-only copy stays, so a player who does not want
        // to see their own legs still has a shadow to judge the sun by.
        if (is_self && en.skeleton)
            en.skeleton->set_visible(m_show_body);
        else if (is_self && en.visual)
            en.visual->set_visible(m_show_body);
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
        // node_light: read once per node the entity is in, at about eye
        // height so a mob standing in a lit doorway takes the doorway's light.
        if (en.visual && obj.props().visual == OBJECTVISUAL_MESH) {
            const v3s16 np((s16)std::floor(pos.X / BS + 0.5f), (s16)std::floor(pos.Y / BS + 1.0f),
                    (s16)std::floor(pos.Z / BS + 0.5f));
            if (np != en.light_pos || !en.light_known) {
                en.light_pos = np;
                const NodeDefManager *ndef = session.nodeDefs();
                MapNode n = session.map().getNode(np);
                if (ndef && n.getContent() != CONTENT_IGNORE) {
                    const ContentFeatures &f = ndef->get(n);
                    if (f.param_type == CPT_LIGHT) {
                        ContentLightingFlags lf = f.getLightingFlags();
                        en.light_sky = decode_light(n.getLight(LIGHTBANK_DAY, lf)) / 255.0f;
                        en.light_block = decode_light(n.getLight(LIGHTBANK_NIGHT, lf)) / 255.0f;
                        en.light_known = true;
                    }
                }
                if (MeshInstance3D *lmi = Object::cast_to<MeshInstance3D>(en.visual))
                    lmi->set_instance_shader_parameter("node_light", Vector2(en.light_block, en.light_sky));
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
            // First-person arm. Goanna does not pose it any more than it has
            // to: the game already does, and now that the dig key is reported
            // it does it for a dig as well. All that is left here is a swing
            // for a game that never touches the bone.
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
            // A game that poses this bone itself is already saying where the
            // arm goes, and now that Goanna reports the dig key it says it for
            // a dig too (Mineclonia switches to its mine animation and aims
            // the arm down the look). Adding a swing of our own on top of that
            // only overshoots, so the local swing is the fallback for games
            // that leave the bone alone, not a second opinion.
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
                float swing = m_arm_swing * (A[0] + A[1] * pitch);
                if (obj.boneOverrides().count(en.arm_bone))
                    swing = 0.0f;
                en.animator->setJointRotationOverride(en.arm_bone, v3f(swing, 0, 0));
            }
        }
        // skeletal animation: GenericCAO::updateAnimation, then a step
        if (en.animator) {
            // Only a range change restarts the frame loop. Servers resend
            // set_animation_speed and bone positions many times a second for a
            // moving mob, each bumping animVersion; re-applying setFrameLoop on
            // every bump reset the frame to the range start and made the
            // animation jitter. Speed, blend and loop are idempotent, so apply
            // them each frame without touching the current frame.
            v2f range = obj.animRange();
            Vector2 vr(range.X, range.Y);
            if (en.anim_range != vr) {
                en.animator->setFrameLoop(range.X, range.Y);
                en.anim_range = vr;
            }
            en.animator->setAnimationSpeed(obj.animSpeed());
            en.animator->setTransitionTime(obj.animBlend());
            en.animator->setLoopMode(obj.animLoop());
            en.animator->step(dt, obj.boneOverridesMut(), en.skeleton, en.shadow_skeleton);
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
