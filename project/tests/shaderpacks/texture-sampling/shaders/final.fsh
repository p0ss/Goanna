#version 120
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
varying vec2 texcoord;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
void main() {
    vec3 value;
    if (texcoord.x < 0.5 && texcoord.y < 0.5) {
        value = vec3(texture2D(colortex1, vec2(0.5, 0.5)).r,
            texture2D(colortex1, vec2(-0.25, 0.5)).r,
            texture2D(colortex1, vec2(1.25, 0.5)).r);
    }
    else if (texcoord.x >= 0.5 && texcoord.y < 0.5) {
        value = vec3(texture2D(colortex2, vec2(0.5, 0.5)).r,
            texture2D(colortex2, vec2(-0.25, 0.5)).r,
            texture2D(colortex2, vec2(1.25, 0.5)).r);
    }
    else if (texcoord.x < 0.5 && texcoord.y >= 0.5) {
        value = vec3(texture2D(colortex3, vec2(0.5, 0.5)).r,
            texture2D(colortex3, vec2(-0.25, 0.5)).r,
            texture2D(colortex3, vec2(1.25, 0.5)).r);
    }
    else {
        value = vec3(texture2D(colortex4, vec2(0.5, 0.5)).r,
            texture2D(colortex4, vec2(-0.25, 0.5)).r,
            texture2D(colortex4, vec2(1.25, 0.5)).r);
    }
    gl_FragColor = vec4(value, 1.0);
}
