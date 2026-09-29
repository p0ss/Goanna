// Goanna: alpha-blended non-liquid nodes (glass, ice, stained glass): TILE_MATERIAL_ALPHA,
// and clear glass that its game cuts out rather than blends (see
// buildFakeLiquidTextures in goanna_client.cpp). A cut-out texel is
// transparent, so there it shows only the refracted scene and the reflection.
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

#include "res://shaders/glass_common.gdshaderinc"
