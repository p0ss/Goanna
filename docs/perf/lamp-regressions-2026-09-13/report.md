# Lamp regressions, 13 September 2026

These are diagnostic fixes following the rejected visual review, not a completed default-look overhaul.

[View the diagnostics and current scenes](index.html).

## Confirmed cause of the wet-looking shadows

The exterior torch at Godot position (-67.35, 26.25, 327) illuminated the inside of the room when it had no shadow map. Its light reached the back of the wall; the normal map tilted some texels toward that light, producing bright grooves on wood and flecks on cobblestone. Disabling rain, specular, emission, SDFGI or directional bounce did not remove that source. Enabling its isolated shadow map removed it. Wetness and precipitation were both zero.

The two source-isolation images use one lamp, one frozen camera and the same renderer. They show the cause; they are not whole-scene before/after images. The original shadow pool was separate from the light pool, and visiting different views changed which lamps retained shadows. This made capture history affect the result.

## Changes

- When lamp shadows are enabled, direct-light admission is capped by the shadow budget. Every admitted lamp casts shadows, including during fade-out. The existing stable slot ownership and admission hysteresis remain. The separate shadow-allocation hysteresis was removed. Distant lighting uses the existing propagated block-light fallback.
- The default still budgets 16 shadowed lamps. This changes the village's simultaneous direct lighting; it is a visible tradeoff, not free extra shadow coverage. Setting Shadow casting lamps to zero still explicitly disables shadows. The settings descriptions explain the coupling.
- LabPBR perceptual smoothness now converts to Godot perceptual roughness with `1 - smoothness`, across node, entity, vegetation and glass shaders and the distant material averages. Goanna previously squared that value before Godot squared it again. See the [LabPBR channel definition](https://shaderlabs.org/wiki/LabPBR_Material_Standard) and [Godot 4.5 BRDF implementation](https://github.com/godotengine/godot/blob/4.5-stable/servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl#L206). This is a separate material correction; it was not the cause of the shadow streaks.
- Lantern source positions use the centre of the largest oriented selection box, excluding the chain. In this room they moved from y=33 to y=32.78125, inside the body.
- The inferred emission mask now attenuates linear colour before encoding its texture as sRGB. Previously the sRGB transfer suppressed partially glowing texels again. The mask still excludes the dark housing; the emission-only image checks that the panels glow without direct lamp illumination.

The existing sunset and rain changes were retained. This round made no new grading or atmosphere changes.

## Verification

Native build passed. The night/twilight grading-bypass checks passed. The live Forward+ renderer reported no shader or script errors during these checks. Dry-scene assertions and active-light/shadow assertions passed at budgets 8, 16 and 32. Room, wall-torch and village captures each had 16 active lamps, all shadowed; their JSON records the actual light positions and renderer counters.

The wall-torch shadow on/off pair uses the same source and frozen camera, with other pooled lights hidden. The overhang and ledge block its light with shadows enabled. Its shadow shape differs from the original displaced light; the old offset was not restored.

These close-scene checks waited for active near-mesh work to drain. The village image is a lighting diagnostic, not proof of completed distant-terrain loading or a landscape comparison. Direct screenshots, no external colour edits. The review uses the isolated copy of test_world, leaving the user's world and settings untouched.

## Still unresolved

The follow-up [lantern illumination comparison](../lantern-room-2026-09-13/index.html) confirms that the default 16-slot pool drops all four ceiling lanterns from the exterior village view. Raising the budget to 32 restores them in that view. This remains a known limitation in this checkpoint; the default was not raised.


The daylight treatment remains too slight to justify calling this an overhaul. Distant-terrain shading and atmosphere still need comparable, fully settled panoramic review. The reduced direct-light count needs wider visual assessment, and close wall-torch hotspots remain strong. No claim is made that the full look is finished or accepted.
