// SPDX-License-Identifier: LGPL-2.1-or-later
shader_type canvas_item;
uniform sampler2D memory_mask : filter_nearest, repeat_disable;
uniform vec2 view_centre;
uniform vec2 view_span;
uniform vec2 rect_origin;
uniform vec2 rect_size = vec2(1.0);
uniform bool has_memory = false;
void fragment() {
    vec4 colour = texture(TEXTURE, UV);
    vec2 cell = floor(view_centre + (UV - vec2(0.5)) * view_span * vec2(1.0, -1.0) + vec2(0.5));
    vec2 at = cell - rect_origin;
    if (has_memory && all(greaterThanEqual(at, vec2(0.0))) && all(lessThan(at, rect_size))) {
        float remembered = texture(memory_mask, (at + vec2(0.5)) / rect_size).r;
        float grey = dot(colour.rgb, vec3(0.2126, 0.7152, 0.0722));
        colour.rgb = mix(colour.rgb, mix(colour.rgb, vec3(grey), 0.3) * 0.84, remembered);
    }
    COLOR = colour;
}
