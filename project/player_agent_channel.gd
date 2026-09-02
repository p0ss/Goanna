# SPDX-License-Identifier: LGPL-2.1-or-later
# Experimental, read-only player-agent protocol. It intentionally shares no
# dispatcher or arbitrary-code facility with control_channel.gd.
extends Node

const PROTOCOL := "goanna-player/0.1"
const DEFAULT_PORT := 30850
const MAX_LINE := 1 << 20
const COMMANDS := ["hello", "observe"]
const EVENT_LIMIT := 128

var main: Node
var _server := TCPServer.new()
var _connections: Array = []
var _port := 0
var _session := ""
var _sequence := 0
var _events: Array = []
var _event_cursor := 0
var _chat_seen := 0

func _ready() -> void:
	var spec := OS.get_environment("GOANNA_PLAYER_AGENT")
	_port = int(spec) if spec.is_valid_int() and int(spec) > 1 else DEFAULT_PORT
	_session = "%x-%x" % [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	var error := _server.listen(_port, "127.0.0.1")
	if error != OK:
		push_error("player agent: cannot listen on 127.0.0.1:%d (error %d)" % [_port, error])
		return
	print("player agent: read-only %s listening on 127.0.0.1:%d" % [PROTOCOL, _port])

func _exit_tree() -> void:
	_server.stop()

func _process(_delta: float) -> void:
	_capture_chat()
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

func _accept(connection: Dictionary, line: String) -> void:
	var request = JSON.parse_string(line)
	if not request is Dictionary:
		_send(connection, {"ok": false, "error": "request must be a JSON object"})
		return
	var command := String(request.get("cmd", ""))
	var args = request.get("args", {})
	var reply := {"id": request.get("id", null)}
	if command not in COMMANDS:
		reply.merge({"ok": false, "error": "command is not available on the player interface"})
	elif command == "hello":
		reply.merge({"ok": true, "result": _hello()})
	else:
		reply.merge({"ok": true, "result": _observe(args if args is Dictionary else {})})
	_send(connection, reply)

func _hello() -> Dictionary:
	return {"protocol": PROTOCOL, "session": _session, "subject": _subject(),
		"read_only": true, "capabilities": {"scope": ["actor"],
			"observations": ["body", "camera", "pointed", "nearby_entities",
				"inventory", "environment", "chat_events", "spatial_memory"],
			"actions": [], "director": false}}

func _observe(args: Dictionary) -> Dictionary:
	_sequence += 1
	var since := maxi(0, int(args.get("since_event", 0)))
	var new_events := []
	for event in _events:
		if int(event.cursor) > since:
			new_events.append(event)
	var oldest := int(_events[0].cursor) if not _events.is_empty() else _event_cursor + 1
	var status: Dictionary = main.client.status()
	var position: Vector3 = main.client.server_player_position()
	var entities := []
	for entity in main.client.entity_list():
		var entity_position = entity.get("position", entity.get("pos", null))
		if entity_position is Vector3 and position.distance_to(entity_position) <= 32.0:
			entities.append(entity)
	return _plain({"protocol": PROTOCOL, "session": _session, "subject": _subject(),
		"scope": "actor", "sequence": _sequence, "sampled_ms": Time.get_ticks_msec(),
		"connection": status.get("state", "unknown"),
		"body": {"position": position, "health": main.client.hp(),
			"breath": main.client.breath(), "grounded": status.get("on_ground", false),
			"wield_index": main.client.wield_index(), "wield_item": main.client.wield_item_name()},
		"camera": {"position": main.cam.position, "pitch": main.pitch, "yaw": main.yaw,
			"fov": main.cam.fov}, "pointed": main.pointed,
		"nearby_entities": {"radius": 32.0, "sensed": entities},
		"inventory": _compact_inventory(main.client.inventory_state()),
		"environment": {"sky": main.client.sky_state(),
			"underwater": main.client.is_underwater(main.cam.position)},
		"events": new_events, "event_cursor": _event_cursor,
		"events_truncated": since > 0 and since < oldest - 1,
		"spatial_memory": {"current": {"pointed": main.pointed}, "stale": [],
			"unknown": "all unobserved world state"}})

func _compact_inventory(raw: Dictionary) -> Dictionary:
	var out := {"version": raw.get("version", 0), "lists": {}}
	for list_name in raw.get("lists", {}):
		var source: Array = raw.lists[list_name]
		var items := []
		for slot in source.size():
			var item = source[slot]
			if item is Dictionary and (int(item.get("count", 0)) > 0 or String(item.get("name", "")) != ""):
				var entry: Dictionary = item.duplicate(true)
				entry["slot"] = slot
				items.append(entry)
		out.lists[list_name] = {"size": source.size(), "items": items}
	return out

func _capture_chat() -> void:
	if main == null or main.ui == null:
		return
	if _chat_seen > main.ui.chat_lines.size():
		_chat_seen = 0
	while _chat_seen < main.ui.chat_lines.size():
		_event_cursor += 1
		var line: Dictionary = main.ui.chat_lines[_chat_seen]
		_events.append({"cursor": _event_cursor, "kind": "chat", "text": line.get("text", "")})
		_chat_seen += 1
	while _events.size() > EVENT_LIMIT:
		_events.pop_front()

func _subject() -> String:
	return OS.get_environment("GOANNA_NAME") if OS.get_environment("GOANNA_NAME") != "" else "player"

func _send(connection: Dictionary, message: Dictionary) -> void:
	var peer: StreamPeerTCP = connection.peer
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(message) + "\n").to_utf8_buffer())

func _plain(value: Variant) -> Variant:
	if value is Vector3:
		return [value.x, value.y, value.z]
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
