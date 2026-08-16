// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
// Copyright (C) 2020 numzero, Lobachevskiy Vitaliy <numzer0@yandex.ru>
//
// Sun and moon path and the day/night ratio, in Goanna terms. The wicked
// time of day and sky body position functions are copied from Luanti
// 5.16.1 client/sky.cpp; each is marked at its definition.

#include "goanna_sky.h"

#include <cmath>

#include "daynightratio.h"

namespace goanna {

// Copied from luanti/src/client/sky.cpp (LGPL-2.1-or-later).
float getWickedTimeOfDay(float time_of_day)
{
	float nightlength = 0.415f;
	float wn = nightlength / 2;
	float wicked_time_of_day = 0;
	if (time_of_day > wn && time_of_day < 1.0f - wn)
		wicked_time_of_day = (time_of_day - wn) / (1.0f - wn * 2) * 0.5f + 0.25f;
	else if (time_of_day < 0.5f)
		wicked_time_of_day = time_of_day / wn * 0.25f;
	else
		wicked_time_of_day = 1.0f - ((1.0f - time_of_day) / wn * 0.25f);
	return wicked_time_of_day;
}

// Copied from luanti/src/client/sky.cpp (getSkyBodyPosition).
static v3f skyBodyPosition(float horizon_position, float day_position, float orbit_tilt)
{
	v3f result = v3f(0, 0, -1);
	result.rotateXZBy(horizon_position);
	result.rotateXYBy(day_position);
	result.rotateYZBy(orbit_tilt);
	return result;
}

v3f sunDirection(float time_of_day, float orbit_tilt) {
	if (orbit_tilt == SkyboxParams::INVALID_SKYBOX_TILT)
		orbit_tilt = 0.0f;
	return skyBodyPosition(90, getWickedTimeOfDay(time_of_day) * 360 - 90, orbit_tilt);
}

v3f moonDirection(float time_of_day, float orbit_tilt) {
	if (orbit_tilt == SkyboxParams::INVALID_SKYBOX_TILT)
		orbit_tilt = 0.0f;
	return skyBodyPosition(270, getWickedTimeOfDay(time_of_day) * 360 - 90, orbit_tilt);
}

u32 dayNightRatio(float time_of_day) {
	return time_to_daynight_ratio(time_of_day * 24000.0f, true);
}

} // namespace goanna
