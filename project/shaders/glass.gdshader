// Goanna: alpha-blended non-liquid nodes (glass, ice, stained glass): TILE_MATERIAL_ALPHA.
//
// Reflection is the same two-rung sky answer as water.gdshader, plus the
// same screen space march for what the sky answer cannot give (the bank and
// its trees on a frozen lake): where the reflected direction's sky is on
// screen, the frame's own sky pixels are sampled by direction; where it is
// not, the sky gradient plus a drawn sun disc and halo stands in.
//
// What keeps this from reading as chrome is that the surface's own maps
// drive it. The baked pack's _n companion bends the normal (falling back to
// a luminance bump when no pack covers the tile), and the _s companion's
// smoothness decides per texel how much reflection there is at all, so a
// sheet of ice is patches of frost that barely reflect around slicks that
// do, under a hard overall cap: ice is a scattering solid, not standing
// water, and the texture must stay the majority of what you see.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
// LabPBR companions, the entity path's conventions (entity.gdshader): _n
// carries the tangent normal in RG (no green flip, V runs down on both
// sides), _s carries perceptual smoothness in R and F0 in G.
uniform sampler2D normal_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D spec_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform bool has_spec = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float refraction = 0.015;
uniform float roughness = 0.08;
// How hard the texture's own relief bends the surface normal when there is
// no authored _n: the tile's luminance stands in as a height field, one
// texel per facet, deliberately blocky.
uniform float bump_strength = 0.55;
// Ceiling on the reflected share. Fresnel and the smoothness map shape
// where the sheen falls, but they can never take more than this from the
// texture; without the cap a frozen lake at mid distance was nine tenths
// mirror, and the far mips average any normal detail away exactly where
// the mirror was at its cleanest.
uniform float reflect_strength : hint_range(0.0, 1.0) = 0.22;
// The march stops past this distance and the sky answer stands alone, as
// in water.gdshader.
uniform float reflect_range : hint_range(0.0, 4096.0) = 512.0;

// The same globals water.gdshader reflects with, set in _apply_sky; the
// glow is zero at night and when a weather sky hides the disc.
global uniform float goanna_eye_underwater;
global uniform vec3 goanna_sky_top;
global uniform vec3 goanna_sky_horizon;
global uniform vec3 goanna_sun_dir;
global uniform vec3 goanna_sun_glow;

// View-space distance of the opaque geometry at this screen uv, as in
// water.gdshader.
float scene_distance(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -(v.z / v.w);
}

// The UV-to-surface frame, recovered from screen space derivatives because
// the node meshes carry no tangents: the standard tangentless bump mapping.
bool uv_frame(vec3 p, vec2 uv, out vec3 t_u, out vec3 t_v) {
	vec2 duvdx = dFdx(uv), duvdy = dFdy(uv);
	float det = duvdx.x * duvdy.y - duvdx.y * duvdy.x;
	if (abs(det) < 1e-12)
		return false;
	vec3 dpdx = dFdx(p), dpdy = dFdy(p);
	t_u = (dpdx * duvdy.y - dpdy * duvdx.y) / det;
	t_v = (dpdy * duvdx.x - dpdx * duvdy.x) / det;
	return length(t_u) > 1e-6 && length(t_v) > 1e-6;
}

// The shading normal: the authored _n where the pack has one, otherwise
// luminance as height, one texel of central difference each way.
vec3 surface_normal(vec3 n, vec3 p, vec2 uv) {
	vec3 t_u, t_v;
	if (!uv_frame(p, uv, t_u, t_v))
		return n;
	if (has_normal) {
		vec2 xy = (texture(normal_tex, uv).rg * 2.0 - 1.0) * normal_strength;
		float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
		return normalize(normalize(t_u) * xy.x + normalize(t_v) * xy.y + n * z);
	}
	if (bump_strength < 0.001)
		return n;
	vec2 texel = 1.0 / vec2(textureSize(albedo_tex, 0));
	vec3 lum = vec3(0.2126, 0.7152, 0.0722);
	float h = dot(texture(albedo_tex, uv).rgb, lum);
	float hu = dot(texture(albedo_tex, uv + vec2(texel.x, 0.0)).rgb, lum);
	float hv = dot(texture(albedo_tex, uv + vec2(0.0, texel.y)).rgb, lum);
	return normalize(n - bump_strength
			* ((hu - h) * normalize(t_u) + (hv - h) * normalize(t_v)));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV) * COLOR;
	vec3 nrm = surface_normal(NORMAL, VERTEX, UV);
	NORMAL = nrm;
	vec2 ofs = nrm.xy * refraction;
	vec3 behind = texture(screen_tex, SCREEN_UV + ofs).rgb;
	vec3 body = mix(behind, tex.rgb, tex.a);
	float here = -VERTEX.z;

	// Face on you see through it, grazing you see the world reflected.
	// Schlick, with glass's real normal-incidence reflectance.
	float fres = pow(1.0 - clamp(dot(nrm, VIEW), 0.0, 1.0), 5.0);
	float refl_amount = clamp(0.04 + 0.96 * fres, 0.0, 1.0);
	// Where the surface reflects at all. A sharp image of the sky needs a
	// microfacet field well past merely polished, so the ramp is steep: the
	// bake's frost sits near 0.75 smoothness and keeps almost nothing, its
	// slicks near 0.95 keep the full (capped) share. Without an _s the
	// whole tile counts as slick and the cap alone holds the line.
	float sm = has_spec ? texture(spec_tex, UV).r : 1.0;
	float slick = smoothstep(0.6, 0.95, sm);
	float refl_mix = 0.0;

	vec3 reflected = vec3(0.0);
	if (goanna_eye_underwater < 0.5 && refl_amount > 0.03) {
		refl_mix = refl_amount * reflect_strength * slick;
		vec3 dir = reflect(normalize(VERTEX), nrm);
		vec3 world_dir = normalize((INV_VIEW_MATRIX * vec4(dir, 0.0)).xyz);
		float up = clamp(world_dir.y, 0.0, 1.0);
		reflected = mix(goanna_sky_horizon, goanna_sky_top, pow(up, 0.45));
		float sun_d = max(dot(world_dir, goanna_sun_dir), 0.0);
		reflected += goanna_sun_glow
				* (pow(sun_d, 1500.0) * 3.0 + pow(sun_d, 350.0) * 0.8);
		// The frame's own sky, sampled by direction: see water.gdshader for
		// why one matrix multiply is enough and why only depth-confirmed sky
		// pixels are trusted.
		if (dir.z < 0.0) {
			vec4 sclip = PROJECTION_MATRIX * vec4(dir, 1.0);
			vec2 suv = (sclip.xy / sclip.w) * 0.5 + 0.5;
			if (suv == clamp(suv, vec2(0.0), vec2(1.0))
					&& texture(depth_tex, suv).r < 1e-6) {
				vec2 sfade = smoothstep(vec2(0.0), vec2(0.08), suv)
						* (1.0 - smoothstep(vec2(0.92), vec2(1.0), suv));
				reflected = mix(reflected, texture(screen_tex, suv).rgb,
						sfade.x * sfade.y);
			}
		}
		// The world in the ice: the same growing-step march water runs, so
		// a bank and its trees lie on a frozen lake the way they do on open
		// water, faded out over reflect_range where the sky answer is all a
		// hit would say anyway. Skipped where frost has already taken the
		// reflection: no point marching for a share nobody will see.
		float march_keep = 1.0 - smoothstep(reflect_range * 0.7, reflect_range, here);
		if (refl_mix > 0.02 && march_keep > 0.001) {
			float step_len = 0.3;
			vec3 p = VERTEX;
			for (int i = 0; i < 24; i++) {
				p += dir * step_len;
				step_len *= 1.32;
				vec4 clip = PROJECTION_MATRIX * vec4(p, 1.0);
				if (clip.w <= 0.0)
					break;
				vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
				if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
					break;
				float scene = scene_distance(uv, INV_PROJECTION_MATRIX);
				float ray = -p.z;
				if (ray > scene && ray - scene < step_len * 4.0) {
					vec2 fade2 = smoothstep(vec2(0.0), vec2(0.1), uv)
							* (1.0 - smoothstep(vec2(0.9), vec2(1.0), uv));
					reflected = mix(reflected, texture(screen_tex, uv).rgb,
							fade2.x * fade2.y * march_keep);
					break;
				}
			}
		}
	}

	// The reflected share comes out of the body, and reflected light is
	// light that never entered the glass, so it rides as emission and is not
	// shaded a second time; both as in water.gdshader. The alpha share rises
	// with the reflection, or blending would throw most of a grazing
	// mirror away with the transparency.
	ALBEDO = body * (1.0 - refl_mix);
	EMISSION = reflected * refl_mix;
	ALPHA = clamp(tex.a + 0.2 + 0.6 * refl_mix, 0.0, 1.0);
	// The _s answers for the light pass too: frost scatters the sun where a
	// slick keeps its highlight tight.
	ROUGHNESS = has_spec ? clamp((1.0 - sm) * (1.0 - sm), 0.04, 1.0) : roughness;
	SPECULAR = has_spec ? clamp(texture(spec_tex, UV).g / 0.08, 0.0, 1.0) : 0.6;
}
