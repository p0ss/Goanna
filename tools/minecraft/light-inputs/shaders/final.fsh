#version 120
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
varying vec2 texcoord;
void main() {
    vec2 uv = fract(texcoord * 2.0);
    vec4 c;
    if (texcoord.y >= 0.5) {
        if (texcoord.x < 0.5) c = texture2D(colortex0, uv);
        else c = texture2D(colortex1, uv);
    } else {
        if (texcoord.x < 0.5) c = texture2D(colortex2, uv);
        else c = texture2D(colortex3, uv);
    }
    gl_FragColor = vec4(c.rgb, 1.0);
}
