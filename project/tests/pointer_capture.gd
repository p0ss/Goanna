# SPDX-License-Identifier: LGPL-2.1-or-later
## Focus and pointer-entry sequences without touching the desktop pointer.
extends SceneTree
const Capture := preload("res://input/pointer_capture.gd")
var failures := 0
var modes: Array = []
func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)
func _initialize() -> void:
	var capture := Capture.new()
	capture.apply_mode = func(mode: int) -> void: modes.append(mode)
	var blocked := [true]
	capture.blocked = func() -> bool: return blocked[0]
	capture.want_capture(true)
	check(not capture.should_capture(), "loading while unfocused leaves the cursor visible")
	check(modes.back() == Input.MOUSE_MODE_VISIBLE, "loading applies visible mouse mode")
	capture.focus_changed(true)
	check(not capture.should_capture(), "focus alone cannot establish a Wayland pointer window")
	capture.pointer_entered()
	check(not capture.should_capture(), "loading overlay keeps the cursor visible")
	blocked[0] = false
	capture.refresh()
	check(capture.should_capture(), "play captures after focus, entry and loading")
	check(modes.back() == Input.MOUSE_MODE_CAPTURED, "play applies captured mouse mode")
	capture.focus_changed(false)
	check(not capture.should_capture(), "alt-tab releases capture")
	check(modes.back() == Input.MOUSE_MODE_VISIBLE, "alt-tab applies visible mouse mode")
	blocked[0] = true
	capture.focus_changed(true)
	capture.pointer_entered()
	check(not capture.should_capture(), "returning to a settlement form keeps the cursor visible")
	capture.want_capture(false)
	blocked[0] = false
	capture.refresh()
	check(not capture.should_capture(), "focus changes preserve a UI request to release capture")
	capture.want_capture(true)
	capture.pointer_left()
	check(capture.should_capture(), "capture-induced pointer exit cannot oscillate capture")
	for i in 3:
		capture.focus_changed(false)
		capture.focus_changed(true)
		check(not capture.should_capture(), "repeated alt-tab waits for pointer entry")
		capture.pointer_entered()
		check(capture.should_capture(), "entry restores play capture")
	capture.free()
	print("pointer capture: ", failures, " failures")
	quit(1 if failures else 0)
