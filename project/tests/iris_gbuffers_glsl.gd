# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Checks the gbuffers translator turns GLSL constructions that Godot's
## shading language spells differently, or refuses, into Godot shaders its
## front end accepts. Headless, no server or GPU:
## godot --headless --path project --script res://tests/iris_gbuffers_glsl.gd
## GOANNA_GLSL_CASE=name runs one case and prints its translation.
#
# Godot's language looks like GLSL and is stricter: it converts nothing
# implicitly, takes constructor arguments only of the target's base type and
# exact width, holds built in calls in a constant to literal and constant
# arguments, compiles both stages as one unit, and has no matrix negation
# or shift between int and uint. Shader packs are written for GL drivers,
# which take all of that. Each case below is one such construction in a
# pack of its own (gbuffers_terrain only), with its inputs read from
# uniforms so nothing folds away; a case passes when the translated terrain
# shader compiles. They came from the 22 surveyed packs failing on
# 2026-10-20 (docs/develop/shaderpack-status.md) and from the neighbouring
# constructions those failures pointed to. A case is
# [name, fragment globals, fragment body adding to r, vertex globals,
# vertex body].
extends SceneTree

const CASES := [
	["ctor_trunc_vec", "", "vec3 a = vec3(vec4(u)); r += a.x;"],
	["ctor_trunc_last", "", "vec3 a = vec3(vec2(u), vec4(u)); r += a.z;"],
	["ctor_trunc_vec2", "", "vec2 a = vec2(vec3(u)); r += a.y;"],
	["ctor_trunc_ivec", "", "ivec2 a = ivec2(ivec4(iu)); r += float(a.x);"],
	["ctor_trunc_matvec", "", "vec3 a = vec3(gbufferModelView * vec4(u)); r += a.x;"],
	["ctor_int_from_float", "", "ivec2 a = ivec2(u); r += float(a.y);"],
	["ctor_int_from_vec", "", "ivec3 a = ivec3(vec3(u)); r += float(a.z);"],
	["ctor_int_mixed", "", "ivec3 a = ivec3(u, iu, 1.5); r += float(a.x);"],
	["ctor_uint_from_int", "", "uvec2 a = uvec2(iu); r += float(a.x);"],
	["ctor_uint_from_float_vec", "", "uvec3 a = uvec3(vec3(u)); r += float(a.x);"],
	["ctor_bool_from_float", "", "bool b = bool(u); bvec2 bb = bvec2(u, iu); if (b && bb.y) r += 1.0;"],
	["ctor_float_from_bool", "", "bool b = u > 0.0; vec2 a = vec2(true, b); r += a.y;"],
	["ctor_vec_from_bvec", "", "vec3 a = vec3(greaterThan(vec3(u), vec3(0.5))); r += a.x;"],
	["ctor_mat3_from_mat4", "", "mat3 m = mat3(gbufferModelView); r += m[0].x;"],
	["ctor_mat4_from_mat3", "", "mat4 m = mat4(mat3(u)); r += m[3].w;"],
	["ctor_mat2_from_mat4", "", "mat2 m = mat2(gbufferModelView); r += m[1].y;"],
	["ctor_mat_diag_int", "", "mat3 m = mat3(1); r += m[1].y;"],
	["ctor_mat_mixed_cols", "", "mat2 m = mat2(u, 1, vec2(u)); r += m[1].x;"],
	["ctor_vec4_from_mat2", "", "vec4 a = vec4(mat2(u)); r += a.w;"],
	["ctor_vec_int_args", "", "vec3 a = vec3(1, iu, u); r += a.y;"],
	["ctor_struct_int", "struct S { float a; int b; };", "S s = S(1, 2); r += s.a + float(s.b);"],
	["assign_int", "", "float a = 1; a = iu; r += a;"],
	["compound_int", "", "float a = u; a += 1; a *= iu; r += a;"],
	["vec_compound_int", "", "vec2 a = vec2(u); a *= 2; a += iu; r += a.x;"],
	["return_int", "float f() { return 1; }", "r += f();"],
	["return_int_var", "float f(int k) { return k; }", "r += f(iu);"],
	["ternary_lit", "", "float a = u > 0.0 ? 1 : 2.0; r += a;"],
	["ternary_var", "", "float a = u > 0.0 ? iu : u; r += a;"],
	["ternary_vec", "", "vec3 a = u > 0.0 ? vec3(1) : vec3(iu); r += a.x;"],
	["array_ctor_int", "", "float a[3] = float[3](1, 2, iu); r += a[2];"],
	["array_list_int", "", "float a[2] = {1.0, 2}; r += a[1];"],
	["compare_int_float", "", "if (iu < u) r += 1.0;"],
	["div_mixed", "", "r += iu / 2.0 + 2 * u;"],
	["vec_div_int", "", "vec2 a = vec2(u) / 2; r += a.x;"],
	["uint_literal_int", "", "uint a = 3; a = a + 1; r += float(a);"],
	["uint_int_var", "", "uint a = uint(iu); a = a & 0xFF; a = a >> 2; r += float(a);"],
	["bitwise_int_uint", "", "uint a = iu & 3u; r += float(a);"],
	["shift_int_uint", "", "int a = iu << 2u; r += float(a);"],
	["builtin_int_args", "", "r += mod(u, 2) + pow(u, 2) + min(u, 1) + clamp(u, 0, 1) + max(1, u);"],
	["builtin_int_vec", "", "vec3 a = clamp(vec3(u), 0, 1); r += a.x;"],
	["step_scalar_vec", "", "vec3 a = step(0.5, vec3(u)); r += a.x;"],
	["mix_bvec", "", "vec3 a = mix(vec3(0.0), vec3(1.0), bvec3(u > 0.0)); r += a.x;"],
	["atan2_int", "", "r += atan(1, u);"],
	["abs_int", "", "r += float(abs(iu) + sign(iu));"],
	["texlod_int", "", "r += textureLod(texture, texcoord, 0).r;"],
	["texelfetch_float_coord", "", "r += texelFetch(texture, ivec2(texcoord * 16.0), 0).r;"],
	["texsize_vec2", "", "vec2 s = vec2(textureSize(texture, 0)); r += s.x;"],
	["const_call_expr", "const float A = 2.0; const float B = max(A * 2.0, 1.0);", "r += B;"],
	["const_call_ctor", "const float A = 2.0; const vec3 C = max(vec3(A), vec3(1.0));", "r += C.x;"],
	["const_ctor_float_to_int", "const float A = 2.0; const ivec2 S = ivec2(A * 2.0);", "r += float(S.x);"],
	["const_cast_int_expr", "const int N = 1024; const float F = 2048.0 / float(N) * 0.5;", "r += F;"],
	["const_member", "const ivec3 V = ivec3(4, 5, 6); const float D = min(float(V.x), 3.0);", "r += D;"],
	["const_nested_calls", "const float A = sqrt(abs(-4.0)); const float B = pow(A, 2.0);", "r += B;"],
	["const_local_nonconst", "", "const float k = u * 2.0; r += k;"],
	["const_local_const", "", "const float k = 2.0 * 3.0; r += k;"],
	["const_array_size", "const int N = 4;", "float a[N]; a[0] = u; r += a[0];"],
	["const_array_global", "const float W[3] = float[3](0.25, 0.5, 0.25);", "r += W[1];"],
	["const_vec_swizzle", "const vec3 K = vec3(1.0, 2.0, 3.0); const vec2 J = K.xy;", "r += J.y;"],
	["const_pi", "const float PI = 3.14159265; const float TAU = 6.2831853; const float E = 2.71828;", "r += PI + TAU + E;"],
	["switch_const_case", "const int K = 2;", "switch (iu) { case K: r += 1.0; break; default: break; }"],
	["global_init_var", "float g = 1.0;", "g += u; r += g;"],
	["global_init_uniform_expr", "float g2 = 0.0;", "g2 = viewWidth * 2.0; r += g2;"],
	["uniform_default", "uniform float tweak = 2.0;", "r += tweak;"],
	["user_fn_texture_name", "float textureFoo(sampler2D t, vec2 c) { return texture2D(t, c).r; }", "r += textureFoo(texture, texcoord);"],
	["user_fn_texture2DShadow", "float texture2DShadow(sampler2D t, vec3 c) { return step(c.z, texture2D(t, c.xy).r); }", "r += texture2DShadow(texture, vec3(texcoord, u));"],
	["user_fn_shadow2D_name", "float shadow2DSoft(sampler2DShadow t, vec3 c) { return shadow2D(t, c).x; }", "r += shadow2DSoft(shadowtex0, vec3(texcoord, u));"],
	["shadow_texture_float", "", "float s = texture(shadowtex0, vec3(texcoord, u)); r += s;"],
	["shadow2D_x", "", "float s = shadow2D(shadowtex0, vec3(texcoord, u)).x; r += s;"],
	["shadowing_nested", "float f(float x) { float y = x; { float y = 2.0; x += y; } return y + x; }", "r += f(u);"],
	["shadowing_param", "float f(float x) { for (int x2 = 0; x2 < 2; x2++) { float x = 1.0; r0 += x; } return x; } ", "r += f(u);"],
	["loop_var_reuse", "", "for (int i = 0; i < 2; i++) r += 1.0; for (int i = 0; i < 2; i++) r += 1.0; int i = 3; r += float(i);"],
	["local_named_like_fn", "float g(float a) { return a; }", "float g_ = g(u); r += g_;"],
	["godot_words", "", "float hint = u; float instance = u; float global = u; float varying_ = u; float group_uniforms = u; r += hint + instance + global + group_uniforms;"],
	["godot_builtin_names", "", "float TIME = u; float VERTEX = u; float NORMAL = u; float ALBEDO = u; float UV = u; float LIGHT = u; float COLOR = u; r += TIME + VERTEX + NORMAL + ALBEDO + UV + LIGHT + COLOR;"],
	["stage_const_differs", "const vec2 offs[2] = vec2[2](vec2(1.0), vec2(2.0));", "r += offs[1].x;", "const vec2 offs[2] = vec2[2](vec2(3.0), vec2(4.0));", "gl_Position.xy += offs[0] * 0.0;"],
	["stage_struct_differs", "struct P { float a; };", "P p = P(u); r += p.a;", "struct P { vec2 a; };", "P p = P(vec2(1.0)); gl_Position.x += p.a.x * 0.0;"],
	["stage_fn_differs", "float h(float a) { return a * 2.0; }", "r += h(u);", "float h(float a) { return a * 3.0; }", "gl_Position.x += h(0.0);"],
	["stage_global_differs", "float shared_g;", "shared_g = u; r += shared_g;", "vec2 shared_g;", "shared_g = vec2(0.0); gl_Position.xy += shared_g;"],
	["scalar_swizzle", "", "vec3 a = u.xxx; r += a.y;"],
	["float_suffixes", "", "r += 1.0f + 2.f + .5 + 1e2 + 1.5e-2F + 3.F;"],
	["hex_literals", "", "int a = 0x1F; uint b = 0xFFu; r += float(a) + float(b);"],
	["increment_float", "", "float a = u; a++; ++a; a--; r += a;"],
	["array_length", "", "float a[3]; a[0] = u; r += float(a.length());"],
	["precision_qual", "", "highp float a = u; mediump vec2 b = vec2(a); r += b.x;"],
	["discard_in_fn", "void f(float a) { if (a < 0.0) discard; }", "f(u); r += 1.0;"],
	["array_param", "float sum3(float a[3]) { return a[0] + a[1] + a[2]; }", "float a[3] = float[3](u, u, u); r += sum3(a);"],
	["array_return", "float[2] two() { return float[2](1.0, 2.0); }", "r += two()[1];"],
	["out_param", "void f(out float x, inout vec2 y) { x = 1.0; y += 1.0; }", "float x; vec2 y = vec2(u); f(x, y); r += x + y.x;"],
	["const_param", "float f(const in float x) { return x * 2.0; }", "r += f(u);"],
	["do_while", "", "int k = 0; do { r += 1.0; k++; } while (k < 2);"],
	["comma_for", "", "for (int i = 0, j = 4; i < j; i++, j--) r += 1.0;"],
	["vec_eq", "", "if (vec3(u) == vec3(1)) r += 1.0;"],
	["bool_ops", "", "bool a = u > 0.0, b = iu > 0; if (a ^^ b) r += 1.0;"],
	["matrix_ops", "", "mat3 m = mat3(u); r += determinant(m) + inverse(m)[0].x + transpose(m)[1].x + matrixCompMult(m, m)[0].x;"],
	["bit_functions", "", "r += float(bitCount(iu) + findMSB(iu) + bitfieldExtract(iu, 1, 2));"],
	["pack_functions", "", "r += unpackUnorm4x8(packUnorm4x8(vec4(u))).x + unpackHalf2x16(packHalf2x16(vec2(u))).y;"],
	["frexp_ldexp", "", "int e; float m = frexp(u, e); r += ldexp(m, e);"],
	["fragcoord_frontfacing", "", "r += gl_FragCoord.x * (gl_FrontFacing ? 1.0 : 0.5);"],
	["ivec_float_mul", "", "ivec2 a = ivec2(iu); vec2 b = a * 0.5; r += b.x;"],
	["int_mod_neg", "", "int a = iu % 3; r += float(a);"],
	["global_mat_uniform_mul", "", "vec4 p = gbufferModelView * vec4(u); r += p.x;"],
	["arb_grad", "", "r += texture2DGradARB(texture, texcoord, vec2(0.01), vec2(0.01)).r + texture2DLodARB(texture, texcoord, 0.0).r;"],
	["arb_grad_param", "float g(sampler2D t, vec2 c) { return texture2DGradARB(t, c, dFdx(c), dFdy(c)).r; }", "r += g(texture, texcoord);"],
	["overload_uint", "float s(float a, const uint n) { return a * float(n); } float s(float a) { return a; }", "r += s(u, 6) + s(u);"],
	["overload_int_to_float", "float s(float a, float b) { return a * b; } float s(vec2 a) { return a.x; }", "r += s(u, 2) + s(vec2(u));"],
	["attr_midblock_vec3", "", "r += 1.0;", "in vec3 at_midBlock; in vec3 at_tangent;", "gl_Position.xyz += (at_midBlock / 64.0 + at_tangent) * 0.0;"],
	["sampler3d_unbound", "uniform sampler3D voxelTex; uniform usampler3D voxelIds; uniform isampler2D ints;", "r += texture(voxelTex, vec3(u)).r + textureLod(voxelTex, vec3(u), 0.0).g + float(texelFetch(voxelIds, ivec3(1), 0).r) + float(texelFetch(ints, ivec2(1), 0).r) + float(textureSize(voxelTex, 0).z);"],
	["sampler2darray_unbound", "uniform sampler2DArray layers;", "r += texture(layers, vec3(texcoord, 1.0)).r;"],
	["const_param_uniform", "float f(const int k) { return float(k % 16); }", "r += f(frameCounter);"],
	["const_param_uniform_float", "float f(const float k) { return k; }", "r += f(viewWidth);"],
	["matrix_negate", "", "mat3 m = mat3(u); mat3 n = -m; r += n[0].x;"],
	["image_unbound", "uniform layout(r32ui) uimage3D voxelImg;", "uint v = imageLoad(voxelImg, ivec3(1)).r; imageStore(voxelImg, ivec3(1), uvec4(v)); r += float(v) + float(imageSize(voxelImg).x);"],
	["normals_sampler", "uniform sampler2D normals;", "r += texture2D(normals, texcoord).z;"],
	["nonsquare_mat", "", "mat2x3 m = mat2x3(vec3(u), vec3(1.0)); vec3 v = m * vec2(1.0); r += v.x;"],
]

const FRAGMENT := """#version 330 compatibility
uniform sampler2D texture;
uniform sampler2DShadow shadowtex0;
uniform float viewWidth;
uniform int frameCounter;
uniform mat4 gbufferModelView;
varying vec2 texcoord;
float r0 = 0.0;
%s
void main() {
	float u = viewWidth;
	int iu = frameCounter;
	float r = 0.0;
	%s
	gl_FragData[0] = texture2D(texture, texcoord) * (r + r0);
}
"""

const VERTEX := """#version 330 compatibility
varying vec2 texcoord;
%s
void main() {
	texcoord = gl_MultiTexCoord0.xy;
	gl_Position = ftransform();
	%s
}
"""

var failures: Array[String] = []


func write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var only := OS.get_environment("GOANNA_GLSL_CASE")
	var base := OS.get_temp_dir().path_join("goanna-iris-glsl-%d" % OS.get_process_id())
	var ran := 0
	for c in CASES:
		if only != "" and c[0] != only:
			continue
		var dir: String = base.path_join(c[0]).path_join("shaders")
		DirAccess.make_dir_recursive_absolute(dir)
		write(dir.path_join("gbuffers_terrain.fsh"), FRAGMENT % [c[1], c[2]])
		write(dir.path_join("gbuffers_terrain.vsh"), VERTEX % ([c[3], c[4]] if c.size() > 3 else ["", ""]))
		write(dir.path_join("shaders.properties"), "")
		var g := GoannaIrisGbuffers.new()
		ran += 1
		if not g.load_pack(dir.get_base_dir()):
			failures.append("%s: the pack did not load: %s" % [c[0], g.report()])
			continue
		var shader: Shader = g.shader(0)
		if shader == null:
			failures.append("%s: no terrain shader: %s" % [c[0], g.report()])
			continue
		if only != "":
			print(shader.code)
		# A shader Godot refuses has no uniforms; the terrain shell always
		# declares some.
		if shader.get_shader_uniform_list(true).is_empty():
			failures.append("%s: Godot refused the translation" % c[0])
	_remove(base)
	for f in failures:
		push_error(f)
	print("iris_gbuffers_glsl: %d of %d cases compile" % [ran - failures.size(), ran])
	quit(1 if not failures.is_empty() or ran == 0 else 0)


func _remove(path: String) -> void:
	for d in DirAccess.get_directories_at(path):
		_remove(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
