# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends SceneTree

const OwnedProcess := preload("res://owned_process.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	_run.call_deferred()

func running(pid: int) -> bool:
	var file := FileAccess.open("/proc/%d/stat" % pid, FileAccess.READ)
	if file == null:
		return false
	var stat := file.get_line()
	return stat.substr(stat.rfind(")") + 2, 1) != "Z"

func _run() -> void:
	if OS.get_name() != "Linux":
		print("owned process: Linux process identity checks skipped")
		quit()
		return
	var owned := OwnedProcess.new()
	var other := OwnedProcess.new()
	owned.adopt(OS.create_process("/bin/sleep", ["20"]))
	other.adopt(OS.create_process("/bin/sleep", ["20"]))
	var first_pid := owned.pid
	var second_pid := other.pid
	check(first_pid > 0 and second_pid > 0, "Test processes start")
	var token := owned.start_time
	check(not token.is_empty(), "Read the process start identity from procfs")
	owned.start_time = "wrong-identity"
	owned.stop()
	check(OwnedProcess.process_start(first_pid) == token, "A reused PID must not be stopped")
	owned.adopt(first_pid)
	owned.stop()
	await create_timer(0.2).timeout
	check(not running(first_pid), "The owned process stops")
	check(running(second_pid), "A different process with the same command survives")
	other.stop()
	await create_timer(0.2).timeout
	check(not running(second_pid), "The second test process is cleaned up")
	print("owned process: %d failures" % failures)
	quit(1 if failures else 0)
