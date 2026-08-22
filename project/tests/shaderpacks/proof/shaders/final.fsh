#version 120
#extension GL_ARB_shader_texture_lod : enable
#include "/lib/common.glsl"

/*
const int colortex1Format = R16F;
const int colortex2Format = RGBA8;
const int noiseTextureResolution = 64;
*/

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;
uniform sampler2D noisetex;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTimeCounter;
uniform vec3 sunPosition;
uniform int worldTime;

varying vec2 texcoord;

void main() {
    vec3 colour = texture2D(colortex0, texcoord).rgb;
    // A mild warm grade plus a vignette: visibly a post pass, not a swap.
    colour = mix(colour, colour * vec3(1.08, 1.0, 0.9), 0.6) * proof_vignette(texcoord);
    // Right third: what composite wrote to colortex1 (luma). Middle third:
    // colortex2 (inverted). Left third: the graded scene.
    if (texcoord.x > 0.6666)
        colour = vec3(texture2D(colortex1, texcoord).r);
    else if (texcoord.x > 0.3333)
        colour = texture2D(colortex2, texcoord).rgb;
    // Bottom band: unmistakable magenta, so a screenshot check is trivial.
    if (texcoord.y > 1.0 - PROOF_BAND)
        colour = vec3(1.0, 0.0, 1.0);
    // Top left square pulses with frameTimeCounter: the uniform block is live.
    vec2 px = texcoord * vec2(viewWidth, viewHeight);
    if (px.x < 48.0 && px.y < 48.0)
        colour = vec3(0.5 + 0.5 * sin(frameTimeCounter * 3.0), 0.2, 0.2);
    // Next square: the depth buffer at screen centre, as a grey. Whatever it
    // reads, it proves depthtex0 is bound.
    if (px.x >= 56.0 && px.x < 104.0 && px.y < 48.0)
        colour = vec3(texture2D(depthtex0, vec2(0.5, 0.5)).r);
    // And one of noise, to prove noisetex.
    if (px.x >= 112.0 && px.x < 160.0 && px.y < 48.0)
        colour = texture2D(noisetex, px / 64.0).rgb;
    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(colour, 1.0);
}
