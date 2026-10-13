// SPDX-License-Identifier: LGPL-2.1-or-later
// A preserved buffer must accumulate across frames, from a defined zero.
#version 120
uniform sampler2D colortex6;
const int colortex6Format = R32F;
const bool colortex6Clear = false;
/* DRAWBUFFERS:6 */
void main() {
    gl_FragData[0] = vec4(texture2D(colortex6, vec2(0.5)).r + 0.1);
}
