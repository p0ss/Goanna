// Shared between stages. Pulled in through #include "/lib/common.glsl".
#define PROOF_BAND 0.04
float proof_vignette(vec2 uv) {
    vec2 d = uv - vec2(0.5);
    return 1.0 - 0.6 * dot(d, d) * 2.0;
}
