// Goanna: opaque node tiles drawn from an array texture.
//
// Luanti's mesher groups same-sized tile images into array textures and writes
// each vertex's layer index into S3DVertex::Aux; Goanna carries that across as
// UV2.x. A whole bunch of different node tiles can then share one material,
// which is what takes a block from ~19 draw calls down to a handful.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2DArray albedo_array : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool scissor = true;

void fragment() {
	vec4 tex = texture(albedo_array, vec3(UV, UV2.x)) * COLOR;
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	if (scissor)
		ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
}
