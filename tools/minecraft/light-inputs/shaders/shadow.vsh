#version 120
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform mat4 gbufferModelViewInverse;
void main() {
    vec4 player = gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex;
    gl_Position = shadowProjection * shadowModelView * player;
}
