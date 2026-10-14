#version 120
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

/* DRAWBUFFERS:0123 */
uniform sampler2D texture;
uniform vec3 sunPosition;
varying vec2 texcoord;
varying vec2 lmcoord;
varying vec4 colour;
void main() {
    vec4 art = texture2D(texture, texcoord);
    if (art.a < 0.1) discard;
    gl_FragData[0] = vec4(art.rgb, 1.0);
    gl_FragData[1] = vec4(colour.rgb, 1.0);
    gl_FragData[2] = vec4(lmcoord, 0.0, 1.0);
    vec3 sun = normalize(sunPosition);
    gl_FragData[3] = vec4(sun * 0.5 + 0.5, 1.0);
}
