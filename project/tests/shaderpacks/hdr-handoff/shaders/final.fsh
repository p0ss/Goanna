// SPDX-License-Identifier: LGPL-2.1-or-later
// Terrain should finish at gamma(0.5, 0.25, 0.5), about (186, 136, 186).
#version 120
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform float viewWidth;
uniform float viewHeight;
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA16;
void main() {
    vec3 colour = texture2D(colortex0, gl_FragCoord.xy / vec2(viewWidth, viewHeight)).rgb;
    vec4 bits = floor(texture2D(colortex1, gl_FragCoord.xy / vec2(viewWidth, viewHeight)) * 65535.0 + 0.5);
    if (any(notEqual(bits, vec4(4660.0, 43981.0, 65244.0, 17185.0)))) {
        gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0);
        return;
    }
    gl_FragColor = vec4(pow(colour / vec3(4.0, 2.0, 16.0), vec3(1.0 / 2.2)), 1.0);
}
