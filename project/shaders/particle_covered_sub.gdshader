// Goanna: particle_covered.gdshaderinc with blend_sub, for a weather
// spawner drawn as particles; particles.gd picks the file by blend and
// loads it through client.load_view_shader, so a local player's copy reads
// that player's rain cover map.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, blend_sub;
#include "res://shaders/particle_covered.gdshaderinc"
