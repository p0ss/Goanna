# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The player agent interface (docs/agents/agent-interfaces.md, section 2): an
# external program observes one connected player and acts as that player,
# with nothing a person at the keyboard does not have.
#
# It shares no dispatcher, eval, method call or other facility with
# control_channel.gd. Every action ends in an input the player already has:
# held movement keys and the dig and place buttons join main.gd's own input
# (main.merge_controls, main.agent_dig, main.agent_place_pressed) ahead of
# step_player and step_interact, so reach, dig times, the window gate, the
# server's privilege and protection checks and its rate limits all apply as
# they do to a person. Inventory clicks go to the open form's own slot
# handlers in ui/game_ui.gd, which send what a mouse click sends. There is no
# teleport, no node query beyond what is on screen, no inventory write and no
# server command.
#
# Local security: opt in with GOANNA_PLAYER_AGENT, loopback only, and every
# request must carry the per launch token written to
# user://player_agent_<port>.token, readable only by the user.
extends Node

const Formspec := preload("res://ui/formspec.gd")

const PROTOCOL := "goanna-player/0.5"
const DEFAULT_PORT := 30850
const MAX_LINE := 1 << 20
const QUERIES := ["hello", "observe", "wait", "action_status"]
const ACTIONS := ["look", "move", "release", "dig", "place", "use", "attack",
	"hotbar", "drop", "inventory_open", "inventory_close", "inventory_click",
	"form_button", "form_field", "form_select", "form_check", "form_scroll",
	"form_action", "respawn", "chat"]
const COMMANDS := ["hello", "observe", "wait", "action_status", "look", "move",
	"release", "dig", "place", "use", "attack", "hotbar", "drop", "inventory_open",
	"inventory_close", "inventory_click", "form_button", "form_field", "form_select",
	"form_check", "form_scroll", "form_action", "respawn", "chat"]
const RESULTS := ["accepted", "completed", "interrupted", "refused", "stale"]
# The movement controls, by the name an agent uses, as main.gd's key names.
const CONTROLS := {"forward": "up", "backward": "down", "left": "left",
	"right": "right", "jump": "jump", "sneak": "sneak", "aux1": "aux1"}
# Body actions need the player in the world, alive and with no window open.
const BODY := ["look", "move", "dig", "place", "use", "attack", "hotbar", "drop"]
# Form actions, by the element types each one works: the formspec type
# names an element was built from (ui/formspec.gd, describe()).
const FORM_TYPES := {
	"form_button": ["button", "button_exit", "image_button", "image_button_exit",
		"item_image_button", "button_url", "button_url_exit"],
	"form_field": ["field", "pwdfield", "textarea"],
	"form_select": ["dropdown", "textlist", "table", "tabheader"],
	"form_check": ["checkbox"],
	"form_scroll": ["scrollbar"],
	"form_action": ["hypertext"],
}
const BUTTONS := {"left": MOUSE_BUTTON_LEFT, "right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE}
const EVENT_LIMIT := 128
const SNAPSHOT_LIMIT := 64
const ACTION_LIMIT := 256
const MAX_HOLD_MS := 30000
const MAX_WAIT_MS := 30000
const MAX_WAIT_TICKS := 600
# Long enough for the server to answer a dig or a place: it puts a predicted
# dig back, or sends the placed node, about one round trip later.
const SETTLE_MS := 1500
const ACTIONS_PER_SECOND := 20
# Below Luanti's default chat_message_limit_per_10sec of 8, so an agent is
# refused here before the server starts counting it towards a kick.
const CHATS_PER_10_SECONDS := 5
const CHAT_MAX := 500
const ENTITY_RADIUS := 32.0
const SAMPLE_RANGE_MAX := 32.0
# Bounds on what a form observation carries.
const MAX_ROWS := 500
const MAX_LABELS := 200
const MAX_TEXT := 4000
const FIELD_MAX := 16384
# Luanti's HUD element types and flags (hud.h), as game_ui.gd draws them.
const HUD_IMAGE := 0
const HUD_TEXT := 1
const HUD_STATBAR := 2
const HUD_INVENTORY := 3
const HUD_WAYPOINT := 4
const HUD_IMAGE_WAYPOINT := 5
const HUD_FLAG_HEALTHBAR := 1 << 1
const HUD_FLAG_BREATHBAR := 1 << 4
const FRAME_WIDTH_MAX := 1280
# Sounds the client makes for the player's own movement and digging, which
# say nothing the observation does not, and would crowd out the rest.
const QUIET_KINDS := ["step", "jump", "dig", "form"]

var main: Node
var _server := TCPServer.new()
var _connections: Array = []
var _port := 0
var _token := ""
var _token_path := ""
var _session := ""
var _sequence := 0
var _snapshots := {}
var _events: Array = []
var _event_cursor := 0
var _last_chat = null
var _actions := {}
var _next_action := 0
var _held := {}           # control name -> action id
var _interaction := 0     # the dig, place, use or attack in progress, or 0
var _action_times: Array = []
var _chat_times: Array = []
var _listening := false

func _ready() -> void:
	var spec := OS.get_environment("GOANNA_PLAYER_AGENT")
	_port = int(spec) if spec.is_valid_int() and int(spec) > 1 else DEFAULT_PORT
	_session = "%x-%x" % [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	if not _write_token():
		push_error("player agent: cannot write the token file, not listening")
		return
	var error := _server.listen(_port, "127.0.0.1")
	if error != OK:
		push_error("player agent: cannot listen on 127.0.0.1:%d (error %d)" % [_port, error])
		return
	print("player agent: %s listening on 127.0.0.1:%d, token in %s"
			% [PROTOCOL, _port, _token_path])

func _exit_tree() -> void:
	_server.stop()
	_release_all("the client is closing")
	if _token_path != "":
		DirAccess.remove_absolute(_token_path)

# A fresh random token for this launch, in a file only this user can read.
# The file is created empty with mode 0600 before the token goes into it, so
# there is no moment when another user could read it.
func _write_token() -> bool:
	_token = Crypto.new().generate_random_bytes(32).hex_encode()
	_token_path = ProjectSettings.globalize_path("user://player_agent_%d.token" % _port)
	DirAccess.make_dir_recursive_absolute(_token_path.get_base_dir())
	if OS.get_name() != "Windows":
		# The path goes in through the environment: Godot does not pass the
		# argument after the script through as $0.
		OS.set_environment("GOANNA_PLAYER_AGENT_TOKEN_PATH", _token_path)
		var code := OS.execute("sh", ["-c",
			'umask 077 && rm -f "$GOANNA_PLAYER_AGENT_TOKEN_PATH" && : > "$GOANNA_PLAYER_AGENT_TOKEN_PATH"'])
		OS.unset_environment("GOANNA_PLAYER_AGENT_TOKEN_PATH")
		if code != 0:
			return false
	var file := FileAccess.open(_token_path, FileAccess.READ_WRITE if OS.get_name() != "Windows" else FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(_token + "\n")
	file.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(_token_path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	return true

func _process(_delta: float) -> void:
	_capture_chat()
	_listen()
	_expire_holds()
	while _server.is_connection_available():
		var peer := _server.take_connection()
		peer.set_no_delay(true)
		_connections.append({"peer": peer, "buffer": ""})
	for connection in _connections.duplicate():
		var peer: StreamPeerTCP = connection.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_connections.erase(connection)
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var received := peer.get_data(available)
			if int(received[0]) == OK:
				connection.buffer += (received[1] as PackedByteArray).get_string_from_utf8()
		var buffer: String = connection.buffer
		var newline := buffer.find("\n")
		while newline >= 0:
			_accept(connection, buffer.substr(0, newline).strip_edges())
			buffer = buffer.substr(newline + 1)
			newline = buffer.find("\n")
		if buffer.length() > MAX_LINE:
			_send(connection, {"ok": false, "error": "line too long"})
			buffer = ""
		connection.buffer = buffer

# --- requests ----------------------------------------------------------------

func _accept(connection: Dictionary, line: String) -> void:
	var request = JSON.parse_string(line)
	if not request is Dictionary:
		_send(connection, {"ok": false, "error": "request must be a JSON object"})
		return
	var reply := {"id": request.get("id", null)}
	if not _token_matches(String(request.get("token", ""))):
		reply.merge({"ok": false, "error": "missing or wrong token: read it from the client's player_agent_<port>.token file"})
		_send(connection, reply)
		return
	var command := String(request.get("cmd", ""))
	var args = request.get("args", {})
	if not args is Dictionary:
		args = {}
	if command not in COMMANDS:
		reply.merge({"ok": false, "error": "command is not available on the player interface"})
		_send(connection, reply)
		return
	match command:
		"hello":
			reply.merge({"ok": true, "result": _hello()})
			_send(connection, reply)
		"observe":
			reply.merge({"ok": true, "result": _observe(args)})
			_send(connection, reply)
		"action_status":
			var rec = _actions.get(_int(args.get("action", 0)), null)
			if rec == null:
				reply.merge({"ok": false, "error": "no such action (only the last %d are kept)" % ACTION_LIMIT})
			else:
				reply.merge({"ok": true, "result": _result(rec)})
			_send(connection, reply)
		"wait":
			_wait(connection, reply, args)
		_:
			_act(connection, reply, command, args)

func _token_matches(given: String) -> bool:
	if _token == "" or given.length() != _token.length():
		return false
	var diff := 0
	for i in _token.length():
		diff |= _token.unicode_at(i) ^ given.unicode_at(i)
	return diff == 0

func _hello() -> Dictionary:
	return {"protocol": PROTOCOL, "session": _session, "subject": _subject(),
		"sequence": _sequence, "tick": Engine.get_process_frames(), "read_only": false,
		"capabilities": {"scope": ["actor"],
			"observations": ["body", "camera", "pointed", "visible_nodes",
				"nearby_entities", "inventory", "window", "form_elements", "hud", "frame", "sounds", "environment", "events",
				"spatial_memory"],
			"actions": ACTIONS, "queries": QUERIES, "results": RESULTS,
			"controls": CONTROLS.keys(),
			"limits": {"max_hold_ms": MAX_HOLD_MS, "max_wait_ms": MAX_WAIT_MS,
				"actions_per_second": ACTIONS_PER_SECOND,
				"chats_per_10_seconds": CHATS_PER_10_SECONDS, "chat_max": CHAT_MAX,
				"observations_kept": SNAPSHOT_LIMIT},
			"director": false},
		"coordinates": "Godot axes: Luanti's x, y and -z, in nodes"}

# --- observing ---------------------------------------------------------------

func _observe(args: Dictionary) -> Dictionary:
	_sequence += 1
	var since := maxi(0, _int(args.get("since_event", 0)))
	var new_events := []
	for event in _events:
		if int(event.cursor) > since:
			new_events.append(event)
	var oldest := int(_events[0].cursor) if not _events.is_empty() else _event_cursor + 1
	var status: Dictionary = main.client.status()
	var position: Vector3 = _body_position()
	var pointed := _pointed_summary(main.pointed)
	var window := _window_state()
	var inventory := _compact_inventory(main.client.inventory_state())
	_snapshots[_sequence] = {"pointed": pointed, "window": window, "inventory": inventory,
		"position": position, "ms": Time.get_ticks_msec()}
	_snapshots.erase(_sequence - SNAPSHOT_LIMIT)
	var out := {"protocol": PROTOCOL, "session": _session, "subject": _subject(),
		"scope": "actor", "sequence": _sequence, "tick": Engine.get_process_frames(),
		"sampled_ms": Time.get_ticks_msec(), "connection": status.get("state", "unknown"),
		"coordinates": "Godot axes: Luanti's x, y and -z, in nodes",
		"body": {"position": position, "health": main.client.hp(),
			"breath": main.client.breath(), "grounded": bool(main.last_move.get("on_ground", false)),
			"in_liquid": bool(main.last_move.get("in_liquid", false)),
			"climbing": bool(main.last_move.get("climbing", false)),
			"velocity": main.last_move.get("speed", Vector3.ZERO),
			"wield_index": main.client.wield_index(), "wield_slot": main.client.wield_index() + 1,
			"wield_item": main.client.wield_item_name(), "hotbar_size": main._hotbar_count()},
		"camera": {"position": main.cam.position, "pitch": main.pitch, "yaw": main.yaw,
			"look_dir": -main.cam.global_transform.basis.z, "fov": main.cam.fov},
		"pointed": pointed,
		"nearby_entities": {"radius": ENTITY_RADIUS, "rule": "in view and in line of sight",
			"seen": _visible_entities(position)},
		"inventory": inventory, "window": window, "hud": _hud(),
		"environment": {"sky": main.client.sky_state(),
			"underwater": main.client.is_underwater(main.cam.position)},
		"held_controls": _held.keys(), "active_actions": _active_actions(),
		"events": new_events, "event_cursor": _event_cursor,
		"events_truncated": since > 0 and since < oldest - 1,
		"spatial_memory": {"current": {"pointed": pointed}, "stale": [],
			"unknown": "all unobserved world state"}}
	var sample = args.get("visible_nodes", null)
	if sample is Dictionary or sample == true:
		out["visible_nodes"] = _visible_nodes(sample if sample is Dictionary else {})
	var frame = args.get("frame", null)
	if frame is Dictionary or frame == true:
		out["frame"] = _frame(frame if frame is Dictionary else {})
	return _plain(out)

# The screen as the player sees it, HUD and open forms included, scaled to
# width pixels (640 by default) and sent as base64 JPEG or PNG. Nothing is
# drawn that the screen does not show. A client with no renderer (--headless)
# has no picture to give.
func _frame(a: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return {"error": "this client draws no picture (no renderer)"}
	var texture := main.get_viewport().get_texture()
	var image: Image = texture.get_image() if texture != null else null
	if image == null or image.is_empty():
		return {"error": "this client draws no picture (no renderer)"}
	var width := clampi(_int(a.get("width", 640)), 64, FRAME_WIDTH_MAX)
	if image.get_width() > width:
		image.resize(width, maxi(1, roundi(float(image.get_height()) * width / image.get_width())),
			Image.INTERPOLATE_BILINEAR)
	var png := String(a.get("format", "jpeg")) == "png"
	if image.get_format() != Image.FORMAT_RGB8:
		image.convert(Image.FORMAT_RGB8)
	var bytes := image.save_png_to_buffer() if png else image.save_jpg_to_buffer(0.85)
	return {"width": image.get_width(), "height": image.get_height(),
		"mime": "image/png" if png else "image/jpeg", "data": Marshalls.raw_to_base64(bytes)}

# Where the player's feet are, as the local player last stepped. The
# client's server_player_position is only the last position the server
# forced, which does not follow walking.
func _body_position() -> Vector3:
	var at = main.last_move.get("pos", null)
	return at if at is Vector3 else main.client.server_player_position()

func _pointed_summary(p: Dictionary) -> Dictionary:
	var out := {"type": String(p.get("type", "nothing"))}
	if out.type == "node":
		out["node"] = p.get("node", Vector3())
		out["above"] = p.get("above", Vector3())
		out["node_name"] = String(p.get("node_name", ""))
		out["digging"] = bool(p.get("digging", false))
		out["progress"] = float(p.get("progress", 0.0))
	elif out.type == "object":
		out["object_id"] = int(p.get("object_id", -1))
		out["object_name"] = String(p.get("object_name", ""))
	# The infotext shown in the corner while it is pointed at.
	if String(p.get("infotext", "")).strip_edges() != "":
		out["infotext"] = _styled(String(p.infotext))
	return out

# What the player could see of each object: in the camera's view and with a
# clear line from the eye to its body or head. The client knows of objects
# behind walls and behind the player, which a person at the screen does not
# see, so those are left out. A walkable node blocks the line, glass and
# leaves included, which hides a little more than a person would miss.
func _visible_entities(_position: Vector3) -> Array:
	var eye: Vector3 = main.cam.global_position
	var seen := []
	for entity in main.client.entity_list():
		if bool(entity.get("local", false)):
			continue
		var at = entity.get("position", null)
		if not at is Vector3 or eye.distance_to(at) > ENTITY_RADIUS:
			continue
		var visible := false
		for lift in [0.5, 1.4]:
			var point: Vector3 = at + Vector3(0, lift, 0)
			if main.cam.is_position_in_frustum(point) and _line_clear(eye, point):
				visible = true
				break
		if visible:
			var one := {"id": entity.get("id", -1), "name": entity.get("name", ""),
				"position": at, "rotation_y": entity.get("rotation_y", 0.0),
				"distance": eye.distance_to(at)}
			# The tag drawn over it. Its infotext shows only when pointed at,
			# so it is in pointed, not here.
			if String(entity.get("nametag", "")).strip_edges() != "":
				one["nametag"] = _styled(String(entity.nametag))
			seen.append(one)
	return seen

func _line_clear(from: Vector3, to: Vector3) -> bool:
	var length := from.distance_to(to)
	var dir := (to - from) / maxf(length, 0.001)
	var d := 0.3
	while d < length - 0.5:
		if main.client.node_walkable_at(from + dir * d):
			return false
		d += 0.25
	return true

# The first node each of a grid of rays through the screen meets: the
# surfaces on screen, which is what the player sees of the world. Rays stop
# at an unloaded node ("ignore") and report nothing there.
func _visible_nodes(a: Dictionary) -> Dictionary:
	var columns := clampi(_int(a.get("columns", 9)), 1, 24)
	var rows := clampi(_int(a.get("rows", 7)), 1, 16)
	var reach := clampf(float(a.get("range", 16.0)), 1.0, SAMPLE_RANGE_MAX)
	var size: Vector2 = main.get_viewport().get_visible_rect().size
	var origin: Vector3 = main.cam.global_position
	var hits := {}
	for row in rows:
		for column in columns:
			var screen := Vector2((column + 0.5) / columns * size.x, (row + 0.5) / rows * size.y)
			var hit := _cast(origin, main.cam.project_ray_normal(screen), reach)
			if not hit.is_empty():
				hits[hit.node] = hit
	return {"columns": columns, "rows": rows, "range": reach, "nodes": hits.values()}

func _cast(origin: Vector3, dir: Vector3, reach: float) -> Dictionary:
	# Nodes are centred on whole numbers, so cell boundaries are at halves.
	var o := origin + Vector3(0.5, 0.5, 0.5)
	var cell := Vector3i(floori(o.x), floori(o.y), floori(o.z))
	var step := Vector3i(int(signf(dir.x)), int(signf(dir.y)), int(signf(dir.z)))
	var t_max := Vector3.ZERO
	var t_delta := Vector3.ZERO
	for axis in 3:
		if dir[axis] == 0.0:
			t_max[axis] = INF
			t_delta[axis] = INF
		else:
			var edge: float = cell[axis] + (1.0 if dir[axis] > 0.0 else 0.0)
			t_max[axis] = (edge - o[axis]) / dir[axis]
			t_delta[axis] = absf(1.0 / dir[axis])
	var t := 0.0
	# The eye's own medium, water under water, is looked through rather than
	# at: its source and flowing nodes share a name up to the last "_".
	var medium := _medium(main.client.node_name_at(Vector3(cell)))
	var first := true
	while t <= reach:
		if not first:
			var name: String = main.client.node_name_at(Vector3(cell))
			if name == "ignore" or name == "":
				return {}
			if name != "air" and _medium(name) != medium:
				return {"node": cell, "name": name, "distance": snappedf(t, 0.01)}
		first = false
		var axis := 0
		if t_max.y < t_max[axis]:
			axis = 1
		if t_max.z < t_max[axis]:
			axis = 2
		t = t_max[axis]
		t_max[axis] += t_delta[axis]
		cell[axis] += step[axis]
	return {}

static func _medium(name: String) -> String:
	if name == "air" or name.rfind("_") < name.find(":"):
		return name
	return name.substr(0, name.rfind("_"))

# The open window as the player sees it: what kind it is, and for a form,
# the slots on screen with what is in them, and the stack on the cursor.
func _window_state() -> Dictionary:
	var ui = main.ui
	if ui == null:
		return {"kind": "none"}
	var out := {"kind": _window_kind(), "chat_open": bool(ui.chat_open)}
	if ui.window == null or ui.window != ui.form:
		return out
	out["formname"] = String(ui.form.formname)
	var lists := {}
	for s in ui.form.describe()["slots"]:
		if not s["visible"]:
			continue
		var key := "%s|%s" % [s["location"], s["listname"]]
		if not lists.has(key):
			lists[key] = {"location": s["location"], "list": s["listname"], "slots": []}
		var item: Dictionary = s["item"] if s["item"] is Dictionary else {}
		var entry := {"index": s["index"]}
		if String(item.get("name", "")) != "":
			entry["item"] = String(item["name"])
			entry["count"] = int(item.get("count", 1))
		(lists[key]["slots"] as Array).append(entry)
	out["lists"] = lists.values()
	out["cursor"] = _cursor()
	out["allow_close"] = bool(ui.form.allow_close)
	out["elements"] = _form_elements()
	out["labels"] = _form_labels()
	return out

# The named elements on screen, each as the player sees it: its formspec
# type, its caption or text, and what can be done with it. Hidden ones and
# ones scrolled out of view are left out, as with slots.
func _form_elements() -> Array:
	var form = main.ui.form
	var out := []
	for e in form.describe()["elements"]:
		if not e["visible"]:
			continue
		var c: Control = e["control"]
		var entry := {"name": String(e["name"]), "type": String(e["type"])}
		if String(e["tooltip"]) != "":
			entry["tooltip"] = _plain_text(form.strip_enriched(String(e["tooltip"])))
		if c is BaseButton:
			entry["disabled"] = (c as BaseButton).disabled
		if c is CheckBox:
			entry["text"] = (c as CheckBox).text
			entry["checked"] = (c as CheckBox).button_pressed
		elif c is OptionButton:
			var ob := c as OptionButton
			entry["items"] = range(ob.item_count).map(func(i: int) -> String: return ob.get_item_text(i))
			entry["selected"] = ob.selected + 1
		elif c is Button:
			var caption := _styled(String(c.get_meta("label", (c as Button).text)))
			entry["text"] = caption.text
			if caption.has("spans"):
				entry["spans"] = caption.spans
		elif c is LineEdit:
			var le := c as LineEdit
			# The player's own typing, but not a password echoed back.
			entry["text"] = "" if le.secret else le.text
			entry["editable"] = le.editable
			if le.secret:
				entry["secret"] = true
				entry["length"] = le.text.length()
		elif c is TextEdit:
			entry["text"] = (c as TextEdit).text
			entry["editable"] = (c as TextEdit).editable
		elif c is TabBar:
			var tb := c as TabBar
			entry["tabs"] = range(tb.tab_count).map(func(i: int) -> String: return tb.get_tab_title(i))
			entry["selected"] = tb.current_tab + 1
		elif c is ItemList:
			var il := c as ItemList
			entry["items"] = range(il.item_count).map(func(i: int) -> String: return il.get_item_text(i))
			var picked: Array = Array(il.get_selected_items())
			entry["selected"] = int(picked[0]) + 1 if not picked.is_empty() else 0
		elif c is Tree:
			entry["rows"] = _table_rows(c as Tree)
			var item := (c as Tree).get_selected()
			entry["selected"] = int(item.get_meta("row", 0)) if item != null else 0
		elif c is ScrollBar:
			var bar := c as ScrollBar
			entry["value"] = int(bar.value)
			entry["min"] = int(bar.min_value)
			entry["max"] = int(bar.max_value)
		elif c is RichTextLabel:
			entry["text"] = (c as RichTextLabel).get_parsed_text()
			if c.has_meta("markup"):
				entry["spans"] = Formspec.markup_spans(c)
				entry["actions"] = form.hypertext_actions(c).map(func(a: Dictionary) -> Dictionary:
					var link := {"action": a["name"], "text": a["text"]}
					if String(a["url"]) != "":
						link["url"] = a["url"]
					return link)
		elif c is Label:
			entry["text"] = (c as Label).text
		out.append(entry)
	return out

# A table's rows as the player sees them: the row number it sends, and the
# text of each column. Rows inside a collapsed tree row are not on screen.
func _table_rows(t: Tree) -> Array:
	var rows := []
	var item := t.get_root()
	while item != null and rows.size() < MAX_ROWS:
		if item != t.get_root() or not t.hide_root:
			var cells := []
			for column in t.columns:
				cells.append(item.get_text(column))
			rows.append({"row": int(item.get_meta("row", 0)), "cells": cells})
		item = item.get_next_visible()
	return rows

# Text on the form that belongs to no named element: label[], vertlabel[],
# unnamed textareas. Captions are reported with their buttons.
func _form_labels() -> Array:
	var form = main.ui.form
	var out := []
	var stack: Array = [form.root] if form.root != null else []
	while not stack.is_empty() and out.size() < MAX_LABELS:
		var n: Node = stack.pop_back()
		var children := n.get_children()
		children.reverse()
		for child in children:
			if child is BaseButton or child.has_meta("formspec_name"):
				continue
			stack.append(child)
		if n == form.root or not (n is Label or n is RichTextLabel):
			continue
		var text: String = (n as Label).text if n is Label else (n as RichTextLabel).get_parsed_text()
		if text.strip_edges() != "" and form.shown_rect(n).has_area():
			var label := _styled(String(n.get_meta("enriched", text)).left(MAX_TEXT))
			if n.has_meta("markup"):
				label["spans"] = Formspec.markup_spans(n)
			out.append(label)
	return out

# Text as {text}, and with spans, each a run of text with its colour, when
# escapes colour any of it, as core.colorize does: the colours are what the
# player is shown.
func _styled(raw: String) -> Dictionary:
	var runs: Array = Formspec.parse_enriched_runs(raw, Color.WHITE)
	var out := {"text": "".join(runs.map(func(r: Dictionary) -> String: return r.text))}
	if raw.contains("\u001b(c@"):
		out["spans"] = runs.map(func(r: Dictionary) -> Dictionary:
			return {"text": r.text, "color": "#" + (r.color as Color).to_html(false)})
	return out

# The HUD as game_ui.gd draws it: the server's text, images, status bars,
# inventory strips and the waypoints in front of the camera. Hidden bars are
# left out, as are a compass and a minimap, which Goanna does not draw. The
# hotbar is in body and inventory.
func _hud() -> Array:
	var st: Dictionary = main.client.hud_state()
	var flags := int(st.get("flags", 0xffff))
	var out := []
	for e in st.get("elements", []):
		var type := int(e.get("type", -1))
		var one := {"id": int(e.get("id", 0)), "position": e.get("pos", Vector2()),
			"offset": e.get("offset", Vector2()), "z_index": int(e.get("z_index", 0))}
		match type:
			HUD_TEXT:
				if String(e.get("text", "")).strip_edges() == "":
					continue
				var n := int(e.get("number", 0xffffff))
				var colour := Color8(n >> 16 & 0xff, n >> 8 & 0xff, n & 0xff)
				var runs: Array = Formspec.parse_enriched_runs(String(e.text), colour)
				one["type"] = "text"
				one["text"] = "".join(runs.map(func(r: Dictionary) -> String: return r.text))
				one["spans"] = runs.map(func(r: Dictionary) -> Dictionary:
					return {"text": r.text, "color": "#" + (r.color as Color).to_html(false)})
			HUD_IMAGE:
				if String(e.get("text", "")) == "":
					continue
				one["type"] = "image"
				one["image"] = String(e.text)
				one["scale"] = e.get("scale", Vector2.ONE)
			HUD_STATBAR:
				var bar := String(e.get("name", ""))
				if (bar == "health" and not flags & HUD_FLAG_HEALTHBAR) \
						or (bar == "breath" and not flags & HUD_FLAG_BREATHBAR):
					continue
				one["type"] = "statbar"
				one["name"] = bar
				one["image"] = String(e.get("text", ""))
				one["value"] = int(e.get("number", 0))
				one["max"] = int(e.get("item", 0))
			HUD_INVENTORY:
				one["type"] = "inventory"
				one["list"] = String(e.get("text", ""))
				one["count"] = int(e.get("number", 0))
			HUD_WAYPOINT, HUD_IMAGE_WAYPOINT:
				var wp = _waypoint(e)
				if wp == null:
					continue
				one.merge(wp)
			_:
				continue
		out.append(one)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.z_index < b.z_index)
	return out

# A waypoint as the screen shows it: only while in front of the camera, at
# its place on the screen (0 to 1 across and down), with the distance as
# drawn and the look that would centre it. Its exact coordinates are not
# shown to a person, so they are not given here.
func _waypoint(e: Dictionary) -> Variant:
	var at: Vector3 = e.get("world_pos", Vector3())
	if main.cam.is_position_behind(at):
		return null
	var size: Vector2 = main.get_viewport().get_visible_rect().size
	var screen: Vector2 = main.cam.unproject_position(at) / size
	var d: Vector3 = at - main.cam.global_position
	var out := {"type": "waypoint" if int(e.type) == HUD_WAYPOINT else "image_waypoint",
		"name": String(e.get("name", "")), "screen": screen,
		"on_screen": Rect2(0, 0, 1, 1).has_point(screen),
		"look": {"yaw": rad_to_deg(atan2(-d.x, -d.z)),
			"pitch": rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length()))}}
	if int(e.type) == HUD_IMAGE_WAYPOINT:
		out["image"] = String(e.get("text", ""))
	elif String(e.get("text", "")) != "-":
		out["distance"] = int(d.length())
		out["unit"] = String(e.text) if String(e.text) != "" else "m"
	return out

func _cursor() -> Dictionary:
	var selected: Dictionary = main.ui.selected
	if selected.is_empty():
		return {}
	return {"item": String(selected.get("name", "")), "count": int(selected.get("amount", 0)),
		"from": "%s|%s|%d" % [selected.get("location", ""), selected.get("listname", ""),
			int(selected.get("index", 0))]}

func _window_kind() -> String:
	var ui = main.ui
	if ui.window == null:
		return "none"
	if ui.window == ui.form:
		return "inventory" if ui.form_is_inventory else "form"
	for kind in ["pause_menu", "death_screen", "settings_menu"]:
		if ui.get(kind) == ui.window:
			return kind
	return "menu"

func _compact_inventory(raw: Dictionary) -> Dictionary:
	var out := {"version": raw.get("version", 0), "lists": {}}
	for list_name in raw.get("lists", {}):
		var source: Array = raw.lists[list_name]
		var items := []
		for slot in source.size():
			var item = source[slot]
			if item is Dictionary and (int(item.get("count", 0)) > 0 or String(item.get("name", "")) != ""):
				var entry := {"slot": slot, "name": String(item.get("name", "")),
					"count": int(item.get("count", 0)), "wear": int(item.get("wear", 0))}
				if item.has("description"):
					entry["description"] = _plain_text(String(item.description))
				if item.has("stack_max"):
					entry["stack_max"] = int(item.stack_max)
				items.append(entry)
		out.lists[list_name] = {"size": source.size(), "items": items}
	return out

# Text as the player reads it: Luanti's colour and translation escapes
# (ESC followed by a bracketed argument, or by one letter) taken out.
static var _escapes := RegEx.create_from_string("\\x{1b}(\\([^)]*\\)|.)")
static func _plain_text(text: String) -> String:
	return _escapes.sub(text, "", true)

func _item_counts(inventory: Dictionary) -> Dictionary:
	var counts := {}
	for list_name in inventory.get("lists", {}):
		for item in inventory.lists[list_name].items:
			var name := String(item.get("name", ""))
			if name != "":
				counts[name] = int(counts.get(name, 0)) + int(item.get("count", 0))
	return counts

func _inventory_change(before: Dictionary, after: Dictionary) -> Dictionary:
	var a := _item_counts(before)
	var b := _item_counts(after)
	var change := {}
	for name in a.keys() + b.keys():
		var d := int(b.get(name, 0)) - int(a.get(name, 0))
		if d != 0:
			change[name] = d
	return change

# --- events ------------------------------------------------------------------

func _push_event(event: Dictionary) -> void:
	_event_cursor += 1
	event["cursor"] = _event_cursor
	event["tick"] = Engine.get_process_frames()
	_events.append(event)
	while _events.size() > EVENT_LIMIT:
		_events.pop_front()

# game_ui keeps the last few chat lines and drops the oldest, so new lines
# are the ones after the last one this channel saw.
func _capture_chat() -> void:
	if main == null or main.ui == null:
		return
	var lines: Array = main.ui.chat_lines
	var start := 0
	if _last_chat != null:
		start = lines.size()
		for i in range(lines.size() - 1, -1, -1):
			if is_same(lines[i], _last_chat):
				break
			start = i
	for i in range(start, lines.size()):
		_push_event({"kind": "chat", "text": _plain_text(String(lines[i].get("text", "")))})
	if not lines.is_empty():
		_last_chat = lines[lines.size() - 1]

# Every sound the client plays reaches ui/audio.gd's played signal, before
# the player's own volume and mute, as it would reach a person's ears. Each
# becomes a sound event: what it is, how loud it was played, whether it loops,
# and for one in the world the look that would face it and its distance in
# whole nodes. Its exact place is not given; a person hears a direction and
# roughly how far.
func _listen() -> void:
	if _listening or main == null or main.ui == null or main.ui.get("audio") == null:
		return
	main.ui.audio.played.connect(_on_sound)
	_listening = true

func _on_sound(info: Dictionary) -> void:
	var kind := String(info.get("kind", ""))
	if kind in QUIET_KINDS:
		return
	var event := {"kind": "sound", "sound": String(info.get("name", "")),
		"source": "server" if kind == "" else kind,
		"gain": snappedf(float(info.get("gain", 1.0)), 0.01), "loop": bool(info.get("loop", false))}
	var at = info.get("position", null)
	if at is Vector3:
		var d: Vector3 = at - main.cam.global_position
		event["distance"] = roundi(d.length())
		event["look"] = {"yaw": roundf(rad_to_deg(atan2(-d.x, -d.z))),
			"pitch": roundf(rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length())))}
	else:
		event["local"] = true
	_push_event(event)

# --- actions -----------------------------------------------------------------

func _act(connection: Dictionary, reply: Dictionary, kind: String, args: Dictionary) -> void:
	_next_action += 1
	var rec := {"id": _next_action, "kind": kind, "based_on": _int(args.based_on) if _is_int(args.get("based_on", null)) else null,
		"status": "accepted", "reason": "", "effects": {}, "started_ms": Time.get_ticks_msec(),
		"finished_ms": 0, "cancel": false}
	_actions[rec.id] = rec
	_actions.erase(rec.id - ACTION_LIMIT)
	var problem := _check(kind, args)
	if not problem.is_empty():
		_finish(rec, problem.status, problem.reason, problem.get("effects", {}))
	else:
		_run(rec, kind, args)
	# Hold-until-released movement, and anything sent with wait false,
	# answers at once; the rest answer when they end.
	var answer_now := not bool(args.get("wait", true)) \
			or (kind == "move" and not args.has("duration_ms"))
	while not answer_now and rec.status == "accepted":
		await get_tree().process_frame
	reply.merge({"ok": true, "result": _result(rec)})
	_send(connection, reply)

# Why an action cannot be tried at all, or {} when it can.
func _check(kind: String, args: Dictionary) -> Dictionary:
	var now := Time.get_ticks_msec()
	while not _action_times.is_empty() and now - int(_action_times[0]) > 1000:
		_action_times.pop_front()
	if _action_times.size() >= ACTIONS_PER_SECOND:
		return {"status": "refused", "reason": "more than %d actions a second" % ACTIONS_PER_SECOND}
	_action_times.append(now)
	if kind == "release":
		return {}   # stopping is always allowed
	if not args.has("based_on") or not _is_int(args.based_on):
		return {"status": "refused", "reason": "based_on, the sequence of the observation this action was decided on, is required"}
	var based_on := _int(args.based_on)
	if based_on > _sequence or based_on < 1:
		return {"status": "refused", "reason": "based_on %d is not an observation this session made (last is %d)" % [based_on, _sequence]}
	if not _snapshots.has(based_on):
		return {"status": "stale", "reason": "observation %d is too old (the last %d are kept); observe again" % [based_on, SNAPSHOT_LIMIT]}
	if String(main.client.status().get("state", "")) != "ready" or not main.placed:
		return {"status": "refused", "reason": "the player is not in a world"}
	if kind in BODY:
		if main.client.hp() <= 0:
			return {"status": "refused", "reason": "the player is dead"}
		if main.ui != null and main.ui.blocks_input():
			return {"status": "refused", "reason": "a window or chat is open (%s); close it first" % _window_kind()}
		if main.fly_mode:
			return {"status": "refused", "reason": "the free camera is on"}
	if kind == "respawn" and (main.ui == null or main.ui.window == null
			or main.ui.window != main.ui.death_screen):
		return {"status": "refused", "reason": "the death screen is not showing"}
	if FORM_TYPES.has(kind):
		var problem := _check_form(kind, args, based_on)
		if not problem.is_empty():
			return problem
	var observed: Dictionary = _snapshots[based_on]
	var then: Dictionary = observed.pointed
	var now_pointed := _pointed_summary(main.pointed)
	match kind:
		"dig", "place":
			if then.type != "node":
				return {"status": "refused", "reason": "observation %d pointed at %s, not a node within reach" % [based_on, then.type]}
			if not _same_node(then, now_pointed, kind == "place"):
				return {"status": "stale", "reason": "the crosshair is no longer on the node observed",
					"effects": {"observed": then, "now": now_pointed}}
		"attack":
			if then.type != "object":
				return {"status": "refused", "reason": "observation %d pointed at %s, not an entity within reach" % [based_on, then.type]}
			if now_pointed.type != "object" or now_pointed.object_id != then.object_id:
				return {"status": "stale", "reason": "the crosshair is no longer on the entity observed",
					"effects": {"observed": then, "now": now_pointed}}
		"use":
			if then.type != now_pointed.type or (then.type == "node" and not _same_node(then, now_pointed, true)) \
					or (then.type == "object" and then.object_id != now_pointed.object_id):
				return {"status": "stale", "reason": "the crosshair is no longer on what was observed",
					"effects": {"observed": then, "now": now_pointed}}
	if kind in ["dig", "place", "use", "attack"] and _interaction != 0:
		return {"status": "refused", "reason": "action %d is still using the buttons; wait for it or release" % _interaction}
	return {}

# A form action is tried only on an element the player can see and use now,
# and only if it is as the observation showed it.
func _check_form(kind: String, a: Dictionary, based_on: int) -> Dictionary:
	if main.ui == null or main.ui.window != main.ui.form:
		return {"status": "refused", "reason": "no form is open (%s)" % _window_kind()}
	var name := String(a.get("name", ""))
	var now := _element(_window_state(), name)
	if now.is_empty():
		return {"status": "refused", "reason": "the open form shows no element named '%s'; it may be hidden or scrolled out of view" % name}
	if String(now.type) not in FORM_TYPES[kind]:
		return {"status": "refused", "reason": "'%s' is a %s; %s works %s" % [name, now.type, kind,
			", ".join(FORM_TYPES[kind])]}
	if bool(now.get("disabled", false)):
		return {"status": "refused", "reason": "'%s' is disabled" % name}
	if not bool(now.get("editable", true)):
		return {"status": "refused", "reason": "'%s' is read only" % name}
	var observed: Dictionary = _snapshots[based_on].window
	if String(observed.get("formname", "")) != String(main.ui.form.formname):
		return {"status": "stale", "reason": "a different form is open than the one observed",
			"effects": {"observed": observed.get("formname", null), "now": main.ui.form.formname}}
	var then := _element(observed, name)
	if then != now:
		return {"status": "stale", "reason": "'%s' changed since the observation" % name,
			"effects": {"observed": then, "now": now}}
	return {}

func _element(window: Dictionary, name: String) -> Dictionary:
	for e in window.get("elements", []):
		if e.name == name:
			return e
	return {}

func _same_node(a: Dictionary, b: Dictionary, face: bool) -> bool:
	if a.type != "node" or b.type != "node":
		return false
	if a.node != b.node or a.node_name != b.node_name:
		return false
	return not face or a.above == b.above

func _run(rec: Dictionary, kind: String, args: Dictionary) -> void:
	match kind:
		"look": await _look(rec, args)
		"move": await _move(rec, args)
		"release": _release(rec, args)
		"dig": await _dig(rec, args)
		"place", "use": await _place(rec, args)
		"attack": await _attack(rec, args)
		"hotbar": await _hotbar(rec, args)
		"drop": await _drop(rec, args)
		"inventory_open": await _inventory_open(rec)
		"inventory_close": await _inventory_close(rec)
		"inventory_click": await _inventory_click(rec, args)
		"form_button", "form_field", "form_select", "form_check", "form_scroll", \
				"form_action":
			await _form(rec, kind, args)
		"respawn": await _respawn(rec)
		"chat": _chat(rec, args)

func _finish(rec: Dictionary, status: String, reason := "", effects := {}) -> void:
	if rec.status != "accepted":
		return
	rec.status = status
	rec.reason = reason
	rec.effects.merge(effects, true)
	rec.finished_ms = Time.get_ticks_msec()
	if _interaction == rec.id:
		_interaction = 0
	_push_event({"kind": "action", "action": rec.id, "action_kind": rec.kind,
		"status": status, "reason": reason})

func _result(rec: Dictionary) -> Dictionary:
	return _plain({"protocol": PROTOCOL, "session": _session, "subject": _subject(),
		"scope": "actor", "action": rec.id, "kind": rec.kind, "based_on": rec.based_on,
		"status": rec.status, "reason": rec.reason, "effects": rec.effects,
		"sequence": _sequence, "tick": Engine.get_process_frames(),
		"elapsed_ms": (rec.finished_ms if rec.finished_ms > 0 else Time.get_ticks_msec()) - rec.started_ms})

func _active_actions() -> Array:
	var out := []
	for id in _actions:
		if _actions[id].status == "accepted":
			out.append({"action": id, "kind": _actions[id].kind})
	return out

# Settle for at least ms and at least `frames` frames: a client rendering
# on the CPU may draw one frame a second.
func _settle(ms: int, frames := 3) -> void:
	var until := Time.get_ticks_msec() + ms
	var n := 0
	while Time.get_ticks_msec() < until or n < frames:
		await get_tree().process_frame
		n += 1

# Why a held action has to stop now, or "".
func _broken() -> String:
	if String(main.client.status().get("state", "")) != "ready":
		return "the connection is not ready"
	if main.client.hp() <= 0:
		return "the player died"
	if main.ui != null and main.ui.blocks_input():
		return "a window or chat opened"
	return ""

func _look(rec: Dictionary, a: Dictionary) -> void:
	if not (a.has("pitch") or a.has("yaw") or a.has("turn_pitch") or a.has("turn_yaw")):
		_finish(rec, "refused", "look wants pitch and or yaw (degrees), or turn_pitch and or turn_yaw")
		return
	var pitch := float(a.get("pitch", main.pitch)) + float(a.get("turn_pitch", 0.0))
	var yaw := float(a.get("yaw", main.yaw)) + float(a.get("turn_yaw", 0.0))
	main.pitch = clampf(pitch, -89.0, 89.0)
	main.yaw = fposmod(yaw + 180.0, 360.0) - 180.0
	# Two frames: one for main.gd to point the camera, one for step_interact
	# to cast from it.
	await _settle(0, 2)
	_finish(rec, "completed", "", {"pitch": main.pitch, "yaw": main.yaw,
		"pointed": _pointed_summary(main.pointed)})

func _move(rec: Dictionary, a: Dictionary) -> void:
	var names = a.get("controls", [a.get("control", "")])
	if not names is Array or names.is_empty():
		_finish(rec, "refused", "move wants control or controls: %s" % ", ".join(CONTROLS.keys()))
		return
	for name in names:
		if not CONTROLS.has(String(name)):
			_finish(rec, "refused", "no control called '%s'; they are %s" % [name, ", ".join(CONTROLS.keys())])
			return
	var duration := -1
	if a.has("duration_ms"):
		duration = _int(a.duration_ms)
		if duration < 1 or duration > MAX_HOLD_MS:
			_finish(rec, "refused", "duration_ms is 1 to %d; leave it out to hold until release" % MAX_HOLD_MS)
			return
	# A control already held by another move passes to this one, and that
	# move ends.
	for name in names:
		if _held.has(name):
			var old: Dictionary = _actions.get(_held[name], {})
			if not old.is_empty():
				_end_hold(old, "interrupted", "replaced by action %d" % rec.id)
	var from: Vector3 = _body_position()
	rec["controls"] = names
	rec["from"] = from
	for name in names:
		_held[String(name)] = rec.id
	if duration < 0:
		return   # held until a release, a window, death or a later move
	rec["until_ms"] = Time.get_ticks_msec() + duration

# The timed holds, checked every frame; and every hold ends when the player
# could not be pressing keys.
func _expire_holds() -> void:
	if _held.is_empty():
		return
	var broken := _broken() if main != null and main.client != null else "no client"
	var now := Time.get_ticks_msec()
	for id in _held.values().duplicate():
		var rec: Dictionary = _actions.get(id, {})
		if rec.is_empty() or rec.status != "accepted":
			_drop_holds(id)
		elif broken != "":
			_end_hold(rec, "interrupted", broken)
		elif rec.has("until_ms") and now >= int(rec.until_ms):
			_end_hold(rec, "completed", "")

func _end_hold(rec: Dictionary, status: String, reason: String) -> void:
	_drop_holds(rec.id)
	var to: Vector3 = _body_position()
	_finish(rec, status, reason, {"from": rec.get("from", to), "to": to,
		"distance": to.distance_to(rec.get("from", to))})

func _drop_holds(id: int) -> void:
	for name in _held.keys():
		if _held[name] == id:
			_held.erase(name)

func merge_controls(keys: Dictionary) -> void:
	for name in _held:
		keys[CONTROLS[name]] = true

# Let go. Releasing a control ends the move that holds it, and that lets go
# of every control the move held: all of them are reported.
func _release(rec: Dictionary, a: Dictionary) -> void:
	var what := String(a.get("control", "all"))
	if what != "all" and what != "buttons" and not CONTROLS.has(what):
		_finish(rec, "refused", "release wants all, buttons, or a control: %s" % ", ".join(CONTROLS.keys()))
		return
	var ending := []
	for name in _held:
		if (what == "all" or name == what) and int(_held[name]) not in ending:
			ending.append(int(_held[name]))
	var released := []
	for id in ending:
		for name in _held:
			if int(_held[name]) == id:
				released.append(name)
		var held: Dictionary = _actions.get(id, {})
		if held.is_empty():
			_drop_holds(id)
		else:
			_end_hold(held, "completed", "released by action %d" % rec.id)
	if (what == "all" or what == "buttons") and _interaction != 0:
		_actions[_interaction].cancel = true
		released.append("buttons")
	_finish(rec, "completed", "", {"released": released})

func _release_all(reason: String) -> void:
	for id in _held.values().duplicate():
		var rec: Dictionary = _actions.get(id, {})
		if not rec.is_empty():
			_end_hold(rec, "interrupted", reason)
	_held.clear()
	if main != null:
		main.agent_dig = false
		main.agent_place = false
		main.agent_place_pressed = false

# Hold dig on the pointed node until it breaks, then let go, so the hold
# does not run on into the node behind it. The client predicts the break;
# a server that refuses it (no interact, protection, out of reach) sends the
# node back, so the result waits SETTLE_MS to see which.
func _dig(rec: Dictionary, a: Dictionary) -> void:
	_interaction = rec.id
	var target := _pointed_summary(main.pointed)
	var max_ms := clampi(_int(a.get("max_ms", 15000)), 100, MAX_HOLD_MS)
	var name_before: String = target.node_name
	var before := _compact_inventory(main.client.inventory_state())
	var start := Time.get_ticks_msec()
	main.agent_dig = true
	var outcome := ""
	while true:
		await get_tree().process_frame
		# The break shows either in the map or in the pointed thing, which
		# step_interact names after its prediction; a server that refuses
		# can put the node back before this looks at the map.
		var now := _pointed_summary(main.pointed)
		var on_target: bool = now.type == "node" and now.node == target.node
		if main.client.node_name_at(target.node) != name_before \
				or (on_target and now.node_name != name_before):
			break
		var broken := _broken()
		if broken != "":
			outcome = broken
		elif rec.cancel:
			outcome = "released"
		elif not on_target:
			outcome = "the crosshair left the node"
		elif Time.get_ticks_msec() - start > max_ms:
			outcome = "the node did not break within %d ms; this tool may not dig it" % max_ms
		if outcome != "":
			break
	main.agent_dig = false
	var effects := {"node": target.node, "node_name": name_before,
		"progress": float(main.pointed.get("progress", 0.0))}
	if outcome != "":
		effects["pointed_now"] = _pointed_summary(main.pointed)
		_finish(rec, "interrupted", outcome, effects)
		return
	await _settle(SETTLE_MS)
	var name_after: String = main.client.node_name_at(target.node)
	effects["now"] = name_after
	var change := _inventory_change(before, _compact_inventory(main.client.inventory_state()))
	# A drop can reach the inventory a little after the node goes, when the
	# game drops it as an item the player then picks up.
	var until := Time.get_ticks_msec() + SETTLE_MS
	while change.is_empty() and name_after != name_before and Time.get_ticks_msec() < until:
		await get_tree().process_frame
		change = _inventory_change(before, _compact_inventory(main.client.inventory_state()))
	effects["inventory_change"] = change
	if name_after == name_before:
		_finish(rec, "refused", "the server put the node back (protection, privileges or reach)", effects)
	else:
		_finish(rec, "completed", "", effects)

# One press of the place button, as a right click: place the wielded item
# against the pointed node, use the node (a chest opens its form), use the
# pointed entity, or use the wielded item when nothing is pointed at.
func _place(rec: Dictionary, _a: Dictionary) -> void:
	_interaction = rec.id
	var target := _pointed_summary(main.pointed)
	var watch := []
	if target.type == "node":
		watch = [target.node, target.above]
	var names_before := []
	for p in watch:
		names_before.append(main.client.node_name_at(p))
	var before := _compact_inventory(main.client.inventory_state())
	var wield_before: String = main.client.wield_item_name()
	main.agent_place_pressed = true
	await _settle(SETTLE_MS)
	var effects := {"target": target}
	for i in watch.size():
		var now_name: String = main.client.node_name_at(watch[i])
		if now_name != names_before[i]:
			effects["node_changed" if i == 0 else "placed"] = {"node": watch[i],
				"before": names_before[i], "now": now_name}
	if _window_kind() != "none":
		effects["window"] = _window_kind()
		if main.ui.window == main.ui.form:
			effects["formname"] = String(main.ui.form.formname)
	var change := _inventory_change(before, _compact_inventory(main.client.inventory_state()))
	if not change.is_empty():
		effects["inventory_change"] = change
	if main.client.wield_item_name() != wield_before:
		effects["wield_item"] = main.client.wield_item_name()
	var reason := "" if effects.size() > 1 else \
			"no effect seen: the server may have refused it, or the item does nothing here"
	_finish(rec, "completed", reason, effects)

# Punch the pointed entity: the dig button held for duration_ms (one press
# by default). The client repeats punches while it is held no faster than a
# held mouse button does.
func _attack(rec: Dictionary, a: Dictionary) -> void:
	_interaction = rec.id
	var target := _pointed_summary(main.pointed)
	var duration := clampi(_int(a.get("duration_ms", 100)), 1, MAX_HOLD_MS)
	var start := Time.get_ticks_msec()
	main.agent_dig = true
	var outcome := ""
	var frames := 0
	while frames < 1 or Time.get_ticks_msec() - start < duration:
		await get_tree().process_frame
		frames += 1
		var now := _pointed_summary(main.pointed)
		if _broken() != "":
			outcome = _broken()
		elif rec.cancel:
			outcome = "released"
		elif now.type != "object" or now.object_id != target.object_id:
			outcome = "the crosshair left the entity"
		if outcome != "":
			break
	main.agent_dig = false
	var present := false
	for entity in main.client.entity_list():
		if int(entity.get("id", -1)) == target.object_id:
			present = true
	var effects := {"object_id": target.object_id, "object_name": target.object_name,
		"still_present": present}
	_finish(rec, "interrupted" if outcome != "" else "completed", outcome, effects)

func _hotbar(rec: Dictionary, a: Dictionary) -> void:
	var slot := _int(a.get("slot", 0))
	var count: int = main._hotbar_count()
	if slot < 1 or slot > count:
		_finish(rec, "refused", "slot is 1 to %d on this server" % count)
		return
	main._set_wield(slot - 1)
	await _settle(0, 2)
	_finish(rec, "completed", "", {"slot": slot, "wield_item": main.client.wield_item_name()})

# Luanti's drop key: the wielded stack, or one item of it with single.
func _drop(rec: Dictionary, a: Dictionary) -> void:
	var item: String = main.client.wield_item_name()
	if item == "":
		_finish(rec, "refused", "nothing is wielded")
		return
	var before := _compact_inventory(main.client.inventory_state())
	main._drop_wielded(bool(a.get("single", false)))
	await _settle(500)
	_finish(rec, "completed", "", {"item": item,
		"inventory_change": _inventory_change(before, _compact_inventory(main.client.inventory_state()))})

func _inventory_open(rec: Dictionary) -> void:
	if main.ui == null or main.ui.window != null or main.ui.chat_open:
		_finish(rec, "refused", "a window or chat is already open (%s)" % _window_kind())
		return
	main.ui.toggle_inventory()
	await _settle(0, 2)
	_finish(rec, "completed", "", {"window": _window_kind()})

# Close the open form, as Escape does. Goanna's own menus are not the
# agent's to drive, and the death screen closes only by respawning.
func _inventory_close(rec: Dictionary) -> void:
	if main.ui == null or main.ui.window == null:
		_finish(rec, "refused", "no window is open")
		return
	if main.ui.window != main.ui.form:
		_finish(rec, "refused", "the open window (%s) is not a form" % _window_kind())
		return
	main.ui._close_window()
	await _settle(0, 2)
	_finish(rec, "completed", "", {"window": _window_kind()})

# A click on a slot of the open form, through the same handlers a mouse
# click reaches: press and release on the one slot. Picking up and putting
# down are two clicks, as with a mouse.
func _inventory_click(rec: Dictionary, a: Dictionary) -> void:
	if main.ui == null or main.ui.window != main.ui.form:
		_finish(rec, "refused", "no form is open; inventory_open first")
		return
	var location := String(a.get("location", "current_player"))
	var list_name := String(a.get("list", ""))
	var index := _int(a.get("index", -1))
	var button_name := String(a.get("button", "left"))
	if not BUTTONS.has(button_name):
		_finish(rec, "refused", "button is left, right or middle")
		return
	var key := "%s|%s|%d" % [location, list_name, index]
	var shown := _slots(_window_state())
	if not shown.has(key):
		_finish(rec, "refused", "the open form shows no slot %s" % key)
		return
	var observed: Dictionary = _snapshots[_int(rec.based_on)].window
	var then := _slots(observed)
	if not then.has(key) or then[key] != shown[key] \
			or observed.get("cursor", {}) != _cursor():
		_finish(rec, "stale", "the slot or the cursor stack changed since the observation",
			{"observed": then.get(key, null), "now": shown[key], "cursor": _cursor()})
		return
	var button: int = BUTTONS[button_name]
	main.ui._on_slot_clicked(location, list_name, index, button, bool(a.get("shift", false)))
	main.ui._on_slot_released(location, list_name, index, button)
	await _settle(500)
	var after := _slots(_window_state())
	_finish(rec, "completed", "", {"slot": after.get(key, {}), "cursor": _cursor()})

func _slots(window: Dictionary) -> Dictionary:
	var out := {}
	for list in window.get("lists", []):
		for slot in list.slots:
			out["%s|%s|%d" % [list.location, list.list, int(slot.index)]] = \
				{"item": slot.get("item", ""), "count": int(slot.get("count", 0))}
	return out

# A form element worked as a person works it, through the element's own
# signal, the one a click, a keypress or a wheel turn on it emits. formspec.gd
# answers that by sending the fields upstream sends for the same event, so the
# server sees what it would see from a mouse. Text typed into a field goes
# with the next event that sends fields, as typing does; enter sends at once,
# as Enter does.
func _form(rec: Dictionary, kind: String, a: Dictionary) -> void:
	var form = main.ui.form
	var name := String(a.get("name", ""))
	var c: Control = form.named_controls[name]
	var sent := []
	var watch := func(fields: Dictionary, quit: bool) -> void:
		sent.append({"fields": fields.duplicate(), "quit": quit})
	form.fields_submitted.connect(watch)
	var before: int = form.root.get_instance_id() if form.root != null else 0
	var refused := ""
	match kind:
		"form_button":
			c.pressed.emit()
		"form_field":
			var text := String(a.get("text", ""))
			if text.length() > FIELD_MAX:
				refused = "text is at most %d characters" % FIELD_MAX
			elif c is LineEdit:
				if text.contains("\n"):
					refused = "'%s' is one line" % name
				else:
					(c as LineEdit).text = text
					if bool(a.get("enter", false)):
						(c as LineEdit).text_submitted.emit(text)
			else:
				(c as TextEdit).text = text
				if bool(a.get("enter", false)):
					refused = "Enter in a textarea is a new line, not a submit"
		"form_select":
			refused = _form_select(c, a)
		"form_check":
			if not a.has("checked"):
				refused = "form_check wants checked: true or false"
			else:
				(c as CheckBox).button_pressed = bool(a.checked)
		"form_scroll":
			var bar := c as ScrollBar
			var value := _int(a.get("value", bar.value))
			if a.has("by"):
				value = int(bar.value) + _int(a.by)
			bar.value = clampi(value, int(bar.min_value), int(bar.max_value))
		"form_action":
			refused = _form_action(c as RichTextLabel, a)
	form.fields_submitted.disconnect(watch)
	if refused != "":
		_finish(rec, "refused", refused)
		return
	await _settle(500)
	var effects := {"element": name, "fields_sent": sent, "window": _window_kind()}
	if main.ui.window == form:
		effects["formname"] = String(form.formname)
		effects["form_rebuilt"] = (form.root.get_instance_id() if form.root != null else 0) != before
		effects["now"] = _element(_window_state(), name)
	var reason := "" if not sent.is_empty() or kind == "form_field" else \
			"nothing was sent: it was already in that state"
	_finish(rec, "completed", reason, effects)

# Pick an entry of a dropdown, text list or table, or a tab, counted from 1
# as the form counts them, or by its text. double is a double click, which a
# text list and a table send as their own event.
func _form_select(c: Control, a: Dictionary) -> String:
	var choices := []
	if c is OptionButton:
		for i in (c as OptionButton).item_count:
			choices.append((c as OptionButton).get_item_text(i))
	elif c is ItemList:
		for i in (c as ItemList).item_count:
			choices.append((c as ItemList).get_item_text(i))
	elif c is TabBar:
		for i in (c as TabBar).tab_count:
			choices.append((c as TabBar).get_tab_title(i))
	var index := _int(a.get("index", 0))
	if c is Tree:
		var rows := _table_rows(c as Tree)
		if a.has("text"):
			for r in rows:
				if String(a.text) in r.cells:
					index = int(r.row)
					break
		var item: TreeItem = null
		var at := (c as Tree).get_root()
		while at != null:
			if int(at.get_meta("row", 0)) == index and (at != (c as Tree).get_root() or not (c as Tree).hide_root):
				item = at
				break
			at = at.get_next_visible()
		if item == null:
			return "the table shows no row %s" % (str(a.text) if a.has("text") else str(index))
		var double := bool(a.get("double", false))
		if not double and item == (c as Tree).get_selected():
			return ""
		item.select(0)
		if double:
			(c as Tree).item_activated.emit()
		return ""
	if a.has("text"):
		index = choices.find(String(a.text)) + 1
	if index < 1 or index > choices.size():
		return "choose index 1 to %d, or text, one of: %s" % [choices.size(), ", ".join(choices)]
	if c is OptionButton:
		if (c as OptionButton).selected != index - 1:
			(c as OptionButton).select(index - 1)
			(c as OptionButton).item_selected.emit(index - 1)
	elif c is ItemList:
		var il := c as ItemList
		if bool(a.get("double", false)):
			il.select(index - 1)
			il.item_activated.emit(index - 1)
		elif not il.is_selected(index - 1):
			il.select(index - 1)
			il.item_selected.emit(index - 1)
	elif c is TabBar:
		(c as TabBar).current_tab = index - 1
	return ""

# Follow one <action> link of a hypertext element, by the name it sends or
# the text it shows.
func _form_action(rt: RichTextLabel, a: Dictionary) -> String:
	var links: Array = main.ui.form.hypertext_actions(rt)
	for i in links.size():
		var link: Dictionary = links[i]
		if (a.has("action") and link.name == String(a.action)) \
				or (a.has("text") and link.text == String(a.text)):
			rt.meta_clicked.emit({"index": i, "name": link.name, "url": link.url})
			return ""
	return "no action link %s; it has: %s" % [str(a.get("action", a.get("text", ""))),
		", ".join(links.map(func(l: Dictionary) -> String: return "%s (%s)" % [l.name, l.text]))]

# The death screen's Respawn button.
func _respawn(rec: Dictionary) -> void:
	main.ui._respawn()
	var until := Time.get_ticks_msec() + SETTLE_MS
	while main.client.hp() <= 0 and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	await _settle(0, 2)
	_finish(rec, "completed" if main.client.hp() > 0 else "interrupted",
		"" if main.client.hp() > 0 else "the server has not brought the player back yet",
		{"health": main.client.hp(), "position": _body_position(), "window": _window_kind()})

# Chat, as typed into the chat box. A leading slash would make it a server
# command, which the player interface does not carry.
func _chat(rec: Dictionary, a: Dictionary) -> void:
	var text := String(a.get("text", "")).strip_edges()
	if text == "" or text.length() > CHAT_MAX or text.contains("\n"):
		_finish(rec, "refused", "text is one line of 1 to %d characters" % CHAT_MAX)
		return
	if text.begins_with("/"):
		_finish(rec, "refused", "server commands are not part of the player agent vocabulary")
		return
	var now := Time.get_ticks_msec()
	while not _chat_times.is_empty() and now - int(_chat_times[0]) > 10000:
		_chat_times.pop_front()
	if _chat_times.size() >= CHATS_PER_10_SECONDS:
		_finish(rec, "refused", "more than %d chat messages in 10 seconds" % CHATS_PER_10_SECONDS)
		return
	_chat_times.append(now)
	main.client.send_chat(text)
	_finish(rec, "completed", "", {"text": text})

# --- waiting -----------------------------------------------------------------

# Wait for frames (ticks), time, an event after since_event, or an action to
# end. Answers completed when it happened and interrupted at the timeout.
func _wait(connection: Dictionary, reply: Dictionary, a: Dictionary) -> void:
	var start := Time.get_ticks_msec()
	var timeout := clampi(_int(a.get("timeout_ms", a.get("ms", MAX_WAIT_MS))), 0, MAX_WAIT_MS)
	var out := {"status": "completed"}
	if a.has("ticks"):
		var ticks := clampi(_int(a.ticks), 1, MAX_WAIT_TICKS)
		for i in ticks:
			await get_tree().process_frame
		out["ticks"] = ticks
	elif a.has("action"):
		var rec = _actions.get(_int(a.action), null)
		if rec == null:
			reply.merge({"ok": false, "error": "no such action"})
			_send(connection, reply)
			return
		while rec.status == "accepted" and Time.get_ticks_msec() - start < timeout:
			await get_tree().process_frame
		if rec.status == "accepted":
			out.status = "interrupted"
			out["reason"] = "timeout"
		out["action"] = _result(rec)
	elif a.has("event"):
		var kind := String(a.event)
		var since := _int(a.get("since_event", _event_cursor))
		var found := []
		while Time.get_ticks_msec() - start < timeout:
			for event in _events:
				if int(event.cursor) > since and (kind == "any" or event.kind == kind):
					found.append(event)
			if not found.is_empty():
				break
			await get_tree().process_frame
		if found.is_empty():
			out.status = "interrupted"
			out["reason"] = "timeout"
		out["events"] = found
	else:
		while Time.get_ticks_msec() - start < timeout:
			await get_tree().process_frame
	out.merge({"sequence": _sequence, "tick": Engine.get_process_frames(),
		"event_cursor": _event_cursor, "elapsed_ms": Time.get_ticks_msec() - start})
	reply.merge({"ok": true, "result": _plain(out)})
	_send(connection, reply)

# --- plumbing ----------------------------------------------------------------

func _subject() -> String:
	return OS.get_environment("GOANNA_NAME") if OS.get_environment("GOANNA_NAME") != "" else "player"

static func _is_int(v: Variant) -> bool:
	return v is int or (v is float and is_equal_approx(v, roundf(v)))

static func _int(v: Variant) -> int:
	if v is int or v is float:
		return int(v)
	if v is String and v.is_valid_int():
		return int(v)
	return 0

func _send(connection: Dictionary, message: Dictionary) -> void:
	var peer: StreamPeerTCP = connection.peer
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(message) + "\n").to_utf8_buffer())

func _plain(value: Variant) -> Variant:
	if value is Vector3 or value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector2 or value is Vector2i:
		return [value.x, value.y]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Dictionary:
		var dictionary := {}
		for key in value:
			dictionary[str(key)] = _plain(value[key])
		return dictionary
	if value is Array:
		var array := []
		for item in value:
			array.append(_plain(item))
		return array
	return value
