<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Tier baseline, terrain sharing and lamp occlusion

Work in progress. Measurements and conclusions belong in the completed
report; this file records the comparison design.

1. Capture the five existing tiers before implementation changes, with one
   and four players at 1280x800. Record nearby and separated views, radial
   streaming and a night fixture. Use a frozen client and world copy.
2. Share immutable terrain preparation and eligible GPU buffers. Validate
   content changes, missing neighbours, per-view materials and resource
   lifetime. Count actual reuse independently from frame time.
3. Prototype nearby full-block lamp visibility independently of shadow
   maps. Check a wall, an opening and edits, with a restored control.
4. Repeat the tier runs with unchanged preset values, then measure candidate
   adjustments. Add grouped movement to exercise overlapping terrain work.

Each client gets four total mesh workers and a total 4 ms poll budget,
shared between its players. Record 15 seconds per phase after warmup and
terrain settling. Streaming must drain after movement. A timeout is not a
settled result. The night scene's default lamp overrides are replaced with
the selected tier's values.

The captured desktop is not a Steam Deck. Handheld targets remain design
budgets until tested on representative hardware. CPU and GPU timers overlap;
RAM and VRAM are capacity constraints, not additive frame-time components.

The initial matrix is screening evidence. Repeated controls are required
where compilation or other desktop work overlaps a recording, or where
baseline timings drift. No speedup may be assigned from a noisy single pair.
