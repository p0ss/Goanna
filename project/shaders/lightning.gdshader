// Goanna: a lightning bolt, as the server's strike spawner describes it.
// project/ui/lightning.gd builds one quad per strike and drives `flash`;
// docs/weather.md has the whole picture.
//
// The quad stands upright and turns about its own vertical axis to face the
// camera, as a vertical Luanti particle does, and is drawn additive and
// unshaded at several times white, so the bolt is the brightest thing in the
// frame and the glow pass blooms it. It is the server's own texture when the
// client has it (Mineclonia draws its bolt so that it meets the ground at the
// middle of the texture's bottom edge); without one, a jagged line is drawn
// here that meets the ground at the same point.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D bolt_texture : source_color, filter_nearest_mipmap;
uniform bool use_texture = false;
// 0 to 1, the strokes and afterglow, from lightning.gd.
uniform float flash = 0.0;
// Picks the procedural bolt's shape.
uniform float seed = 0.0;
// How many times white the core is drawn, so it survives the exposure and
// catches the glow. Additive, so this is light added, not a colour.
uniform float energy = 6.0;
uniform vec3 bolt_colour = vec3(0.86, 0.9, 1.0);

void vertex() {
	// Godot's own upright billboard, as BILLBOARD_FIXED_Y builds it: the
	// quad's x toward the camera's right in the horizontal plane, y up.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
			vec4(0.0, 1.0, 0.0, 0.0),
			vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
			MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

float bolt_hash(float x) {
	return fract(sin(x * 127.1 + seed * 311.7) * 43758.5453);
}

// Smooth 1D noise, -0.5 to 0.5.
float bolt_noise(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(bolt_hash(i), bolt_hash(i + 1.0), f * f * (3.0 - 2.0 * f)) - 0.5;
}

// Where the channel is across the quad at height v (0 at the top, 1 at the
// strike point), as an offset from the middle in quad widths. Mostly a few
// long bends with finer kinks on them, pinned to the middle at the bottom.
float channel(float v) {
	float x = bolt_noise(v * 4.0) * 0.16 + bolt_noise(v * 13.0 + 7.0) * 0.05
			+ bolt_noise(v * 41.0 + 3.0) * 0.015;
	return x * (1.0 - smoothstep(0.8, 1.0, v));
}

void fragment() {
	vec3 col;
	float a;
	if (use_texture) {
		vec4 t = texture(bolt_texture, UV);
		col = t.rgb;
		a = t.a;
	} else {
		float v = UV.y;
		float d = abs(UV.x - 0.5 - channel(v));
		// One branch off the main channel, forking down and away from a
		// point on its upper half.
		float v0 = 0.25 + 0.3 * bolt_hash(5.0);
		float side = bolt_hash(9.0) < 0.5 ? -1.0 : 1.0;
		float along = (v - v0) / 0.3;
		float bd = 1.0;
		if (along > 0.0 && along < 1.0) {
			float bx = 0.5 + channel(v0) + side * along * 0.12 + bolt_noise(v * 29.0 + 11.0) * 0.02;
			bd = abs(UV.x - bx) + along * 0.004;
		}
		float core = 1.0 - smoothstep(0.0015, 0.005, d);
		float glow = exp(-d / 0.02) * 0.35;
		float branch = (1.0 - smoothstep(0.001, 0.004, bd)) * 0.6 + exp(-bd / 0.012) * 0.15;
		col = bolt_colour;
		a = clamp(core + glow + branch, 0.0, 1.0) * smoothstep(0.0, 0.08, v);
	}
	ALBEDO = col * bolt_colour * energy;
	ALPHA = clamp(a * flash, 0.0, 1.0);
}
