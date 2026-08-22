#version 120
// Writes colortex1 = luma of the scene and colortex2 = inverted scene, which
// final then composes, proving DRAWBUFFERS, the ping pong and clearing.
uniform sampler2D gcolor;   /* legacy alias of colortex0 */

void main() {
    vec3 c = texture2D(gcolor, gl_TexCoord[0].st).rgb * gl_Color.rgb;
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
/* DRAWBUFFERS:12 */
    gl_FragData[0] = vec4(vec3(luma), 1.0);
    gl_FragData[1] = vec4(1.0 - c, 1.0);
}
