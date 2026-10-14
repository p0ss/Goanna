// SPDX-License-Identifier: LGPL-2.1-or-later
// Values above one and all four packed channels must survive transport.
#version 120
/* DRAWBUFFERS:01 */
void main() {
    gl_FragData[0] = vec4(2.0, 0.5, 8.0, 1.0);
    gl_FragData[1] = vec4(4660.0, 43981.0, 65244.0, 17185.0) / 65535.0;
}
