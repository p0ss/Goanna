// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_entities.h"

#include <set>
#include <godot_cpp/variant/utility_functions.hpp>

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
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
        en.anim_range = Vector2(-1, -1); // apply the frame loop on the next sync
        if (obj.isLocalPlayer())
            en.animator->setShrinkJoint("Head");
    } else {
        holder->add_child(mi);
    }
    en.visual = holder;
    return true;
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
        GoannaTexture *gt = dynamic_cast<GoannaTexture *>(buf->getMaterial().getTexture(0));
        std::string tname = gt ? session.tsrc()->getTextureName(gt->id()) : "";
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
        // First-person body: draw our own model too (mesh visuals only; a
        // billboard self would just block the lens). The CAO init marks the
        // local player invisible for first person, so gate on the property's
        // own is_visible rather than isVisible() there.
        bool is_self = obj.isLocalPlayer();
        bool visible = is_self
                ? (m_show_body && obj.props().visual == OBJECTVISUAL_MESH && obj.props().is_visible)
                : obj.isVisible();
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
        if (is_self) {
            // Pin the body to the predicted local player, not the
            // server-interpolated CAO, or it trails the camera; body yaw
            // follows the look yaw, pitch stays level.
            if (LocalPlayer *lp = session.player()) {
                v3f pp = lp->getPosition();
                // slightly behind the eye along the look yaw, so the
                // shoulders sit below the lens instead of filling it. The
                // horizontal look is (0,0,1).rotateXZBy(yaw) = (-sin, cos).
                float yaw_rad = lp->getYaw() * core::DEGTORAD;
                pp.X += std::sin(yaw_rad) * 1.2f;
                pp.Z -= std::cos(yaw_rad) * 1.2f;
                en.root->set_position(Vector3(pp.X / BS, pp.Y / BS, -pp.Z / BS));
                // Unlike CAO rotations, the player yaw maps to Godot yaw
                // directly; mirroring it made the body counter-rotate. The
                // model faces the camera at that yaw, so add a half turn:
                // your body should face where you look (and its right arm
                // then falls on the camera's right, which the arm pick below
                // confirms).
                en.root->set_rotation_degrees(Vector3(0, lp->getYaw() + 180.0f, 0));
            }
        }
        if (is_self && en.animator) {
            // First-person arm: pose one of the body's arms toward the view so
            // the wield item the game attaches to that bone sits in hand, and
            // swing the same pose. Which arm reads as "yours" depends on the
            // model's facing and its bone naming, so pick the one that
            // actually projects to the camera's right rather than assuming.
            float yaw = 0.0f, pitch = 0.0f;
            if (LocalPlayer *lp = session.player()) {
                yaw = lp->getYaw();
                pitch = lp->getPitch();
            }
            if (en.arm_bone.empty() && en.skeleton) {
                const char *cands[4] = {"Arm_Right_Pitch_Control", "Arm_Right",
                        "Arm_Left_Pitch_Control", "Arm_Left"};
                float yr = yaw * core::DEGTORAD;
                Vector3 cam_right(std::cos(yr), 0, -std::sin(yr));
                Transform3D body = en.skeleton->get_global_transform();
                float best = 0.0f;
                for (const char *c : cands) {
                    Transform3D j;
                    if (!en.animator->jointGlobal(c, j))
                        continue;
                    float d = (body.xform(j.origin) - body.origin).dot(cam_right);
                    if (en.arm_bone.empty() || d > best) {
                        // require a real offset, so an unstepped (identity)
                        // skeleton does not lock in a bad choice
                        if (std::fabs(d) > 0.02f) {
                            best = d;
                            en.arm_bone = c;
                        }
                    }
                }
            }
            if (!en.arm_bone.empty() && getenv("GOANNA_DEBUG_ARM")) {
                static std::string last;
                if (last != en.arm_bone) {
                    last = en.arm_bone;
                    godot::UtilityFunctions::print("arm bone chosen: ", String(en.arm_bone.c_str()));
                }
            }
            if (!en.arm_bone.empty()) {
                // Mineclonia's own Arm_Right_Pitch_Control convention:
                // x = 90 + look pitch, y pulls the arm inward, z counters a
                // little; the swing chops the same pose. Tunable: GOANNA_ARM.
                static float A[7] = {62.0f, 14.0f, 0.0f, 1.0f, 0.35f, -40.0f, 10.0f};
                static bool arm_env = [] {
                    if (const char *e = std::getenv("GOANNA_ARM"))
                        sscanf(e, "%f,%f,%f,%f,%f,%f,%f", &A[0], &A[1], &A[2], &A[3], &A[4], &A[5], &A[6]);
                    return true;
                }();
                (void)arm_env;
                v3f eul(A[0] + A[3] * pitch + A[5] * m_arm_swing,
                        A[1] + A[6] * m_arm_swing,
                        A[2] + A[4] * pitch);
                // Same convention as server bone overrides: euler degrees,
                // stored inverse (BoneSceneNode keeps rotations inverted).
                core::quaternion q(eul * core::DEGTORAD);
                q.makeInverse();
                en.animator->setJointRotationOverride(en.arm_bone, q);
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
