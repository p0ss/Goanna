// Goanna: a weather particle kept out from under roofs.
//
// Weather the client does not draw by shader (pollen, and all of it with
// shader weather off) is drawn as particles, and Goanna's particles do not
// collide, so it fell through every roof. particles.gd draws such a
// spawner with this in place of its StandardMaterial3D: the same billboard,
// kept scale, sprite sheet animation and blend (the variant's render_mode,
// written ahead of this include), and one more test, nothing under the
// rain cover map's roof. It does what BaseMaterial3D generates for these
// particles and nothing else: no lighting, no particle rotation.

#include "res://shaders/weather_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool fixed_y = false;
uniform int anim_h_frames = 1;
uniform int anim_v_frames = 1;
uniform bool anim_loop = false;
uniform float scissor = 0.0;

void vertex() {
	if (fixed_y) {
		// BILLBOARD_FIXED_Y: upright, turned only about the vertical.
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
				vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
				vec4(0.0, 1.0, 0.0, 0.0),
				vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
				MODEL_MATRIX[3]);
	} else {
		// BILLBOARD_PARTICLES: facing the camera.
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1],
				INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
	// billboard_keep_scale: the particle's own size.
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	float h = float(anim_h_frames);
	float v = float(anim_v_frames);
	float total = h * v;
	float frame = floor(INSTANCE_CUSTOM.z * total);
	frame = anim_loop ? mod(frame, total) : clamp(frame, 0.0, total - 1.0);
	UV /= vec2(h, v);
	UV += vec2(mod(frame, h) / h, floor((frame + 0.5) / h) / v);
}

void fragment() {
	if (goanna_rain_open((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, 1.0) < 0.5)
		discard;
	vec4 c = texture(albedo_tex, UV) * COLOR * albedo_color;
	ALBEDO = c.rgb;
	ALPHA = c.a;
	if (scissor > 0.0)
		ALPHA_SCISSOR_THRESHOLD = scissor;
}
