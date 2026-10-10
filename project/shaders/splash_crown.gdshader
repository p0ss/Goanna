// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// The crown a body or a blow throws up going into the water
// (project/ui/splashes.gd, docs/systems/weather.md "Splashes"): a thin sheet of
// water standing up in a ring round where it went in, flaring outward as it
// rises, its lip drawn up into fingers that break apart, then falling back.
// Taller on the side the body or the blow was going, which is where real
// water is thrown.
//
// The mesh is a plain ring of quads (UV.x round it, UV.y from the foot of
// the sheet to its lip); everything else is here, driven by one number, the
// crown's age, so a crown costs a material instance and no CPU per vertex.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, specular_schlick_ggx;

// 0 when it is thrown, 1 when it is gone.
instance uniform float crown_age = 0.0;
// x the radius of its foot, fully spread, nodes; y its height at most.
instance uniform vec2 crown_size = vec2(0.6, 0.8);
// xy the way it was pushed (world xz, unit or zero), z how hard (0 to 1),
// w a seed so no two crowns have the same fingers.
instance uniform vec4 crown_push = vec4(0.0);

uniform vec4 colour : source_color = vec4(0.84, 0.92, 1.0, 1.0);
// How many fingers round the lip.
const float FINGERS = 18.0;

varying float lip;
varying float finger;

// How far a finger stands up at this angle: narrow peaks, uneven in height
// and spacing.
float fingers_at(float a, float seed) {
	float wobble = 1.6 * sin(a * 3.0 + seed * 11.0) + 0.9 * sin(a * 5.0 + seed * 23.0);
	float f = 0.5 + 0.5 * cos(a * FINGERS + seed * 6.28 + wobble);
	// Rounded at the top, the way a finger of water ends in a bead.
	float peak = pow(f, 5.0);
	return sqrt(peak) * peak * (0.55 + 0.45 * sin(a * 7.0 + seed * 31.0));
}

void vertex() {
	float a = UV.x * TAU;
	float v = UV.y;
	vec2 around = vec2(cos(a), sin(a));
	float t = clamp(crown_age, 0.0, 1.0);
	// Up fast and slowing, then back down.
	float rise = sin(PI * pow(t, 0.55));
	float push = dot(around, crown_push.xy) * crown_push.z;
	float tall = crown_size.y * rise * clamp(1.0 + 0.9 * push, 0.25, 2.0);
	finger = fingers_at(a, crown_push.w);
	// The fingers grow out of the lip as it rises, and keep going up a
	// little after the sheet below them has stopped.
	float h = v * tall + smoothstep(0.7, 1.0, v) * finger * tall * 0.45 * smoothstep(0.1, 0.5, t);
	// The foot spreads quickly; the sheet stands up from it and flares out
	// towards the lip, a tulip rather than a cone, leaning out further as
	// it falls; and the whole crown is thrown forward of where it went in.
	float foot = crown_size.x * mix(0.55, 1.0, pow(t, 0.35));
	float r = foot + h * mix(0.12, 0.5, t) + tall * mix(0.3, 0.5, t) * v * v;
	vec2 at = around * r + crown_push.xy * crown_push.z * crown_size.x * 0.25;
	// The foot starts a little under the water, so no seam shows.
	VERTEX = vec3(at.x, h - 0.05, at.y);
	NORMAL = normalize(vec3(around.x, -0.35, around.y));
	lip = v;
}

void fragment() {
	float t = clamp(crown_age, 0.0, 1.0);
	// Clear where it leaves the water, a thin streaky film up the sheet,
	// and a thick bright rim at the lip, beaded at the tips of the fingers,
	// where the water gathers before it breaks off.
	float a = UV.x * TAU;
	float streaks = 0.65 + 0.35 * sin(a * 41.0 + sin(a * 13.0) * 2.0 + lip * 2.5);
	float rim = smoothstep(0.82, 0.97, lip);
	float bead = smoothstep(0.45, 0.8, finger) * smoothstep(0.9, 1.0, lip);
	float alpha = smoothstep(0.0, 0.3, lip) * mix(0.16 * streaks, 0.85, rim);
	alpha = max(alpha, bead);
	// Late in its life the lip between the fingers goes, leaving them
	// standing, and then the whole sheet thins away.
	float gone = smoothstep(0.25, 0.75, t) * smoothstep(0.55, 1.0, lip)
			* (1.0 - smoothstep(0.15, 0.5, finger));
	alpha *= 1.0 - gone;
	alpha *= 1.0 - smoothstep(0.6, 1.0, t);
	// Edge on, a film of water is brighter.
	float edge = 1.0 - abs(dot(NORMAL, VIEW));
	ALBEDO = colour.rgb * mix(0.75, 1.05, max(rim, bead));
	ALPHA = clamp(alpha * mix(0.75, 1.15, edge), 0.0, 1.0);
	ROUGHNESS = 0.1;
	SPECULAR = 0.8;
}
