// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_entities.h"

#include <set>

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/skin.hpp>

#include "transplant/client/content_cao.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include <IMeshManipulator.h>
#include "client/mesh.h"
#include "constants.h"

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
    m_models[name] = model;
    return model;
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
    MeshInstance3D *mi = memnew(MeshInstance3D);
    mi->set_mesh(model->mesh);
    for (int i = 0; i < (int)model->texture_slots.size(); ++i) {
        u32 slot = model->texture_slots[i];
        std::string tex;
        if (slot < p.textures.size())
            tex = p.textures[slot];
        if (tex.empty())
            continue; // upstream: empty string means leave the material alone
        tex += obj.textureModifier();
        mi->set_surface_override_material(i, materialForTexture(session, tex, p.use_texture_alpha, !p.backface_culling));
    }
    en.animator.reset();
    en.skeleton = nullptr;
    if (model->animated) {
        Skeleton3D *sk = memnew(Skeleton3D);
        const auto &joints = model->skinned->getAllJoints();
        std::set<std::string> used;
        for (int i = 0; i < model->bone_count; ++i) {
            // Godot wants unique bone names; models may repeat them (and the
            // extra rigid-attachment bones have none). Lookups use indices.
            std::string name = (i < model->joint_count && joints[i]->Name) ? *joints[i]->Name : "";
            if (name.empty() || used.count(name))
                name += "#" + std::to_string(i);
            used.insert(name);
            sk->add_bone(String::utf8(name.c_str()));
        }
        Ref<Skin> skin;
        skin.instantiate();
        for (int i = 0; i < model->bone_count; ++i)
            skin->add_bind(i, Transform3D());
        mi->set_skin(skin);
        sk->add_child(mi);
        mi->set_skeleton_path(NodePath(".."));
        holder->add_child(sk);
        en.skeleton = sk;
        en.animator = std::make_unique<ModelAnimator>(model);
        en.anim_version = 0; // apply the animation state on the next sync
    } else {
        holder->add_child(mi);
    }
    en.visual = holder;
    return true;
}

void EntityRenderer::rebuildVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en) {
    if (en.visual) {
        en.visual->queue_free();
        en.visual = nullptr;
    }
    en.skeleton = nullptr;
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
        [[fallthrough]];
    case OBJECTVISUAL_ITEM:
    case OBJECTVISUAL_WIELDITEM:
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
        d["visual"] = (int)obj.props().visual;
        d["mesh"] = String::utf8(obj.props().mesh.c_str());
        d["frame"] = kv.second.animator ? kv.second.animator->frame() : -1.0f;
        a.push_back(d);
    }
    return a;
}

void EntityRenderer::sync(GoannaSession &session, float dt, const Vector3 &camera_pos) {
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
        bool visible = obj.isVisible() && !obj.isLocalPlayer();
        en.root->set_visible(visible);
        if (!visible)
            continue;
        if (en.visual_version != obj.visualVersion())
            rebuildVisual(session, obj, en);
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
        // Luanti yaw: rotation.Y degrees; mirrored z flips the sense of yaw
        en.root->set_rotation_degrees(Vector3(rot.X, -rot.Y, -rot.Z));
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
        // skeletal animation: GenericCAO::updateAnimation, then a step
        if (en.animator) {
            if (en.anim_version != obj.animVersion()) {
                v2f range = obj.animRange();
                en.animator->setFrameLoop(range.X, range.Y);
                en.animator->setAnimationSpeed(obj.animSpeed());
                en.animator->setTransitionTime(obj.animBlend());
                en.animator->setLoopMode(obj.animLoop());
                en.anim_version = obj.animVersion();
            }
            en.animator->step(dt, obj.boneOverridesMut(), en.skeleton);
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
