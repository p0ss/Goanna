# SPDX-License-Identifier: LGPL-2.1-or-later
## Keeps capture intent separate from window focus and pointer availability.
## Wayland cannot capture before the pointer has entered the focused window.
extends Node

var requested := false
var focused := false
var inside := false
var blocked: Callable
var apply_mode: Callable
var _last_mode := -1

func _ready() -> void:
	var window := get_window()
	focused = window.has_focus()
	window.focus_entered.connect(focus_changed.bind(true))
	window.focus_exited.connect(focus_changed.bind(false))
	window.mouse_entered.connect(pointer_entered)
	window.mouse_exited.connect(pointer_left)
	refresh()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		# An event delivered by this window also establishes pointer entry when
		# the scene was added after the menu received mouse_entered.
		if focused:
			inside = true
			refresh()

func _process(_delta: float) -> void:
	refresh()

func want_capture(value: bool) -> void:
	requested = value
	refresh()

func focus_changed(value: bool) -> void:
	focused = value
	inside = false
	refresh()

func pointer_entered() -> void:
	inside = true
	refresh()

func pointer_left() -> void:
	# Capture itself may remove the pointer from the ordinary window area.
	if _last_mode != Input.MOUSE_MODE_CAPTURED:
		inside = false
		refresh()

func should_capture() -> bool:
	return requested and focused and inside and not (blocked.is_valid() and blocked.call())

func refresh() -> void:
	var mode := Input.MOUSE_MODE_CAPTURED if should_capture() else Input.MOUSE_MODE_VISIBLE
	if mode == _last_mode and (apply_mode.is_valid() or Input.get_mouse_mode() == mode):
		return
	_last_mode = mode
	if apply_mode.is_valid():
		apply_mode.call(mode)
	else:
		Input.set_mouse_mode(mode)
