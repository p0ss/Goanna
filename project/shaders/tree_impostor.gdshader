// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// A distant tree, drawn by marching the tree's own voxels rather than by
// meshing them. See src/goanna_tree_atlas.h for why the impostor is a volume
// and not a ring of pictures: a volume has the right silhouette from every
// angle including from above, which a ring only has at the angles it was baked
// from.
//
// The mesh is a box standing where the tree stands, as wide as its crown and as
// tall as it is. Every fragment of that box casts a ray through the slot of the
// atlas holding its species and takes the first voxel it meets. So the shape
// that appears is the shape in the atlas, not the box: the box is only the
// volume the march is allowed to happen in.
shader_type spatial;
render_mode cull_front, depth_draw_always, shadows_disabled;

// source_color, and it matters. The atlas holds tile colours as sRGB bytes,
// which is what they are. Without the hint Godot samples them raw and feeds
// sRGB numbers to a linear pipeline, so every tree comes out lighter than the
// same nodes meshed: the impostor and the geometry it stands in for then
// disagree on brightness, which is exactly the seam a continuous field cannot
// afford.
uniform sampler3D atlas : source_color, filter_nearest, repeat_disable;
// Voxels, so the march can step one voxel at a time whatever the tree's size.
uniform vec3 atlas_voxels = vec3(144.0, 40.0, 144.0);
uniform vec3 slot_voxels = vec3(24.0, 40.0, 24.0);
uniform bool write_depth = true;

// Luanti's stored light where this tree stands, x block light and y sky light,
// at the foot and at the crown. Read between them by height, because a crown in
// the sun over a trunk in shade is the ordinary case.
//
// This is what keeps the impostor and the meshed tree the same brightness. The
// near mesh shades from these same two channels, so a tree without them lights
// only from the scene and jumps the moment it crosses into meshed range.
// nodes_array.gdshader is the model being matched: sky light attenuates ambient
// through AO and adds a sky coloured fill as emission, and block light is baked
// emission on the far tiers, which is what an impostor is.
uniform float sky_light_strength : hint_range(0.0, 1.0) = 1.0;
uniform float sky_fill_strength : hint_range(0.0, 2.0) = 1.0;
uniform float block_light_emission : hint_range(0.0, 4.0) = 1.0;
global uniform vec3 goanna_sky_fill;
global uniform vec3 goanna_ground_fill;
// Lets the probe show the march's cost instead of the tree.
uniform bool debug_steps = false;

varying vec3 obj_pos;
varying vec3 obj_cam;
// Per tree, out of the MultiMesh: which slot it draws from, which way it faces,
// and the light it stands in. Every tree in the view is then one draw call, and
// nothing here is a uniform that would force one call per tree.
//
// INSTANCE_CUSTOM carries the slot and the angle, COLOR the four light values,
// because between them that is eight floats and the light needs four of them.
varying flat vec2 v_slot;
varying flat float v_yaw;
varying flat vec4 v_light;

void vertex() {
    obj_pos = VERTEX;
    obj_cam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
    v_slot = INSTANCE_CUSTOM.xy;
    v_yaw = INSTANCE_CUSTOM.z;
    v_light = COLOR;
}

// Slab test against the unit box, in the [0, 1] space the atlas slot uses.
// Also reports which face the ray came in through, since that is the normal of
// the first voxel it can possibly hit.
bool box_span(vec3 origin, vec3 dir, out float t0, out float t1, out vec3 face) {
    vec3 inv = 1.0 / dir;
    vec3 a = (vec3(0.0) - origin) * inv;
    vec3 b = (vec3(1.0) - origin) * inv;
    vec3 lo = min(a, b);
    vec3 hi = max(a, b);
    t0 = max(max(lo.x, lo.y), lo.z);
    t1 = min(min(hi.x, hi.y), hi.z);
    face = -sign(dir) * vec3(equal(lo, vec3(t0)));
    // Starting inside the box is normal: it happens the moment the camera is
    // closer than the crown is wide.
    t0 = max(t0, 0.0);
    return t1 > t0;
}

void fragment() {
    // A BoxMesh spans -0.5 to 0.5, and the atlas slot is addressed 0 to 1.
    //
    // The ray starts at the camera, not at this fragment. cull_front means the
    // fragment being shaded is on the BACK face of the box, so a ray starting
    // there is already leaving: the slab test returns an empty span and every
    // fragment discards. Starting at the camera gives the true entry and exit,
    // and works unchanged when the camera is inside the box, which happens as
    // soon as it is nearer than the crown is wide.
    vec3 origin = obj_cam + vec3(0.5);
    vec3 dir = normalize(obj_pos - obj_cam);

    // The tree turns rather than the atlas: one prototype serves a whole
    // species, and a stand of identical pictures all facing the same way is
    // the tell that gives an impostor away.
    float c = cos(v_yaw);
    float s = sin(v_yaw);
    mat3 turn = mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
    origin = turn * (origin - vec3(0.5)) + vec3(0.5);
    dir = turn * dir;

    float t0;
    float t1;
    vec3 face;
    if (!box_span(origin, dir, t0, t1, face)) {
        discard;
    }

    // Walk voxel by voxel rather than in fixed steps. A fixed step either
    // misses a trunk one voxel wide or oversamples everything else to be sure
    // it does not, and it cannot say which face of a voxel was struck, which
    // is the normal the near mesher would have given that same node. Amanatides
    // and Woo: advance along whichever axis reaches its next boundary first.
    vec3 enter = (origin + dir * t0) * slot_voxels;
    vec3 step_t = dir * slot_voxels;
    ivec3 cell = clamp(ivec3(floor(enter)), ivec3(0), ivec3(slot_voxels) - 1);
    ivec3 advance = ivec3(sign(step_t));
    vec3 delta = abs(1.0 / step_t);
    vec3 next = (vec3(cell) + max(vec3(advance), vec3(0.0)) - enter) / step_t;

    vec3 base = vec3(v_slot.x, 0.0, v_slot.y) * slot_voxels;
    vec4 hit = vec4(0.0);
    float hit_t = t0;
    vec3 normal = face;
    int taken = 0;
    // The longest a ray can be inside a slot is its diagonal in voxels.
    int limit = int(slot_voxels.x + slot_voxels.y + slot_voxels.z);
    for (int i = 0; i < limit; i++) {
        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(slot_voxels)))) {
            break;
        }
        taken = i;
        vec4 v = texture(atlas, (base + vec3(cell) + vec3(0.5)) / atlas_voxels);
        if (v.a > 0.5) {
            hit = v;
            break;
        }
        // Advance, remembering which wall was crossed: that wall is the face
        // of whatever is found next.
        if (next.x < next.y && next.x < next.z) {
            hit_t = t0 + next.x;
            next.x += delta.x;
            cell.x += advance.x;
            normal = vec3(float(-advance.x), 0.0, 0.0);
        } else if (next.y < next.z) {
            hit_t = t0 + next.y;
            next.y += delta.y;
            cell.y += advance.y;
            normal = vec3(0.0, float(-advance.y), 0.0);
        } else {
            hit_t = t0 + next.z;
            next.z += delta.z;
            cell.z += advance.z;
            normal = vec3(0.0, 0.0, float(-advance.z));
        }
    }

    if (hit.a <= 0.5 && !debug_steps) {
        discard;
    }

    ALBEDO = debug_steps ? vec3(float(taken) / float(limit), hit.a, 0.0) : hit.rgb;
    ALPHA = 1.0;
    ROUGHNESS = 0.95;
    SPECULAR = 0.05;

    // Where up the tree the hit was, so the crown reads its own light and the
    // trunk reads its own.
    float up = clamp(float(cell.y) / max(1.0, slot_voxels.y - 1.0), 0.0, 1.0);
    // COLOR packs day at the foot and the crown in rg, night in ba.
    vec2 light = vec2(mix(v_light.b, v_light.a, up), mix(v_light.r, v_light.g, up));

    // Back out of the yaw, then out of object space. MODEL_NORMAL_MATRIX is the
    // inverse transpose, which matters because the box is scaled by the crown
    // in x and z and by the height in y: transforming an axis aligned face by
    // the model matrix alone would lean every normal.
    vec3 obj_n = transpose(turn) * normal;
    vec3 world_n = normalize(MODEL_NORMAL_MATRIX * obj_n);
    NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

    // The same three steps nodes_array.gdshader takes, minus the parts that
    // need a texture: occlusion from sky visibility, a sky coloured fill as
    // emission so the sun's shadow does not darken it, and baked lamp light,
    // which is always on here because an impostor is only ever a far tier.
    float sky_vis = mix(1.0, light.y, sky_light_strength);
    AO = clamp(sky_vis, 0.0, 1.0);
    AO_LIGHT_AFFECT = 0.3;
    float fill_up = clamp(0.5 + 0.5 * world_n.y, 0.0, 1.0);
    vec3 fill_col = mix(goanna_ground_fill, goanna_sky_fill, fill_up);
    float fill_shape = mix(0.65, 1.0, fill_up);
    EMISSION = ALBEDO * fill_col * fill_shape * light.y * sky_fill_strength;
    EMISSION += ALBEDO * light.x * block_light_emission;

    if (write_depth && hit.a > 0.5) {
        // The tree has to sit at the depth of the voxel that was hit, not of
        // the box face the ray entered through, or it will be occluded wrongly
        // by the ground it is standing on.
        vec3 hit_obj = (origin + dir * hit_t) - vec3(0.5);
        hit_obj = transpose(turn) * hit_obj;
        vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * vec4(hit_obj, 1.0);
        DEPTH = clip.z / clip.w;
    }
}
