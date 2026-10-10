# Tier implementation checks, 2026-09-27

This is a validation record, not a calibrated performance comparison. The
[contract](../../systems/graphics-tiers.md) describes the revised tier candidates.
The [profile snapshot](profiles.gd.txt) records their values for this check.

The dummy-renderer tests passed:

- [All 25 profile transitions](profiles-test.log): common controlled keys,
  actual setting application, cloud shader uniforms, preserved appearance
  preferences and view-local feature isolation. View and far distance
  getters need a connected session and are excluded from the dummy test's
  actual-value assertions.
- [Feature switches](features-test.log): saved diagnostic settings, lazy
  cloud allocation, per-view toggles and underwater behaviour.
- [Local menu](menu-test.log): Lowest is offered and persists after saving.
- [Material shaders](shaders-test.log): existing shader interface checks.

Benchmark plan consistency, Python syntax, text style and whitespace checks
also passed. No native code changed in this tier implementation.

## Cloud visual check

Three sequential headless Forward+ runs used four local players at
1280x800, on the existing desktop test machine. Each used a disposable copy
of test_world and the circle scene, with players facing each other. These
are sky and distant-world views, not a near-terrain visual acceptance test.

The first candidate used 12 cloud view samples, four cubemap samples and
two sun samples at Lowest. The [image](rejected-coarse.png) showed increased
edge grain. It was rejected after comparing with
[full cloud sampling](full-cloud-reference.png).

The [final Lowest image](lowest-final.png) keeps 24 view samples and eight
cubemap samples, with two sun samples. Its outline retains the smoother
appearance of the reference. All budgets trace the same 88-node sun path;
Low and Medium use three sun samples, High and Ultra use four. This still
needs motion, grazing-angle and sunset review.

The raw smoke recordings and invocation plans are retained alongside the
images. Each recording lasted only three seconds. They are insufficient to
establish a speedup, tier spacing or target-hardware frame rate. The final
and full-cloud GPU medians were essentially the same in this scene. No
performance benefit is claimed from the new cloud control yet.

All owned test clients and servers exited. The disposable copied worlds
and media were removed after preserving the evidence.
