// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// A small patch of water that moves: the height of the surface round the
// eye, stepped as a damped wave equation, pushed by the bodies moving
// through it. docs/systems/weather.md, "Ripples", has the whole picture.
//
// The point rings in wake.gd (and wake.gdshaderinc) drew each disturbance
// as one ring on its own, so a swimmer read as a string of pings and
// nothing came ahead of it. Here the water keeps what was done to it: a
// body is a patch of pressure on the surface, and moving it pushes a crest
// up ahead and sheds waves behind, faster than they spread, so they lie in
// a V along its path, curving where it turns. Waves meet, add, reflect off
// the banks and settle.
//
// Presentation only: the bodies are positions the client already draws.
// RippleField is plain C++ with no Godot in it, for goanna_ripples_test;
// GoannaRipples wraps it for GDScript and uploads the heights as a texture.
#pragma once

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace goanna {

// One body on the water for a step: where it is now, how fast it is going
// (nodes a second, both in the field's x and z), and what it does to the
// surface over its radius, in nodes. It does two things. It presses down
// (`press`, an acceleration), which on its own gives a dimple under a body
// standing still, and rings when the press varies. And
// as it moves it shoves aside the water it displaces (`displace`, the
// depth of water it pushes, in nodes), raising it ahead and lowering it
// behind; that is what stands a crest up in front of a body, which a
// press alone cannot do once the body outruns its own waves. Going deeper
// into the water (`sinking`, how fast its submerged depth grows, nodes a
// second; negative rising out) it pushes the water it now displaces out
// from under itself into a ring round it, `sink` of the depth, and rising
// lets it back; no water is made or lost, so every crest has its trough.
// A body in the air above the water, however fast it moves, does nothing.
struct RippleBody {
    float x = 0.0f, z = 0.0f;
    float vx = 0.0f, vz = 0.0f;
    float sinking = 0.0f;
    float press = 0.0f;
    float displace = 0.0f;
    float sink = 0.0f;
    float radius = 0.3f;
};

class RippleField {
public:
    // Cells a node along each side. Eight puts a wavelength of about a node,
    // which is what a body the size of a player makes, across eight cells.
    static constexpr int kCellsPerNode = 8;
    // How fast waves spread, nodes a second. A walker in the water outruns
    // them, which is what makes the V: its half angle is about
    // asin(speed of the waves / speed of the body).
    static constexpr float kWaveSpeed = 1.2f;
    // A pull back towards the flat surface, per second squared. Without it a
    // body standing still sinks an ever deeper hole; with it the hole is a
    // dimple and the waves are slightly dispersive, long ones outrunning
    // short ones, as water waves are.
    static constexpr float kRestore = 4.0f;
    // How quickly waves die, per second: a crest is at half height about
    // 1.5 seconds later.
    static constexpr float kDamping = 0.9f;
    // A sponge round the edge of the patch soaks up waves that reach it,
    // so they do not bounce back off the edge of the simulation. Nodes wide,
    // and its strongest damping per second.
    static constexpr int kSpongeNodes = 2;
    static constexpr float kSpongeDamping = 12.0f;
    // The fixed step, and the most steps one call will take: a long frame
    // loses time rather than running away.
    static constexpr float kStep = 1.0f / 60.0f;
    static constexpr int kMaxSteps = 6;
    // Below this everywhere, with nothing pressing on it, the water is still
    // and the field sleeps: a twentieth of a millimetre on a metre node,
    // long past showing in the shading.
    static constexpr float kStill = 5e-4f;

    // A swimmer, as wake.gd hands its bodies over: a player at scale 1, an
    // animal smaller. Everything it does to the water comes from how it
    // moves, so a body holding still leaves the water still: the first
    // version pressed down all the time and swayed at a fixed 1.1 Hz, which
    // drew waves unrelated to anything the player did, and whose press,
    // built up over half a second, left the middle of the pattern behind a
    // moving player. The second lifted and lowered the surface with the
    // body's own vertical speed, in the air as much as in the water, and
    // made water to do it: jumping up and down piled up broad mounds with
    // no troughs, which the shader drew as white smoke rings. Tuned on goanna_ripples_test's "seen from the body"
    // table, for slopes the eye picks out from 1.5 to 6 nodes away (the
    // rings' trail was about 0.3) at the speeds a body really moves in
    // water: wading at 1 node a second, swimming at 2 to 3, bobbing.
    static constexpr float kSwimRadius = 0.3f;
    // How much of the water a body sinks into it pushes out into the ring,
    // and the fastest sinking or rising counted, nodes a second: a jump
    // into the water is a splash, not a detonation.
    static constexpr float kSwimSink = 0.3f;
    static constexpr float kSwimMaxSinking = 3.0f;
    // A body's footprint is a disc of its radius whose edge softens over
    // kEdge either side, nodes; the water it pushes out sinking goes into a
    // ring just outside it, kRingWidth wide (a Gaussian's sigma), and comes
    // back from there rising. The shove moving is the footprint's change,
    // times kShoveScale to keep the old Gaussian's strength.
    static constexpr float kEdge = 0.12f;
    static constexpr float kRingShare = 0.5f;
    static constexpr float kRingWidth = 0.15f;
    static constexpr float kShoveScale = 0.3f;
    // The water shoved aside moving. The shove per step grows with speed,
    // so a slow body is given more water to shove, up to kSwimSlowGain
    // times as much at kSwimSlowSpeed and below, or a wader barely marks
    // the water at all.
    static constexpr float kSwimDisplace = 0.15f;
    static constexpr float kSwimFullSpeed = 2.0f;
    static constexpr float kSwimSlowGain = 3.0f;
    static RippleBody swimmer(float x, float z, float vx, float vz, float sinking, float scale);

    explicit RippleField(int nodes = 32);

    int nodes() const { return m_nodes; }
    int cells() const { return m_cells; }
    float cellSize() const { return 1.0f / kCellsPerNode; }
    // Column 0 of the patch is node (originX, originZ), which spans half a
    // node either side of those whole numbers: nodes are centred on them.
    int originX() const { return m_ox; }
    int originZ() const { return m_oz; }
    float cornerX() const { return m_ox - 0.5f; }
    float cornerZ() const { return m_oz - 0.5f; }

    // Moves the patch by whole nodes, keeping the water already on it; the
    // strip that comes into the patch is flat, and counted as water until
    // setWater says otherwise.
    void setOrigin(int ox, int oz);
    // Which nodes of the patch are open water at the surface, one byte a
    // node, x fastest; nonzero is water. Waves stop and reflect at the rest.
    // Empty is water everywhere.
    void setWater(const std::vector<uint8_t> &mask);

    // A splash: water pushed down at (x, z) by `amount`, over `radius`.
    void impulse(float x, float z, float amount, float radius);
    // Advances by `dt` seconds, in fixed steps, with these bodies pressing
    // on the surface. A body's position is where it is at the end of dt; it
    // is walked back along its velocity for the steps before.
    void step(float dt, const std::vector<RippleBody> &bodies);

    bool asleep() const { return m_asleep; }
    // Surface height at a world position, bilinear, 0 off the patch.
    float height(float x, float z) const;
    const std::vector<float> &heights() const { return m_h; }
    // The largest |height| on the patch.
    float peak() const;

private:
    void substep(float h, float t_back, const std::vector<RippleBody> &bodies);
    void press(const RippleBody &b, float x, float z, float amount);
    void shove(const RippleBody &b, float x0, float z0, float x1, float z1);
    void lift(const RippleBody &b, float x, float z, float amount);
    // Visits the cells within reach of (x, z) for a body of radius r, with
    // the Gaussian weight of each.
    template <typename Fn> void around(float x, float z, float r, Fn &&fn);
    // Visits the cells within `reach` of (x, z), with each one's distance.
    template <typename Fn> void edge(float x, float z, float reach, Fn &&fn);
    bool water(int i, int j) const;

    int m_nodes;
    int m_cells;
    int m_ox = 0, m_oz = 0;
    std::vector<float> m_h, m_v;
    std::vector<float> m_sponge;
    std::vector<uint8_t> m_water;   // per node; empty is all water
    float m_carry = 0.0f;
    bool m_asleep = true;
};

// GDScript's handle on a RippleField, and the texture the water shader reads
// its heights from: one float a cell, x along the texture's width.
class GoannaRipples : public godot::RefCounted {
    GDCLASS(GoannaRipples, godot::RefCounted)

public:
    GoannaRipples();

    int get_nodes() const { return m_field.nodes(); }
    int get_cells() const { return m_field.cells(); }
    float get_cell_size() const { return m_field.cellSize(); }
    void set_origin(const godot::Vector2i &origin);
    godot::Vector2i get_origin() const;
    // The world xz of the patch's corner, where texel (0, 0) begins.
    godot::Vector2 get_corner() const;
    void set_water(const godot::PackedByteArray &mask);
    void impulse(const godot::Vector2 &pos, float amount, float radius);
    // Six floats a swimmer: x, z, velocity x and z, how fast its submerged
    // depth grows, and scale, 1 a player (RippleField::swimmer).
    void step(float delta, const godot::PackedFloat32Array &bodies);
    bool is_asleep() const { return m_field.asleep(); }
    float height_at(const godot::Vector2 &pos) const;
    float peak() const { return m_field.peak(); }
    godot::Ref<godot::ImageTexture> get_texture();

protected:
    static void _bind_methods();

private:
    void upload();

    RippleField m_field;
    godot::Ref<godot::Image> m_image;
    godot::Ref<godot::ImageTexture> m_texture;
    godot::PackedByteArray m_bytes;
    bool m_dirty = true;
};

} // namespace goanna
