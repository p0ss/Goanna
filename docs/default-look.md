# Default look checkpoint

This is work in progress, not an accepted visual overhaul. The first two review passes were rejected for flattened lighting, unreliable comparisons, material artifacts and distant-terrain regressions.

The checkpoint includes daylight grading controls with a protected twilight interval, blue night-sky ambient lighting, bounded atmosphere, dry-bark roughness, aligned stone/brick UVs, explicit emitting-mesh ownership, torch and lantern source placement, corrected roughness decoding and emission-mask colour space, and a shared lamp/shadow budget.

## Current evidence

- [Lamp regression diagnostics](perf/lamp-regressions-2026-09-13/index.html): exterior light leaking through walls caused the wet-looking shadow streaks. The isolated light's shadow map removes them.
- [Lantern room illumination](perf/lantern-room-2026-09-13/index.html): the lanterns cast light inside the room, but the 16-slot pool drops all four from the outside camera. 32 slots restores that view. This diagnostic setting is not a new default.

## Remaining work

The shared light/shadow budget prevents unshadowed point lights shining through walls, but can remove visible room lighting as the camera moves. Admission and distant fallback need further work. Daylight changes are still too slight, distant terrain needs a fully settled panoramic comparison, and close wall-torch hotspots remain strong. The user-valued sunset and rain changes are retained, with no claim that the combined look is finished.

The withdrawn, larger capture sets remain local review scratch rather than committed evidence. They contain rejected or subsequently refreshed comparisons and must not be used to claim success.

## Validation at this checkpoint

`cmake --build build -j3` passed. The headless `project/tests/look_grade.gd` checks passed for twilight/night bypass, disabled strength, monotonicity, curve endpoints and texture reuse. Live checks at 8, 16 and 32 lamp slots confirmed that all admitted lamps have shadows. The current room, wall-torch and village captures recorded zero wetness. No shader or script errors were reported in the final lighting-check run.
