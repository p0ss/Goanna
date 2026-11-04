# SPDX-License-Identifier: LGPL-2.1-or-later
## Presentation and attack safety for ordinary consumable use. This never
## consumes inventory or sends use packets; the game's normal route owns that.
extends RefCounted

const DURATION := 1.0
var elapsed := DURATION
var kind := ""
var block_until_release := false

func step(delta: float, item_kind: String, primary: bool, secondary: bool,
		secondary_pressed: bool) -> Dictionary:
	elapsed = minf(DURATION, elapsed + maxf(0, delta))
	var using := item_kind != "" and (secondary or secondary_pressed)
	var started := item_kind != "" and secondary_pressed
	if started:
		elapsed = 0
		kind = item_kind
	if using or elapsed < DURATION:
		block_until_release = true
	elif not primary:
		block_until_release = false
	return {"dig": primary and not block_until_release,
		"active": using or elapsed < DURATION,
		"started": started, "kind": kind, "phase": elapsed / DURATION}
