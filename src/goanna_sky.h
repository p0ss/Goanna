// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Sky, sun/moon/stars, clouds, fog and lighting state as sent by the server
// (TOCLIENT_SET_SKY/SET_SUN/SET_MOON/SET_STARS/CLOUD_PARAMS/SET_LIGHTING/
// OVERRIDE_DAY_NIGHT_RATIO/TIME_OF_DAY), decoded with Luanti's own structs.
// Goanna maps this onto Godot's Environment; nothing here renders.
//
// Threads: the session thread writes its SkyState as the packets arrive,
// under GoannaSession's m_sky_mutex, and the main thread reads a copy taken
// under the same lock (GoannaSession::skyState), which GoannaClient::sky_state
// hands to main.gd. The functions below are pure. Main types: SkyState.

#include "irrlichttypes_bloated.h"
#include "lighting.h"
#include "skyparams.h"

namespace goanna {

// Everything the server has said about the sky, plain values with no
// Godot. Crosses threads only by copy (see the top of this file).
struct SkyState {
    // time of day 0..1 (0.5 = noon), advanced locally by time_speed
    float time_of_day = 0.5f;
    float time_speed = 72.0f;
    bool day_night_override = false;
    float day_night_override_ratio = 1.0f;

    SkyboxParams sky = SkyboxDefaults::getSkyDefaults();
    SunParams sun = SkyboxDefaults::getSunDefaults();
    MoonParams moon = SkyboxDefaults::getMoonDefaults();
    StarParams stars = SkyboxDefaults::getStarDefaults();
    CloudParams clouds = SkyboxDefaults::getCloudDefaults();
    Lighting lighting;
    uint32_t version = 0; // bumped on every change from the server
};

// Copied from luanti/src/client/sky.cpp: maps time of day onto the sky
// body's orbital position (nights are compressed to look shorter).
float getWickedTimeOfDay(float time_of_day);
// Sun direction in Luanti space (unit vector) for a time of day.
v3f sunDirection(float time_of_day, float orbit_tilt);
v3f moonDirection(float time_of_day, float orbit_tilt);
// Day/night light ratio 0..1000 for a time of day (daynightratio.h).
u32 dayNightRatio(float time_of_day);

} // namespace goanna
