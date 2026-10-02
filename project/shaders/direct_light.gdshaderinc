// Goanna: direct light for the node and entity shaders, with the sun and the
// moon gated by the sunlight Luanti says reaches the surface.
//
// Why. The sun and the moon are DirectionalLight3Ds, and their only occluder is
// the shadow map, which holds only what the client has. A server does not send
// blocks the player cannot see (Luanti's server side occlusion culling), so
// from inside a cave the ground overhead is usually not in the client at all,
// and the sun shone straight through it. Measured 2026-09-18 in a Mineclonia
// lava cave at (-216, -48, 161), 211 blocks received: switching the sun off
// removed bright floor patches with hard shadow edges cast from outside the
// cave. The vanilla client cannot have this fault, because its sunlight is the
// day light bank and its shadows only ever darken that. So here every
// directional light's contribution is scaled by the sunlight the mesh carries,
// and a cave with none gets no sun whatever the shadow map says.
//
// Which sunlight. CUSTOM0.g is Luanti's day bank, and the day bank is not sky
// alone: artificial light is written into both banks, so beside lava or a torch
// it is lit however deep underground. Luanti's own encode_light
// (client/mapblock_mesh.cpp) meets the same ambiguity and settles it the same
// way: where the night bank is lit too, the day bank's light is taken to be
// artificial, and only the excess over it is sun. The cost is that a lamp as
// bright as the sky light reaching it takes the sun off the patch it lights,
// which vanilla's shadows do as well.
//
// Why a whole light(). Godot has no hook that scales one light per fragment. A
// light() function is the only way in, and it replaces all of Godot's direct
// lighting, lamps included. So goanna_direct_light below is Godot 4.5.1's
// light_compute (servers/rendering/renderer_rd/shaders/
// scene_forward_lights_inc.glsl) for exactly what these shaders use:
// diffuse_burley, specular_schlick_ggx, BACKLIGHT and RIM, and no clearcoat,
// anisotropy, transmittance or light size, since no Goanna light sets a size.
// For hair texels on entities (GOANNA_HAIR) the specular lobe is replaced by
// Godot's anisotropic GGX, below. One term cannot be copied: the multiscatter energy compensation reads Godot's
// DFG table, which a user shader cannot reach, so it uses Karis' analytic fit,
// which moves direct specular by a few per cent. Moving to another Godot
// release means reading that function again.
//
// What a shader including this must do: write v_sun_gate (goanna_sun_gate of
// its day and night light), v_specular (its final SPECULAR) and v_rim (RIM and
// RIM_TINT, zero for none) in fragment(). RIM and RIM_TINT themselves do
// nothing once a shader has a light(), which is why they travel here.
//
// goanna_direct_light and the helpers it calls are adapted from Godot Engine,
// which is MIT licensed, so its notice travels with them. See THIRD-PARTY.md.
//
// Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
// Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

#include "lamp_occlusion.gdshaderinc"

#ifdef GOANNA_DIAMOND
#include "diamond.gdshaderinc"
#endif

varying float v_sun_gate;
varying float v_specular;
varying vec2 v_rim;

// How far the day bank must stand above the night bank before the sun is let
// in fully. 0.05 lies between Luanti's levels 1 and 2 on the default light
// curve (0.024 and 0.059), and open sky beside a level 14 lamp, the brightest
// artificial light there is, still stands 0.082 above it, so surface sun is
// never dimmed by a torch or by lava.
uniform float sun_gate_width : hint_range(0.001, 0.5) = 0.05;

float goanna_sun_gate(float day, float night) {
	return smoothstep(0.0, sun_gate_width, day - night);
}

float goanna_schlick_fresnel(float u) {
	float m = 1.0 - u;
	float m2 = m * m;
	return m2 * m2 * m;
}

// dfg.y of Godot's table, the directional albedo of the specular lobe with a
// Fresnel of one, from Karis' fit ("Physically Based Shading on Mobile").
float goanna_dfg_y(float roughness, float nv) {
	const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
	const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
	vec4 r = roughness * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
	vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
	return max(ab.x + ab.y, 1e-3);
}

// Godot's light_compute, term for term; see the header.
void goanna_direct_light(vec3 n, vec3 l, vec3 v, vec3 light_color, float attenuation,
		vec3 surface_albedo, float roughness, float metallic, float specular,
		float specular_amount, vec3 backlight, vec2 rim,
		out vec3 diffuse, out vec3 spec) {
	diffuse = vec3(0.0);
	spec = vec3(0.0);
	float ndotl = min(dot(n, l), 1.0);
	float cndotv = max(dot(n, v), 1e-4);
	// Godot applies rim ahead of attenuation, so a shadowed rim still glows.
	if (rim.x > 0.0) {
		float rim_light = pow(max(1e-4, 1.0 - cndotv), max(0.0, (1.0 - roughness) * 16.0));
		diffuse += rim_light * rim.x * mix(vec3(1.0), surface_albedo, rim.y) * light_color;
	}
	float cndotl = max(ndotl, 0.0);
	vec3 h = normalize(v + l);
	float cldoth = clamp(dot(l, h), 0.0, 1.0);
	if (metallic < 1.0) {
		float fd90_minus_1 = 2.0 * cldoth * cldoth * roughness - 0.5;
		float fdv = 1.0 + fd90_minus_1 * goanna_schlick_fresnel(cndotv);
		float fdl = 1.0 + fd90_minus_1 * goanna_schlick_fresnel(cndotl);
		float diffuse_brdf_nl = (1.0 / PI) * fdv * fdl * cndotl;
		diffuse += light_color * diffuse_brdf_nl * attenuation;
		diffuse += light_color * (vec3(1.0 / PI) - diffuse_brdf_nl) * backlight * attenuation;
	}
	if (roughness > 0.0) {
		float cndoth = clamp(dot(n, h), 0.0, 1.0);
		float alpha_ggx = roughness * roughness;
		float a = cndoth * alpha_ggx;
		float k = alpha_ggx / (1.0 - cndoth * cndoth + a * a);
		float d = k * k * (1.0 / PI);
		float g = clamp(0.5 / mix(2.0 * cndotl * cndotv, cndotl + cndotv, alpha_ggx), 0.0, 1.0);
		vec3 f0 = mix(vec3(0.16 * specular * specular), surface_albedo, metallic);
		float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), metallic, 1.0);
		vec3 f = f0 + (f90 - f0) * goanna_schlick_fresnel(cldoth);
		vec3 energy = 1.0 + f0 * (1.0 / goanna_dfg_y(roughness, cndotv) - 1.0);
		spec += energy * cndotl * d * f * g * light_color * attenuation * specular_amount;
	}
}

#ifdef GOANNA_HAIR
// Hair's highlight. A strand is a thin cylinder, so the facets it shows face
// every way round its circumference and almost no way along it: the
// highlight is a narrow band lying across the strands, not a spot. The
// authored maps cannot draw that at a skin's sixteen map pixels per art
// texel, since the band comes from orientations far finer than a texel and
// mipmaps average away what relief there is. So a hair texel (_s green 12,
// set in entity_common.gdshaderinc) swaps the isotropic lobe for Godot's
// anisotropic GGX (D_GGX_anisotropic and V_GGX_anisotropic in
// scene_forward_lights_inc.glsl), rough across the strand and smooth along
// it with the product of the two roughnesses kept, as Godot's ANISOTROPY
// keeps it, so the peak and the energy stay those of the isotropic lobe. A
// second, wider lobe tinted by the albedo, shifted toward the tip where the
// first is shifted toward the root, is the light that entered the strand and
// left by its far wall (Marschner's TRT). The box under the hair has no
// curvature along the strand for the band to travel over, so the strand
// normal is turned along the strand by up to 45 degrees across each face
// (v_hair_strand.w), as if the box were rounded: for the specular only, the
// diffuse keeps the box.
varying float v_hair;
varying vec4 v_hair_strand;
// Hair drawn by the shader (hair_strands.gdshaderinc): x its weight, which
// swaps the diffuse for a wrapped one, y the strand's shine on the
// highlight. Zero on everything else.
varying vec2 v_hair_fx;
// How far round the terminator the hair's wrapped diffuse reaches, as the
// cosine it adds: light passes into and out of a mass of strands, so hair
// has no hard terminator.
uniform float hair_wrap : hint_range(0.0, 1.0) = 0.3;
// Along roughness over across, as alpha_along = alpha * hair_aspect and
// alpha_across = alpha / hair_aspect.
uniform float hair_aspect : hint_range(0.05, 1.0) = 0.35;
// The tinted second lobe's weight, and the two lobes' tilt toward the root
// and the tip in radians.
uniform float hair_secondary : hint_range(0.0, 2.0) = 0.6;
uniform float hair_shift_root : hint_range(0.0, 0.5) = 0.08;
uniform float hair_shift_tip : hint_range(0.0, 0.5) = 0.14;

float goanna_hair_lobe(vec3 n, vec3 t, vec3 l, vec3 v, vec3 h, float at, float ab) {
	vec3 b = cross(n, t);
	float ndotl = dot(n, l);
	float ndotv = max(dot(n, v), 1e-4);
	if (ndotl <= 0.0)
		return 0.0;
	float th = dot(t, h), bh = dot(b, h), nh = max(dot(n, h), 0.0);
	float a2 = at * ab;
	vec3 dv = vec3(ab * th, at * bh, a2 * nh);
	float w2 = a2 / max(dot(dv, dv), 1e-12);
	float d = a2 * w2 * w2 * (1.0 / PI);
	float lv = ndotl * length(vec3(at * dot(t, v), ab * dot(b, v), ndotv));
	float ll = ndotv * length(vec3(at * dot(t, l), ab * dot(b, l), ndotl));
	float g = 0.5 / max(lv + ll, 1e-5);
	return ndotl * d * g;
}

// The specular goanna_direct_light would give, for a hair texel. n is the
// mapped normal, so the strand direction is turned by the map's tilt.
vec3 goanna_hair_specular(vec3 n, vec3 l, vec3 v, vec3 light_color, float attenuation,
		vec3 surface_albedo, float roughness, float specular, float specular_amount) {
	vec3 t = v_hair_strand.xyz - n * dot(n, v_hair_strand.xyz);
	if (dot(t, t) < 1e-8 || dot(n, l) <= 0.0)
		return vec3(0.0);
	t = normalize(t);
	vec3 h = normalize(v + l);
	float alpha = roughness * roughness;
	float at = max(alpha * hair_aspect, 1e-3);
	float ab = min(alpha / hair_aspect, 1.0);
	// The rounding, and the two lobes' tilts on top of it.
	float arc = v_hair_strand.w;
	float r1 = arc - hair_shift_root;
	float r2 = arc + hair_shift_tip;
	vec3 n1 = n * cos(r1) + t * sin(r1), t1 = t * cos(r1) - n * sin(r1);
	vec3 n2 = n * cos(r2) + t * sin(r2), t2 = t * cos(r2) - n * sin(r2);
	float primary = goanna_hair_lobe(n1, t1, l, v, h, at, ab);
	float secondary = goanna_hair_lobe(n2, t2, l, v, h, min(at * 1.6, 1.0), ab);
	// As the isotropic lobe: F0 from SPECULAR, Schlick, the multiscatter term.
	float cldoth = clamp(dot(l, h), 0.0, 1.0);
	float cndotv = max(dot(n, v), 1e-4);
	vec3 f0 = vec3(0.16 * specular * specular);
	float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), 0.0, 1.0);
	vec3 f = f0 + (f90 - f0) * goanna_schlick_fresnel(cldoth);
	vec3 energy = 1.0 + f0 * (1.0 / goanna_dfg_y(roughness, cndotv) - 1.0);
	// The rounded normal may face a light the box does not; the box's own
	// normal still decides whether the light reaches the surface.
	float facing = clamp(dot(n, l) * 8.0, 0.0, 1.0);
	return energy * f * (primary + secondary * hair_secondary * surface_albedo)
			* facing * light_color * attenuation * specular_amount;
}
#endif

void light() {
	vec3 diffuse;
	vec3 spec;
	goanna_direct_light(NORMAL, LIGHT, VIEW, LIGHT_COLOR, ATTENUATION, ALBEDO,
			ROUGHNESS, METALLIC, v_specular, SPECULAR_AMOUNT, BACKLIGHT, v_rim,
			diffuse, spec);
#ifdef GOANNA_HAIR
	if (v_hair > 0.0)
		spec = mix(spec, goanna_hair_specular(NORMAL, LIGHT, VIEW, LIGHT_COLOR, ATTENUATION,
				ALBEDO, ROUGHNESS, v_specular, SPECULAR_AMOUNT), v_hair);
	if (v_hair_fx.x > 0.0) {
		spec *= mix(1.0, v_hair_fx.y, v_hair_fx.x);
		float wrapped = max((dot(NORMAL, LIGHT) + hair_wrap) / (1.0 + hair_wrap), 0.0);
		diffuse = mix(diffuse, LIGHT_COLOR * ATTENUATION * wrapped * (1.0 / PI), v_hair_fx.x);
	}
#endif
	// Only the sun, the moon and the bounce are directional; every lamp is an
	// omni or spot light and keeps its full contribution.
	float gate = LIGHT_IS_DIRECTIONAL ? v_sun_gate : 1.0;
	// The carried light sits at the camera and has no node emitter. Keep it
	// independent, including when a static lamp lies on the same view ray.
	if (!LIGHT_IS_DIRECTIONAL && ATTENUATION > 0.0001 && dot(LIGHT, VIEW) < 0.999999)
		gate *= goanna_lamp_visibility(v_lamp_world,
				normalize((INV_VIEW_MATRIX * vec4(LIGHT, 0.0)).xyz));
	DIFFUSE_LIGHT += diffuse * gate;
	SPECULAR_LIGHT += spec * gate;
#ifdef GOANNA_DIAMOND
	if (v_diamond > 0.001)
		SPECULAR_LIGHT += goanna_diamond_fire(NORMAL, LIGHT, VIEW, v_diamond_axis, v_gem_optics.a)
				* v_diamond * LIGHT_COLOR * ATTENUATION * SPECULAR_AMOUNT * gate;
	if (v_diamond_interior > 0.001) {
		// Light refracted into the crystal catches a different plane from
		// its polished skin. Both layers obey the same shadow and sun gate.
		vec3 inner = goanna_diamond_fire(normalize(v_diamond_inner_normal),
				LIGHT, VIEW, v_diamond_axis, v_gem_optics.a);
		SPECULAR_LIGHT += inner * v_diamond_interior * v_gem_optics.rgb
				* LIGHT_COLOR * ATTENUATION * SPECULAR_AMOUNT * gate;
		float wrapped = clamp((dot(NORMAL, LIGHT) + 0.45) / 1.45, 0.0, 1.0);
		float forward = pow(max(dot(-LIGHT, VIEW), 0.0), 4.0);
		DIFFUSE_LIGHT += v_diamond_scatter * (wrapped * 0.18 + forward * 0.35)
				* LIGHT_COLOR * ATTENUATION * gate / PI;
	}
#endif
}
