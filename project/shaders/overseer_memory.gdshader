// SPDX-License-Identifier: LGPL-2.1-or-later
// The overseer's top down view, greyed where it shows remembered columns
// rather than ones the server reported this time. project/game/overseer.gd puts
// this on the SubViewportContainer that holds the orthographic view, and
// sets every uniform. docs/systems/overseer.md.
shader_type canvas_item;
// One texel per column of the requested rectangle: white where the column
// is remembered, black where it is live.
uniform sampler2D memory_mask : filter_nearest, repeat_disable;
// The camera's centre in node x and z (z with Luanti's sign, north up), and
// how many nodes the view spans across and down.
uniform vec2 view_centre;
uniform vec2 view_span;
// The requested rectangle's low corner and its size, in nodes.
uniform vec2 rect_origin;
uniform vec2 rect_size = vec2(1.0);
// False until a reply has filled the mask, and again when a level or
// rectangle change clears it.
uniform bool has_memory = false;
void fragment() {
    vec4 colour = texture(TEXTURE, UV);
    // The node column under this pixel. Screen V runs down and the map's z
    // runs up, hence the flip; the half rounds to the column's centre.
    vec2 cell = floor(view_centre + (UV - vec2(0.5)) * view_span * vec2(1.0, -1.0) + vec2(0.5));
    vec2 at = cell - rect_origin;
    if (has_memory && all(greaterThanEqual(at, vec2(0.0))) && all(lessThan(at, rect_size))) {
        float remembered = texture(memory_mask, (at + vec2(0.5)) / rect_size).r;
        // 30 per cent toward its own luminance and 16 per cent darker.
        float grey = dot(colour.rgb, vec3(0.2126, 0.7152, 0.0722));
        colour.rgb = mix(colour.rgb, mix(colour.rgb, vec3(grey), 0.3) * 0.84, remembered);
    }
    COLOR = colour;
}
