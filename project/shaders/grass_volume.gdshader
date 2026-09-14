// SPDX-License-Identifier: LGPL-2.1-or-later
// Bounded procedural grass experiment. Inspired by MonterMan's grass field
// (shadertoy dd2cWh, supplied by the user); independently implemented tapered
// blade distance estimator, per-surface bounds, depth and Godot lighting.
shader_type spatial;
render_mode cull_front, diffuse_burley, specular_schlick_ggx, alpha_to_coverage, depth_draw_always;

global uniform vec3 goanna_sky_fill;
global uniform vec3 goanna_ground_fill;
global uniform float goanna_wetness;
uniform bool enabled = true;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.45;
uniform int march_steps : hint_range(16, 128) = 64;
uniform float detail_near = 35.0;
uniform float detail_far = 95.0;
uniform float clock_override = -1.0;
uniform bool debug_iterations = false;
uniform bool debug_bounds = false;
uniform bool analytic_blades = true;
uniform bool composite_edges = true;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest;
uniform int interaction_count = 0;
uniform vec4 interaction_centres[8];
uniform bool interaction_enabled = true;
uniform float interaction_angle : hint_range(0.0, 0.8) = 0.8;

varying flat vec4 patch;
varying flat vec3 root_light;
varying flat float shadow_pass;
varying flat float patch_margin;
varying vec3 world_exit;

// Integer hashing retains deterministic cells on either side of the origin.
uint grass_hash(ivec2 cell) {
    uint h = uint(cell.x) * 1597334677u ^ uint(cell.y) * 3812015801u;
    h = (h ^ (h >> 16u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    return h ^ (h >> 16u);
}
vec4 grass_random(ivec2 cell) {
    uint h = grass_hash(cell);
    return vec4(float(h & 255u), float((h >> 8u) & 255u),
        float((h >> 16u) & 255u), float(h >> 24u)) / 255.0;
}
float grass_noise(vec2 p) {
    ivec2 cell = ivec2(floor(p));
    vec2 f = fract(p);
    f = f*f*(3.0-2.0*f);
    return mix(mix(grass_random(cell).x, grass_random(cell+ivec2(1,0)).x, f.x),
        mix(grass_random(cell+ivec2(0,1)).x, grass_random(cell+ivec2(1,1)).x, f.x), f.y);
}

void vertex() {
    // Terrain tiers translate their meshes by half a node. Transform both
    // the root bounds and the proxy, so the hash field never restarts at LOD.
    vec3 lower = (MODEL_MATRIX * vec4(CUSTOM0.x, CUSTOM1.x, CUSTOM0.y, 1.0)).xyz;
    vec3 upper = (MODEL_MATRIX * vec4(CUSTOM0.z, CUSTOM1.x, CUSTOM0.w, 1.0)).xyz;
    // The terrain's bevel insets its top polygon. Grass belongs to the
    // entire voxel footprint, including that small rim.
    patch = vec4(floor(lower.xz+vec2(0.5001))-vec2(0.5),
        ceil(upper.xz+vec2(0.4999))-vec2(0.5));
    root_light = vec3(lower.y, CUSTOM1.yz);
    // Empty space around every block used to cover much of the screen when
    // the camera entered the grass. Only enlarge the volume where a nearby
    // actor can actually push a blade beyond its normal wind envelope.
    patch_margin=0.11;
    if (interaction_enabled) {
        for (int i=0;i<8;i++) {
            if (i>=interaction_count) break;
            vec4 actor=interaction_centres[i];
            float separation=distance(actor.xz,clamp(actor.xz,patch.xy,patch.zw));
            float weight=(1.0-smoothstep(0.0,actor.w,separation))*
                (1.0-smoothstep(0.25,0.9,abs(lower.y-actor.y)));
            patch_margin=max(patch_margin,0.11+1.1*sin(clamp(interaction_angle,0.0,0.8)*weight));
        }
    }
    vec3 middle = vec3((CUSTOM0.x+CUSTOM0.z)*0.5,CUSTOM1.x+0.1,(CUSTOM0.y+CUSTOM0.w)*0.5);
    world_exit = vec3(VERTEX.x > middle.x ? patch.z+patch_margin : patch.x-patch_margin,
        lower.y+(VERTEX.y > middle.y ? 1.24 : 0.002),
        VERTEX.z > middle.z ? patch.w+patch_margin : patch.y-patch_margin);
    // Terrain meshes are world-axis aligned and only translated by tier.
    VERTEX = world_exit-MODEL_MATRIX[3].xyz;
    shadow_pass = length(INV_VIEW_MATRIX[3].xyz - MAIN_CAM_INV_VIEW_MATRIX[3].xyz);
}

vec3 grass_interaction(vec2 anchor) {
    vec3 result=vec3(0.0);
    if (!interaction_enabled) return result;
    for (int i=0;i<8;i++) {
        if (i>=interaction_count) break;
        vec4 actor=interaction_centres[i];
        vec2 delta=anchor-actor.xz;
        float distance=length(delta);
        float weight=(1.0-smoothstep(0.0,actor.w,distance))*
            (1.0-smoothstep(0.25,0.9,abs(root_light.x-actor.y)));
        if (weight>result.z) result=vec3(delta/max(distance,0.05),weight);
    }
    return result;
}

// Rotate the complete curved blade about its planted root. An orthogonal
// transform preserves every segment length and width; lowering the tip is
// a result of bending, never a change to the blade's height parameter.
vec3 grass_unbend(vec3 v, vec3 pressure) {
    float axis_length=length(pressure.xy);
    if (pressure.z<0.0001 || axis_length<0.0001) return v;
    vec3 axis=vec3(pressure.y,0.0,-pressure.x)/axis_length;
    float angle=clamp(interaction_angle,0.0,0.8)*pressure.z;
    float c=cos(angle),s=sin(angle);
    return v*c-cross(axis,v)*s+axis*dot(axis,v)*(1.0-c);
}

int grass_neighbourhood(vec3 p) {
    if (!interaction_enabled) return 1;
    int radius=1;
    for (int i=0;i<8;i++) {
        if (i>=interaction_count) break;
        vec4 actor=interaction_centres[i];
        float weight=1.0-smoothstep(0.25,0.9,abs(root_light.x-actor.y));
        float angle=clamp(interaction_angle,0.0,0.8)*weight;
        // A bent tip can reach far from its root, but the lower blade cannot.
        // Bound roots using this ray segment's height, including the complete
        // wind curve and blade width after rotation.
        float reach=min(0.11+1.1*sin(angle),
            max(p.y-root_light.x,0.0)*tan(angle)+0.11/cos(angle));
        if (weight>0.0001 && distance(p.xz,actor.xz)<actor.w+reach)
            radius=max(radius,int(ceil(reach/0.12)));
    }
    return radius;
}

float grass_distance(vec3 p, float tm) {
    const float spacing = 0.12;
    float y = p.y-root_light.x;
    if (y > 1.12) return (y-1.1)*0.55;
    float gust = sin(dot(p.xz,vec2(0.17,0.11))-tm*1.7);
    ivec2 cell = ivec2(floor(p.xz / spacing));
    float result = 1.0;
    if (all(greaterThanEqual(p.xz,patch.xy)) && all(lessThan(p.xz,patch.zw))) {
        // The root bed is part of the same field. Even the gaps between
        // blades inherit its continuous colour rather than revealing a tile.
        result = (p.y-root_light.x-0.012)*0.55;
    }
    int radius=grass_neighbourhood(p);
    for (int z = -radius; z <= radius; z++) {
        for (int x = -radius; x <= radius; x++) {
            ivec2 id = cell + ivec2(x,z);
            vec4 rnd = grass_random(id);
            vec2 anchor = (vec2(id) + vec2(0.15) + rnd.xy*0.7)*spacing;
            if (any(lessThan(anchor, patch.xy)) || any(greaterThanEqual(anchor, patch.zw))) continue;
            float height = 0.55 + 0.55*rnd.w;
            vec3 pressure=grass_interaction(anchor);
            if (pressure.z<0.0001 && (abs(x)>1 || abs(z)>1)) continue;
            vec3 centre=vec3(anchor.x,root_light.x,anchor.y);
            vec3 local_p=centre+grass_unbend(p-centre,pressure);
            float local_y=local_p.y-root_light.x;
            float t = clamp(local_y/height, 0.0, 1.0);
            vec2 axis = normalize(vec2(rnd.z,rnd.x)*2.0-1.0+vec2(0.0001));
            vec2 bend = axis*(0.045+0.025*rnd.x) + vec2(0.03,0.02)*gust*wind_strength;

            vec2 q = local_p.xz-anchor-bend*t*t;
            float width = (0.03+0.018*rnd.y)*(1.0-t)+0.001;
            float side = abs(dot(q, axis))-width;
            float thin = abs(dot(q,vec2(-axis.y,axis.x)))-0.004;
            float vertical = max(-local_y,local_y-height);
            // Conservative step for the curved coordinate warp.
            result = min(result, max(max(side,thin),vertical)*0.55);
        }
    }
    return result;
}

// The blades have a quadratic bend, so their intersections can be solved
// directly inside each grid cell. This keeps the same procedural field but
// avoids dozens of tiny distance steps between adjacent leaves.
vec3 blade_root(float t, vec3 origin, vec3 rd, vec2 anchor, vec2 axis,
        vec2 bend, float height, float width, float max_t, float footprint) {
    if (t < -0.0001 || t > max_t+0.0001) return vec3(1e20,0.0,0.0);
    vec3 p=origin+rd*t;
    float y=p.y-root_light.x;
    if (y<0.0 || y>height) return vec3(1e20,0.0,0.0);
    float h=y/height;
    float side=abs(dot(p.xz-anchor-bend*h*h,axis));
    vec2 normal=vec2(-axis.y,axis.x);
    vec3 plane_normal=normalize(vec3(normal.x,-2.0*dot(bend,normal)*h/height,normal.y));
    float filter_width=max(0.0006,footprint/max(abs(dot(plane_normal,rd)),0.15));
    float half_width=width*(1.0-h)+0.001;
    // Integrate the blade interval over a pixel footprint. Narrow blades
    // contribute proportionally instead of blinking between black and green.
    float coverage=clamp((half_width-side)/filter_width+0.5,0.0,1.0)
        -clamp((-half_width-side)/filter_width+0.5,0.0,1.0);
    if (coverage<0.01) return vec3(1e20,0.0,0.0);
    return vec3(max(t,0.0),coverage,y/1.05);
}

vec3 nearer_blade(vec3 a, vec3 b) {
    return a.x<b.x ? a : b;
}

vec3 cell_intersection(vec3 origin, vec3 rd, ivec2 cell, float max_t, float footprint, float tm) {
    vec3 closest=vec3(1e20,0.0,0.0);
    int radius=grass_neighbourhood(vec3(origin.x,max(origin.y,origin.y+rd.y*max_t),origin.z));
    // Clamp the search before hashing: the neighbouring volume can overlap
    // this ray, but only blades actually rooted in this patch belong here.
    ivec2 lower=max(ivec2(-radius),ivec2(floor(patch.xy/0.12))-cell);
    ivec2 upper=min(ivec2(radius),ivec2(floor(patch.zw/0.12))-cell);
    for (int z=lower.y;z<=upper.y;z++) {
        for (int x=lower.x;x<=upper.x;x++) {
            ivec2 id=cell+ivec2(x,z);
            vec4 rnd=grass_random(id);
            vec2 anchor=(vec2(id)+vec2(0.15)+rnd.xy*0.7)*0.12;
            if (any(lessThan(anchor,patch.xy)) || any(greaterThanEqual(anchor,patch.zw))) continue;
            float height=0.55+0.55*rnd.w;
            vec3 pressure=grass_interaction(anchor);
            if (pressure.z<0.0001 && (abs(x)>1 || abs(z)>1)) continue;
            vec3 centre=vec3(anchor.x,root_light.x,anchor.y);
            float width=0.03+0.018*rnd.y;
            vec3 local_origin=centre+grass_unbend(origin-centre,pressure);
            vec3 local_rd=grass_unbend(rd,pressure);
            // A cheap cylinder encloses the complete curved, filtered blade.
            // Reject ray segments outside it before evaluating wind or solving
            // the quadratic. Work in the unbent frame to retain full length.
            vec3 local_end=local_origin+local_rd*max_t;
            float low_y=min(local_origin.y,local_end.y)-root_light.x;
            float high_y=max(local_origin.y,local_end.y)-root_light.x;
            if (low_y>height || high_y<0.0) continue;
            float along=clamp(dot(anchor-local_origin.xz,local_rd.xz)/max(dot(local_rd.xz,local_rd.xz),1e-12),0.0,max_t);
            vec2 offset=local_origin.xz+local_rd.xz*along-anchor;
            float reach=(0.07+0.036056*abs(wind_strength))*pow(clamp(high_y/height,0.0,1.0),2.0)
                +width+0.001+0.5*footprint/0.15;
            if (dot(offset,offset)>reach*reach) continue;
            vec2 axis=normalize(vec2(rnd.z,rnd.x)*2.0-1.0+vec2(0.0001));
            vec2 normal=vec2(-axis.y,axis.x);
            float gust=sin(dot(anchor,vec2(0.17,0.11))-tm*1.7);
            vec2 bend=axis*(0.045+0.025*rnd.x)+vec2(0.03,0.02)*gust*wind_strength;
            float h=(local_origin.y-root_light.x)/height;
            float dy=local_rd.y/height;
            float bn=dot(bend,normal);
            float qa=-bn*dy*dy;
            float qb=dot(local_rd.xz,normal)-2.0*bn*h*dy;
            float qc=dot(local_origin.xz-anchor,normal)-bn*h*h;
            if (abs(qa)<0.000001) {
                if (abs(qb)>0.000001) closest=nearer_blade(closest,
                    blade_root(-qc/qb,local_origin,local_rd,anchor,axis,bend,height,width,max_t,footprint));
            } else {
                float disc=qb*qb-4.0*qa*qc;
                if (disc>=0.0) {
                    float q=-0.5*(qb+(qb>=0.0?1.0:-1.0)*sqrt(disc));
                    closest=nearer_blade(closest,blade_root(q/qa,local_origin,local_rd,anchor,axis,bend,height,width,max_t,footprint));
                    if (abs(q)>0.000001) closest=nearer_blade(closest,
                        blade_root(qc/q,local_origin,local_rd,anchor,axis,bend,height,width,max_t,footprint));
                }
            }
        }
    }
    return closest;
}

void fragment() {
    // The terrain casts its existing shadows. Re-tracing every blade for
    // each shadow cascade is deliberately excluded from this experiment.
    if (!enabled || shadow_pass > 0.01) discard;
    vec3 rd = normalize(world_exit - CAMERA_POSITION_WORLD);
    vec3 ro = CAMERA_POSITION_WORLD;
    vec3 lo = vec3(patch.x-patch_margin,root_light.x+0.002,patch.y-patch_margin);
    vec3 hi = vec3(patch.z+patch_margin,root_light.x+1.24,patch.w+patch_margin);
    vec3 safe_rd = mix(vec3(0.000001), rd, greaterThan(abs(rd),vec3(0.000001)));
    vec3 a = (lo-ro)/safe_rd;
    vec3 b = (hi-ro)/safe_rd;
    vec3 entry = min(a,b), leave = max(a,b);
    float start = max(max(entry.x,entry.y),max(entry.z,0.0));
    float end = min(min(leave.x,leave.y),leave.z);
    // Stop at opaque geometry. Integrating the blades behind a creature
    // would otherwise paint their coverage over its body.
    float opaque_depth=textureLod(scene_depth,SCREEN_UV,0.0).r;
    vec4 opaque_view=INV_PROJECTION_MATRIX*vec4(SCREEN_UV*2.0-1.0,opaque_depth,1.0);
    if (opaque_depth>0.0) end=min(end,length(opaque_view.xyz/opaque_view.w));
    if (end <= start) discard;
    float tm = clock_override >= 0.0 ? clock_override : TIME;
    float footprint = max(0.0006, 2.0*start/(VIEWPORT_SIZE.y*PROJECTION_MATRIX[1][1]));
    float far_mix = smoothstep(detail_near,detail_far,start);
    // Once blades are unresolved, shade a continuous canopy using the same
    // world field. No repeating ground tile and no dense tracing at horizon.
    // A stable mean height, independent of which proxy exit face was drawn.
    float canopy_height = 0.57;
    float canopy_t = (root_light.x+canopy_height-ro.y)/safe_rd.y;
    vec3 canopy_p = ro+rd*canopy_t;
    bool canopy_valid = canopy_t >= start && canopy_t <= end &&
        all(greaterThanEqual(canopy_p.xz,patch.xy)) && all(lessThan(canopy_p.xz,patch.zw));
    float t = start+0.0001;
    bool hit = false;
    float coverage = 1.0;
    float first_t = 1e20;
    float accumulated = 0.0;
    float shade_sum = 0.0;
    int layers = 0;
    int count = 0;
    if (far_mix < 0.999) {
        for (int i=0; i<128; i++) {
            if (i >= march_steps || t > end) break;
            count = i+1;
            vec3 p = ro+rd*t;
            // The local neighbourhood changes at cell boundaries. An empty
            // margin must not return a long step that jumps over the first
            // rows of blades at a block edge.
            vec2 cell_edge = (floor(p.xz/0.12)+step(vec2(0.0),rd.xz))*0.12;
            vec2 crossing = (cell_edge-p.xz)/safe_rd.xz;
            crossing=mix(vec2(1e20),crossing,greaterThan(abs(rd.xz),vec2(0.000001)));
            footprint=max(0.0006,2.0*t/(VIEWPORT_SIZE.y*PROJECTION_MATRIX[1][1]));
            float cell_step = max(0.0015,min(crossing.x,crossing.y)+0.0002);
            if (analytic_blades) {
                vec3 blade_t=cell_intersection(p,rd,ivec2(floor(p.xz/0.12)),min(cell_step,end-t),footprint,tm);
                if (blade_t.x<1e19) {
                    t+=blade_t.x;
                    if (!composite_edges) { coverage=blade_t.y; hit=true; break; }
                    first_t=min(first_t,t);
                    float weight=(1.0-accumulated)*blade_t.y;
                    float blade_height=clamp(blade_t.z,0.0,1.0);
                    shade_sum+=weight*(0.34+0.66*sqrt(blade_height));
                    accumulated+=weight;
                    layers++;
                    if (accumulated>0.995 || layers>=4) break;
                    // A partial blade edge must reveal the next blade, not
                    // jump straight to the unoccluded bright ground texture.
                    t+=0.001;
                    continue;
                }
                t+=cell_step;
            } else {
                float d=grass_distance(p,tm);
                if (d<min(0.014,footprint*0.35)) { hit=true; break; }
                t+=min(max(d,0.0015),cell_step);
            }
        }
    }
    if (!hit) {
        // Bounded tracing may exhaust its budget between thin blades. The
        // root bed has an analytic intersection, so it never exposes tiled
        // strips or holes as the view changes.
        float ground_t = (root_light.x+0.012-ro.y)/safe_rd.y;
        vec3 ground_p = ro+rd*ground_t;
        if (ground_t >= start && ground_t <= end &&
                all(greaterThanEqual(ground_p.xz,patch.xy)) && all(lessThan(ground_p.xz,patch.zw))) {
            if (composite_edges && analytic_blades) {
                shade_sum+=(1.0-accumulated)*0.41;
                accumulated=1.0;
                first_t=min(first_t,ground_t);
            } else { t=ground_t; hit=true; }
        }
    }
    if (composite_edges && analytic_blades && accumulated>0.0) {
        coverage=accumulated;
        t=first_t;
        hit=true;
    }
    if (canopy_valid && far_mix > 0.0) {
        if (hit) { t = mix(t,canopy_t,far_mix); coverage=mix(coverage,1.0,far_mix); }
        else {
            // Continuous coverage avoids crawling hash patterns in motion.
            coverage=far_mix;
            t = canopy_t;
        }
        hit = true;
    }
    if (debug_bounds) { t=start; hit=true; }
    if (!hit) discard;
    vec3 p = ro+rd*t;
    vec3 view_hit = (VIEW_MATRIX*vec4(p,1.0)).xyz;
    vec4 clip = PROJECTION_MATRIX*vec4(view_hit,1.0);
    DEPTH = clip.z/clip.w;
    ALPHA = coverage;
    LIGHT_VERTEX = view_hit;
    NORMAL = normalize((VIEW_MATRIX*vec4(0.0,1.0,0.0,0.0)).xyz);
    float broad = grass_noise(p.xz*0.055)*0.7 + grass_noise(p.xz*0.23)*0.3;
    float height_shade = mix(0.34+0.66*sqrt(clamp((p.y-root_light.x)/1.05,0.0,1.0)),0.78,far_mix);
    if (composite_edges && analytic_blades && accumulated>0.0)
        height_shade=mix(shade_sum/accumulated,0.78,far_mix);
    // Vertex colours arrive as the source texture's sRGB mean and node tint.
    vec3 base = mix(COLOR.rgb/12.92,pow((COLOR.rgb+0.055)/1.055,vec3(2.4)),
        greaterThan(COLOR.rgb,vec3(0.04045)));
    ALBEDO = base * mix(0.77,1.2,broad) * height_shade;
    ALBEDO *= 1.0-goanna_wetness*0.14;
    ROUGHNESS = 0.9-goanna_wetness*0.15;
    SPECULAR = 0.25;
    BACKLIGHT = ALBEDO*0.3;
    RIM = 0.18;
    RIM_TINT = 0.5;
    AO = root_light.z*root_light.y;
    AO_LIGHT_AFFECT = 0.25;
    EMISSION = ALBEDO*goanna_sky_fill*root_light.y*root_light.z;
    if (debug_iterations) {
        ALBEDO = vec3(0.0);
        EMISSION = vec3(float(count)/float(march_steps),far_mix,0.0);
    }
}
