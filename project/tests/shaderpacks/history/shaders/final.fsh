// SPDX-License-Identifier: LGPL-2.1-or-later
// After ten frames this is red (1, 0, 0); a reset history stays at 0.1.
#version 120
uniform sampler2D colortex6;
void main() {
    gl_FragColor = vec4(min(texture2D(colortex6, vec2(0.5)).r, 1.0), 0.0, 0.0, 1.0);
}
