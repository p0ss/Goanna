// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// Transplanted from luanti/src/client/content_cao.cpp (GenericCAO).
// Goanna changes 2026-09, against Luanti 5.17.0: no Irrlicht scene nodes,
// so everything that built or updated a scene node is removed and replaced
// by a state snapshot the Godot side reads (goanna_entities); movement uses
// the transplanted collision code directly rather than ClientEnvironment;
// the class is goanna::GoannaActiveObject. SmoothTranslator and its wrapped
// variants, the init data and AO_CMD_* message parsing, position and
// rotation interpolation, animation, bone overrides, attachment and texture
// modifier handling are upstream code. Animation tracks (5.17.0): resolving
// a track id needs the mesh, which only the renderer has, on the main
// thread. So processMessage reads AO_CMD_SET_ANIMATION,
// AO_CMD_SET_ANIMATION_SPEED and AO_CMD_STOP_ANIMATION exactly as upstream
// does and queues them, where upstream queues only set_animation and only
// before addToScene; the renderer applies the queue through
// applyTrackAnimation, applyAnimationSpeed and stopTrackAnimation, the last
// two holding the rest of upstream's handlers unchanged. A long queue for an
// object the renderer does not draw drops the commands a later one on the
// same track makes irrelevant. AnimatedMeshNodeStandIn takes the place of
// m_animated_meshnode; setAnimatedMesh is the animation half of addToScene
// and of the visual expiry in step, and a rebuild that keeps the mesh (Goanna
// rebuilds for texture changes, upstream does not) leaves the animation
// playing. applyTrackAnimation takes the LocalPlayer as a parameter. The
// renderer advances the animation and poses the joints (goanna_animation,
// goanna_models).

#include "content_cao.h"

#include <algorithm>
#include <cassert>
#include <sstream>
#include <variant>

#include <AnimSpec.h>
#include <IAnimatedMesh.h>

#include "constants.h"
#include "log.h"
#include "transplant/collision.h"
#include "transplant/localplayer.h"
#include "util/numeric.h"
#include "util/serialize.h"

namespace goanna {

// ---- track identifiers: copied from luanti/src/client/content_cao.cpp ----

static scene::TrackId readTrackIdentifier(std::istringstream &is)
{
	// Possible formats:
	// - Track number > 0, no track name
	// - Track number = 0, track name follows
	u16 track_number = readU16(is);
	if (track_number > 0)
		return (u16)(track_number - 1);
	return deSerializeString16(is);
}

// ---- SmoothTranslator: copied from luanti/src/client/content_cao.cpp ----

template<typename T>
void SmoothTranslator<T>::init(T current)
{
	val_old = current;
	val_current = current;
	val_target = current;
	anim_time = 0;
	anim_time_counter = 0;
	aim_is_end = true;
}

template<typename T>
void SmoothTranslator<T>::update(T new_target, bool is_end_position, float update_interval)
{
	aim_is_end = is_end_position;
	val_old = val_current;
	val_target = new_target;
	if (update_interval > 0) {
		anim_time = update_interval;
	} else {
		if (anim_time < 0.001 || anim_time > 1.0)
			anim_time = anim_time_counter;
		else
			anim_time = anim_time * 0.9 + anim_time_counter * 0.1;
	}
	anim_time_counter = 0;
}

template<typename T>
void SmoothTranslator<T>::translate(f32 dtime)
{
	anim_time_counter = anim_time_counter + dtime;
	T val_diff = val_target - val_old;
	f32 moveratio = 1.0;
	if (anim_time > 0.001)
		moveratio = anim_time_counter / anim_time;
	f32 move_end = aim_is_end ? 1.0 : 1.5;
	// Move a bit less than should, to avoid oscillation
	moveratio = std::min(moveratio * 0.8f, move_end);
	val_current = val_old + val_diff * moveratio;
}

template struct SmoothTranslator<v3f>;

void SmoothTranslatorWrappedv3f::translate(f32 dtime)
{
	anim_time_counter = anim_time_counter + dtime;
	v3f val_diff_v3f;
	val_diff_v3f.X = std::abs(val_target.X - val_old.X);
	val_diff_v3f.Y = std::abs(val_target.Y - val_old.Y);
	val_diff_v3f.Z = std::abs(val_target.Z - val_old.Z);
	if (val_diff_v3f.X > 180.f)
		val_diff_v3f.X = 360.f - val_diff_v3f.X;
	if (val_diff_v3f.Y > 180.f)
		val_diff_v3f.Y = 360.f - val_diff_v3f.Y;
	if (val_diff_v3f.Z > 180.f)
		val_diff_v3f.Z = 360.f - val_diff_v3f.Z;
	f32 moveratio = 1.0;
	if (anim_time > 0.001)
		moveratio = anim_time_counter / anim_time;
	f32 move_end = aim_is_end ? 1.0 : 1.5;
	// Move a bit less than should, to avoid oscillation
	moveratio = std::min(moveratio * 0.8f, move_end);
	wrappedApproachShortest(val_current.X, val_target.X, val_diff_v3f.X * moveratio, 360.f);
	wrappedApproachShortest(val_current.Y, val_target.Y, val_diff_v3f.Y * moveratio, 360.f);
	wrappedApproachShortest(val_current.Z, val_target.Z, val_diff_v3f.Z * moveratio, 360.f);
}

// ---- GoannaActiveObject ----

GoannaActiveObject::GoannaActiveObject(u16 id, u8 type) : m_id(id), m_type(type) {}

// GenericCAO::processInitData, transplanted.
void GoannaActiveObject::initialize(const std::string &data, LocalPlayer *local_player) {
	std::istringstream is(data, std::ios::binary);
	const u8 version = readU8(is);
	if (version < 1) {
		errorstream << "goanna: unsupported active object init data version" << std::endl;
		return;
	}
	m_name = deSerializeString16(is);
	m_is_player = readU8(is);
	m_id = readU16(is);
	m_position = readV3F32(is);
	m_rotation = readV3F32(is);
	m_hp = readU16(is);
	if (m_is_player && local_player && local_player->getName() == m_name) {
		m_is_local_player = true;
		m_is_visible = false;
	}
	const u8 num_messages = readU8(is);
	for (u8 i = 0; i < num_messages; i++) {
		std::string message = deSerializeString32(is);
		processMessage(message, local_player);
	}
	m_rotation = wrapDegrees_0_360_v3f(m_rotation);
	m_pos_translator.init(m_position);
	m_rot_translator.init(m_rotation);
}

void GoannaActiveObject::setAttachment(u16 parent_id, const std::string &bone, v3f position,
		v3f rotation, bool force_visible) {
	m_attachment_parent_id = parent_id;
	m_attachment_bone = bone;
	m_attachment_position = position;
	m_attachment_rotation = rotation;
	m_force_visible = force_visible;
	m_visual_version++;
}

// GenericCAO::processMessage, transplanted. Scene updates become version bumps.
void GoannaActiveObject::processMessage(const std::string &data, LocalPlayer *local_player) {
	std::istringstream is(data, std::ios::binary);
	u8 cmd = readU8(is);
	if (cmd == AO_CMD_SET_PROPERTIES) {
		ObjectProperties newprops;
		newprops.show_on_minimap = m_is_player;
		newprops.deSerialize(is);
		m_prop = std::move(newprops);
		m_selection_box = m_prop.selectionbox;
		m_selection_box.MinEdge *= BS;
		m_selection_box.MaxEdge *= BS;
		if (!m_initial_tx_basepos_set) {
			m_initial_tx_basepos_set = true;
			m_tx_basepos = m_prop.initial_sprite_basepos;
		}
		if (m_is_local_player && local_player) {
			local_player->makes_footstep_sound = m_prop.makes_footstep_sound;
			aabb3f collision_box = m_prop.collisionbox;
			collision_box.MinEdge *= BS;
			collision_box.MaxEdge *= BS;
			local_player->setCollisionbox(collision_box);
			local_player->setEyeHeight(m_prop.eye_height);
			local_player->setZoomFOV(m_prop.zoom_fov);
		}
		if ((m_is_player && !m_is_local_player) && m_prop.nametag.empty())
			m_prop.nametag = m_name;
		if (m_is_local_player)
			m_prop.show_on_minimap = false;
		m_visual_version++;
	} else if (cmd == AO_CMD_UPDATE_POSITION) {
		m_position = readV3F32(is);
		m_velocity = readV3F32(is);
		m_acceleration = readV3F32(is);
		m_rotation = readV3F32(is);
		m_rotation = wrapDegrees_0_360_v3f(m_rotation);
		bool do_interpolate = readU8(is);
		bool is_end_position = readU8(is);
		float update_interval = readF32(is);
		if (m_attachment_parent_id != 0)
			return;
		if (do_interpolate) {
			if (!m_prop.physical)
				m_pos_translator.update(m_position, is_end_position, update_interval);
		} else {
			m_pos_translator.init(m_position);
		}
		m_rot_translator.update(m_rotation, false, update_interval);
	} else if (cmd == AO_CMD_SET_TEXTURE_MOD) {
		m_current_texture_modifier = deSerializeString16(is);
		m_visual_version++;
	} else if (cmd == AO_CMD_SET_SPRITE) {
		v2s16 p = readV2S16(is);
		int num_frames = readU16(is);
		float framelength = readF32(is);
		bool select_horiz_by_yawpitch = readU8(is);
		m_tx_basepos = p;
		m_anim_num_frames = num_frames;
		m_anim_framelength = framelength;
		m_tx_select_horiz_by_yawpitch = select_horiz_by_yawpitch;
		m_visual_version++;
	} else if (cmd == AO_CMD_SET_PHYSICS_OVERRIDE) {
		PlayerPhysicsOverride phys;
		phys.speed = readF32(is);
		phys.jump = readF32(is);
		phys.gravity = readF32(is);
		phys.sneak = !readU8(is);
		phys.sneak_glitch = !readU8(is);
		phys.new_move = !readU8(is);
		if (canRead(is)) {
			phys.speed_climb = readF32(is);
			phys.speed_crouch = readF32(is);
			phys.liquid_fluidity = readF32(is);
			phys.liquid_fluidity_smooth = readF32(is);
			phys.liquid_sink = readF32(is);
			phys.acceleration_default = readF32(is);
			phys.acceleration_air = readF32(is);
		}
		if (canRead(is)) {
			phys.speed_fast = readF32(is);
			phys.acceleration_fast = readF32(is);
			phys.speed_walk = readF32(is);
		}
		if (m_is_local_player && local_player)
			local_player->physics_override = phys;
	} else if (cmd == AO_CMD_SET_ANIMATION) {
		// Read animation
		scene::TrackAnimSpec anim;
		v2f range = readV2F32(is);
		anim.fps = readF32(is);
		anim.blend_duration = readF32(is);
		// these are sent inverted so we get true when the server sends nothing
		anim.loop = !readU8(is);

		scene::TrackId track_id = (u16) 0;
		std::optional<f32> cur_frame;
		if (canRead(is)) {
			// New animation API since 5.17.0
			track_id = readTrackIdentifier(is);
			anim.priority = readS32(is);
			cur_frame = std::max(0.0f, readF32(is));
		}

		anim.setFrameRange(range.X, range.Y);
		anim.cur_frame = cur_frame.value_or(anim.fps >= 0 ? anim.min_frame : anim.max_frame);

		// Also clamps cur_frame & max_frame to the track max frame number in the mesh
		// Goanna: queued for the renderer, which has the mesh
		deferAnimationCmd({DeferredAnimationCmd::SET, std::move(track_id), anim});
		m_anim_version++;
	} else if (cmd == AO_CMD_SET_ANIMATION_SPEED) {
		// Note: Init message list never contains this command, so it need not apply to deferred animations
		f32 new_fps = readF32(is);
		scene::TrackId track_id = (u16) 0;
		if (canRead(is)) {
			// New animation API since 5.17.0
			track_id = readTrackIdentifier(is);
		}

		// Goanna: queued as well, since the renderer may not have drawn this
		// object yet; the rest of this handler is applyAnimationSpeed
		scene::TrackAnimSpec speed;
		speed.fps = new_fps;
		deferAnimationCmd({DeferredAnimationCmd::SPEED, std::move(track_id), speed});
		m_anim_version++;
	} else if (cmd == AO_CMD_STOP_ANIMATION) {
		// New animation API since 5.17.0
		auto track_id = readTrackIdentifier(is);

		// Goanna: queued; the rest of this handler is stopTrackAnimation
		deferAnimationCmd({DeferredAnimationCmd::STOP, std::move(track_id), {}});
		m_anim_version++;
	} else if (cmd == AO_CMD_SET_BONE_POSITION) {
		std::string bone = deSerializeString16(is);
		auto it = m_bone_override.find(bone);
		BoneOverride props;
		if (it != m_bone_override.end()) {
			props = it->second;
			props.dtime_passed = 0;
			props.position.previous = props.position.vector;
			props.rotation.previous = props.rotation.next;
			props.scale.previous = props.scale.vector;
		} else {
			props.position.interp_duration = 0.0f;
			props.rotation.interp_duration = 0.0f;
			props.scale.interp_duration = 0.0f;
		}
		props.position.vector = readV3F32(is);
		props.rotation.next = core::quaternion(readV3F32(is) * core::DEGTORAD);
		if (!canRead(is)) {
			props.position.absolute = true;
			props.rotation.absolute = true;
		} else {
			props.scale.vector = readV3F32(is);
			props.position.interp_duration = readF32(is);
			props.rotation.interp_duration = readF32(is);
			props.scale.interp_duration = readF32(is);
			u8 absoluteFlag = readU8(is);
			props.position.absolute = (absoluteFlag & 1) > 0;
			props.rotation.absolute = (absoluteFlag & 2) > 0;
			props.scale.absolute = (absoluteFlag & 4) > 0;
		}
		m_bone_override[bone] = props;
		m_anim_version++;
	} else if (cmd == AO_CMD_ATTACH_TO) {
		u16 parent_id = readS16(is);
		std::string bone = deSerializeString16(is);
		v3f position = readV3F32(is);
		v3f rotation = readV3F32(is);
		bool force_visible = false;
		if (canRead(is))
			force_visible = readU8(is);
		setAttachment(parent_id, bone, position, rotation, force_visible);
	} else if (cmd == AO_CMD_PUNCHED) {
		u16 result_hp = readU16(is);
		m_hp = result_hp;
		if (m_is_local_player && local_player)
			local_player->hp = m_hp;
		if (m_hp == 0) {
			m_attachment_parent_id = 0;
			if (!m_is_player)
				m_attachment_child_ids.clear();
			m_visual_version++;
		}
	} else if (cmd == AO_CMD_UPDATE_ARMOR_GROUPS) {
		m_armor_groups.clear();
		int armor_groups_size = readU16(is);
		for (int i = 0; i < armor_groups_size; i++) {
			std::string name = deSerializeString16(is);
			int rating = readS16(is);
			m_armor_groups[name] = rating;
		}
	} else if (cmd == AO_CMD_SPAWN_INFANT) {
		u16 child_id = readU16(is);
		u8 type = readU8(is);
		(void)type;
		m_attachment_child_ids.insert(child_id);
	} else if (cmd == AO_CMD_OBSOLETE1) {
		// nothing
	} else {
		warningstream << "goanna: unknown active object command " << (int)cmd << std::endl;
	}
}

// ---- animation tracks: from luanti/src/client/content_cao.cpp ----

// Goanna: the renderer applies the queue each frame it draws the object, so it
// stays a few commands long and replays exactly what arrived. An object it
// does not draw never has its queue applied, so past this length a set or a
// stop drops the queued commands on the same track id, and a speed change the
// queued speed changes, none of which can affect the result any more.
static constexpr size_t MAX_DEFERRED_ANIMATION_CMDS = 64;

void GoannaActiveObject::deferAnimationCmd(DeferredAnimationCmd &&cmd)
{
	auto &cmds = deferred_animation_cmds;
	if (cmds.size() >= MAX_DEFERRED_ANIMATION_CMDS) {
		cmds.erase(std::remove_if(cmds.begin(), cmds.end(),
				[&](const DeferredAnimationCmd &queued) {
					return queued.track_id == cmd.track_id &&
							(cmd.kind != DeferredAnimationCmd::SPEED ||
							queued.kind == DeferredAnimationCmd::SPEED);
				}), cmds.end());
	}
	cmds.push_back(std::move(cmd));
}

// Goanna: the commands processMessage queued, in the order they arrived.
// Before the first setAnimatedMesh they wait, as upstream's
// deferred_set_animation_cmds wait for addToScene.
void GoannaActiveObject::applyDeferredAnimation(LocalPlayer *local_player)
{
	if (!m_added_to_scene)
		return;
	std::vector<DeferredAnimationCmd> cmds;
	cmds.swap(deferred_animation_cmds);
	for (auto &cmd : cmds) {
		switch (cmd.kind) {
		case DeferredAnimationCmd::SET:
			applyTrackAnimation(std::move(cmd.track_id), cmd.anim, local_player);
			break;
		case DeferredAnimationCmd::SPEED:
			applyAnimationSpeed(cmd.track_id, cmd.anim.fps);
			break;
		case DeferredAnimationCmd::STOP:
			stopTrackAnimation(cmd.track_id);
			break;
		}
	}
}

// Goanna: the animation half of GenericCAO::addToScene and of the visual
// expiry in GenericCAO::step. A rebuild with the same mesh is not an expiry.
void GoannaActiveObject::setAnimatedMesh(scene::IAnimatedMesh *mesh)
{
	if (m_added_to_scene &&
			(m_animated_meshnode ? m_animated_meshnode->getMesh() : nullptr) == mesh)
		return;

	if (m_animated_meshnode) {
		// Preserve current frames of playing animations
		// TODO might want to preserve bone transformation matrices in the future
		const auto &anim = m_animated_meshnode->getAnimation();
		for (const auto &[track_nr, track] : anim.tracks) {
			m_animation.tracks[track_nr].cur_frame = track.cur_frame;
		}
	}

	// removeFromScene(false); addToScene(...)
	m_animated_meshnode.reset();
	if (mesh)
		m_animated_meshnode = std::make_unique<AnimatedMeshNodeStandIn>(mesh);
	m_added_to_scene = true;

	if (m_animated_meshnode && m_animated_meshnode->getMesh()) {
		for (auto it = m_animation.tracks.begin(); it != m_animation.tracks.end();) {
			const auto track_nr = it->first;
			if (track_nr < m_animated_meshnode->getMesh()->getTrackCount()) {
				it->second.clamp(m_animated_meshnode->getMesh()->getMaxFrameNumber(track_nr));
				++it;
			} else {
				it = m_animation.tracks.erase(it);
			}
		}
		m_animated_meshnode->getAnimation() = m_animation; // Restore animation
	}
}

void GoannaActiveObject::updateAnimation(u16 track_nr)
{
	if (!m_animated_meshnode)
		return;

	if (m_local_player_animation) {
		// Reset local player animation override
		m_local_player_animation = false;
		m_animated_meshnode->getAnimation() = m_animation;
		return;
	}

	m_animated_meshnode->getAnimation().tracks[track_nr] = m_animation.tracks[track_nr];
}

std::optional<u16> GoannaActiveObject::resolveTrackId(const scene::TrackId &track_id, bool lax)
{
	if (!m_animated_meshnode)
		return std::nullopt;

	const auto *mesh = m_animated_meshnode->getMesh();

	if (const auto *track_name = std::get_if<std::string>(&track_id)) {
		if (const std::optional<u16> opt = mesh->getTrackNumber(*track_name))
			return *opt;
		warningstream << "Track name " << track_name << " not found in mesh " << m_prop.mesh << std::endl;
		return std::nullopt;
	}

	u16 track_nr = std::get<u16>(track_id);
	u16 max_track_nr = mesh->getTrackCount();
	if (track_nr >= max_track_nr) {
		if (!lax) {
			if (track_nr == 0) {
				warningstream << "Tried to change animation of mesh " << m_prop.mesh
					<< ", but mesh has no predefined animations" << std::endl;
			} else {
				// 1-indexed track number for consistency with Lua API
				warningstream << "Track number " << (track_nr + 1) << " out of bounds for mesh "
					<< m_prop.mesh << " (max: " << max_track_nr << ")" << std::endl;
			}
		}
		return std::nullopt;
	}

	return track_nr;
}

void GoannaActiveObject::applyTrackAnimation(scene::TrackId &&track_id, scene::TrackAnimSpec anim,
		LocalPlayer *local_player)
{
	// Goanna: reached only through applyDeferredAnimation, once the renderer
	// has added the object to the scene; the deferral upstream does here
	// while m_smgr is unset is processMessage's queue.

	// HACK pre-5.17.0 servers send such animations unconditionally for objects at init,
	// including static objects
	const bool lax = anim.min_frame == 0.0f && anim.max_frame == 0.0f &&
			track_id == scene::TrackId((u16) 0);
	const auto track_nr = resolveTrackId(track_id, lax);
	if (!track_nr)
		return;

	if (m_animated_meshnode) {
		anim.clamp(m_animated_meshnode->getMesh()->getMaxFrameNumber(*track_nr));
	}

	// Update stored animation in either case.
	// This becomes relevant if local animations are left unspecified,
	// in which case the stored animation is reapplied.
	m_animation.tracks[*track_nr] = anim;
	if (!m_is_local_player) {
		updateAnimation(*track_nr);
	} else {
		const auto &local_anims = local_player->local_animations;
		bool is_known = track_nr == 0 && std::any_of(local_anims.begin(), local_anims.end(),
				[&](v2f range) {
					return anim.min_frame == range.X && anim.max_frame == range.Y;
				});
		// Apply the animation if it is not a known local animation
		if (!is_known) {
			updateAnimation(*track_nr);
		}
	}
}

// Goanna: the rest of processMessage's AO_CMD_SET_ANIMATION_SPEED handler.
void GoannaActiveObject::applyAnimationSpeed(const scene::TrackId &track_id, f32 new_fps)
{
		auto track_nr_opt = resolveTrackId(track_id);
		if (!track_nr_opt)
			return;
		u16 track_nr = *track_nr_opt;

		auto it = m_animation.tracks.find(track_nr);
		if (it != m_animation.tracks.end()) {
			it->second.fps = new_fps;
			m_animated_meshnode->getAnimation().tracks[track_nr].fps = new_fps;
		}
}

// Goanna: the rest of processMessage's AO_CMD_STOP_ANIMATION handler.
void GoannaActiveObject::stopTrackAnimation(const scene::TrackId &track_id)
{
		auto track_nr_opt = resolveTrackId(track_id);
		if (!track_nr_opt)
			return;
		u16 track_nr = *track_nr_opt;

		auto it = m_animation.tracks.find(track_nr);
		if (it != m_animation.tracks.end()) {
			m_animation.tracks.erase(it);
			m_animated_meshnode->getAnimation().tracks.erase(track_nr);
		}
}

// Motion part of GenericCAO::step, transplanted.
void GoannaActiveObject::step(float dtime, Map *map, IGameDef *gamedef, const GoannaActiveObject *parent) {
	if (m_attachment_parent_id != 0 && parent) {
		// Attachments are glued to their parent; the Godot side places them
		// relative to the parent (bone attachments once skeletons exist).
		m_position = parent->position();
		m_velocity = v3f(0, 0, 0);
		m_acceleration = v3f(0, 0, 0);
		m_pos_translator.val_current = m_position;
		m_pos_translator.val_target = m_position;
		return;
	}
	m_rot_translator.translate(dtime);
	if (m_prop.physical) {
		aabb3f box = m_prop.collisionbox;
		box.MinEdge *= BS;
		box.MaxEdge *= BS;
		v3f p_pos = m_position;
		v3f p_velocity = m_velocity;
		CollisionMoveResult moveresult = collisionMoveSimple(map, gamedef, box, m_prop.stepheight, dtime,
				&p_pos, &p_velocity, m_acceleration, nullptr, m_prop.collideWithObjects, m_prop.step_up_mode);
		m_position = p_pos;
		m_velocity = p_velocity;
		bool is_end_position = moveresult.collides;
		m_pos_translator.update(m_position, is_end_position, dtime);
	} else {
		m_position += dtime * m_velocity + 0.5 * dtime * dtime * m_acceleration;
		m_velocity += dtime * m_acceleration;
		m_pos_translator.update(m_position, m_pos_translator.aim_is_end, m_pos_translator.anim_time);
	}
	m_pos_translator.translate(dtime);
}

} // namespace goanna
