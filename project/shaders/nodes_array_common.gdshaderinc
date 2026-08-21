// Goanna: uniforms shared between the node array shaders.
//
// Only the uniforms live here, not the decode logic: Godot only allows a
// write to a fragment built-in (ALBEDO, ROUGHNESS, ...) from inside
// fragment() itself, not from a function it calls, so the LabPBR decode is
// duplicated in nodes_array.gdshader and nodes_array_scissor.gdshader rather
// than shared. Change one, change the other.

uniform sampler2DArray normal_array : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray spec_array : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform bool has_spec = false;
// Per channel strengths. A LabPBR pack is authored for someone else's
// renderer and someone else's art, so its channels routinely arrive too hot
// for the game they are dressing: the Mineclonia bake's normals carry a
// per channel standard deviation over 40 of 255, and its ambient occlusion
// reaches 147, which on 16 pixel art reads as smeared blotches rather than
// relief. Each of these scales one decoded channel, 1.0 being the pack as
// authored and 0.0 being that channel off. They are set from the settings
// panel through GoannaClient::set_material_strength.
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_strength : hint_range(0.0, 1.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 1.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 4.0;
uniform float sss_strength : hint_range(0.0, 1.0) = 1.0;

// Per vertex node light and occlusion, packed into CUSTOM0 by
// GoannaClient::update_blocks: r is Luanti's block light (torches, lava), g is
// its sky light, b is Goanna's own ambient occlusion, a is spare. See
// docs/mesh-attributes.md for the contract and why light does not ride in
// COLOR.
//
// How much each channel is allowed to do is a uniform rather than a constant,
// because the balance is judged on lighting_chart.tscn and is expected to move
// (docs/pbr-plan.md step 3).
//
// sky_light_strength attenuates ambient by how much sky reaches the vertex,
// which is what makes an interior read as an interior instead of being lit by
// the sky through its own roof.
uniform float sky_light_strength : hint_range(0.0, 1.0) = 1.0;
// vertex_ao_strength scales the traced occlusion. It multiplies ambient only.
uniform float vertex_ao_strength : hint_range(0.0, 1.0) = 1.0;
// How much occlusion is allowed to touch direct light. Occlusion is not
// shadow, so this is 0 by default and exists to be swept, not to be turned up.
uniform float vertex_ao_light_strength : hint_range(0.0, 1.0) = 0.0;
// Block light as emission. Off by default: Goanna already places real Godot
// lights for light emitting nodes, so adding it here would count torches
// twice. The far tiers, which are past the range those lights reach, turn it
// on; see docs/far-rendering.md.
uniform float block_light_emission : hint_range(0.0, 4.0) = 0.0;

// Paints the three channels straight onto the screen as emission: red block
// light, green sky light, blue occlusion. It answers "is this data arriving at
// all", which no amount of looking at a lit frame can, and it is a channel
// rather than a define so it can be toggled inside one run.
uniform float debug_nodelight_strength : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_nodelight;
