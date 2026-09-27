# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends RefCounted

# A launched process and its descendants, never a command-name match.
var pid := -1
var start_time := ""

static func process_start(process_id: int) -> String:
	var path := "/proc/%d/stat" % process_id
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	# procfs reports zero length; read a line rather than using that length.
	var stat := file.get_line()
	var fields := stat.substr(stat.rfind(")") + 2).split(" ", false)
	return fields[19] if fields.size() > 19 else ""

func adopt(process_id: int) -> void:
	pid = process_id
	start_time = process_start(pid) if OS.get_name() == "Linux" else ""

func _descendants(process_id: int, found: Array) -> void:
	var path := "/proc/%d/task/%d/children" % [process_id, process_id]
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	for child in file.get_line().split(" ", false):
		var child_id := int(child)
		var token := process_start(child_id)
		if token.is_empty():
			continue
		_descendants(child_id, found)
		found.append([child_id, token])

func stop() -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Linux":
		if start_time.is_empty() or process_start(pid) != start_time:
			pid = -1
			return
		var children: Array = []
		_descendants(pid, children)
		for child in children:
			if process_start(child[0]) == child[1]:
				OS.kill(child[0])
	if OS.is_process_running(pid) and (OS.get_name() != "Linux" or process_start(pid) == start_time):
		OS.kill(pid)
	pid = -1
