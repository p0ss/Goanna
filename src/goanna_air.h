// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Birds and other fliers in the air, worked out on the client.
//
// The server plays a flier's baked clips (fly, glide, take_off, land, swoop)
// for every client and moves the object; a stock client shows exactly that.
// Goanna adds what the clips cannot know, from where the body is each frame
// and the server's air state:
//
// - the wingbeat follows speed and climb (the fly clip faster climbing or
//   hovering, slower cruising);
// - the wings bank into turns, from the turn rate;
// - the legs stay tucked in flight and reach for the floor actually below as
//   it comes near, rather than when the land clip's timer says;
// - the talons come forward for a swoop's contact and a strike.
//
// The air state is format 4 of the action state on the stroke state bone
// (goanna_strokes.h, DorfCraft's kit/strokes lib/strike.lua): position.x the
// manoeuvre's parameter, position.y its time when sent, scale.x its serial,
// scale.y the manoeuvre (AirManoeuvre), scale.z 4. One set a manoeuvre; the
// client runs its clock, and a manoeuvre ends when the body says so (on the
// floor after a landing, past contact after a swoop). Another format on the
// bone (a stroke) replaces it.

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace Json {
class Value;
}

namespace goanna {

constexpr int AIR_STATE_FORMAT = 4;

enum class AirManoeuvre {
    None = 0,
    TakeOff = 1, // parameter: the height it climbs to, nodes
    Swoop = 2,   // parameter: seconds from the swoop's start to contact
    Land = 3,    // parameter: the drop to the landing spot, nodes
    Strike = 4,  // the talons strike now
};

// From the model's root extras {"air": {...}}: the state bone, the clips the
// leg poses are taken from, the legs and the wing roots, and the leg's
// length (hip to sole, mesh units).
struct AirPlan {
    std::string state;
    std::string fly = "fly", stand = "idle", talons = "swoop";
    struct Leg {
        std::string upper, lower;
    };
    std::vector<Leg> legs;
    std::vector<std::string> wings; // left, right
    float leg_length = 0.35f;
};
bool parseAirPlan(const Json::Value &v, AirPlan &out);

// One frame of a flier: where its origin is (nodes, Luanti axes), its yaw
// (radians, Luanti's: counterclockwise seen from above), the floor's height
// below it if the floor is within reach of the probe, its leg's length, and
// the server's air state (None when there is none).
struct AirInput {
    float dt = 0.0f;
    float x = 0.0f, y = 0.0f, z = 0.0f;
    float yaw = 0.0f;
    std::optional<float> floor;
    float leg = 0.35f; // the leg's length at this body's scale, nodes
    int serial = -1;
    AirManoeuvre manoeuvre = AirManoeuvre::None;
    float since = 0.0f; // seconds since the manoeuvre's state was sent
    float param = 0.0f;
};

// What to add to the clip's pose this frame.
struct AirOutput {
    bool flying = false;
    float beat_rate = 1.0f; // the fly clip's playback rate
    float bank = 0.0f;      // radians; positive: the left wing down
    float reach = 0.0f;     // legs: 0 tucked, 1 standing (reaching down)
    float talons = 0.0f;    // 0 none, 1 fully forward
    float weight = 0.0f;    // how much of the leg pose replaces the clip's
};

class AirMotion {
public:
    AirOutput step(const AirInput &in);
    // The velocity it worked out (nodes a second) and the turn rate
    // (radians a second, positive turning left), both eased.
    float vx() const { return m_vx; }
    float vy() const { return m_vy; }
    float vz() const { return m_vz; }
    float turnRate() const { return m_turn; }

private:
    bool m_have = false, m_moving = false;
    float m_px = 0, m_py = 0, m_pz = 0, m_pyaw = 0;
    float m_vx = 0, m_vy = 0, m_vz = 0, m_turn = 0;
    float m_bank = 0, m_reach = 1, m_talons = 0, m_weight = 0, m_rate = 1;
};

} // namespace goanna
