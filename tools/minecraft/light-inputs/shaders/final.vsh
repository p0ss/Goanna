#version 120
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
varying vec2 texcoord;
void main() { gl_Position = ftransform(); texcoord = gl_MultiTexCoord0.xy; }
