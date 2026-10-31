extends Node
## Finds Luanti servers on the local network for Join Game.
##
## Luanti servers do not announce themselves on a LAN, and the protocol has no
## query packet, so this sends each address on the player's own /24 networks
## the packet a real client opens a connection with: an empty reliable packet
## from peer 0 (luanti/src/network/mtp/threads.cpp, ConnectionSendThread::
## connect). A server answers with CONTROLTYPE_SET_PEER_ID (mtp/impl.cpp,
## Connection::createPeer); each one that does is listed, and sent a DISCO at
## once so it drops the peer rather than waiting for it to time out. Nothing
## else is asked or sent, and nothing is sent unless the player presses Scan.

signal found(host: String, port: int)
signal finished(count: int)

const PROTOCOL_ID := 0x4f457403
const SEQNUM_INITIAL := 65500
const PORTS := [30000, 30001, 30002, 30003, 30004, 30005]
# Packets per frame: a whole /24 over six ports goes out in about a second
# without a burst that a home router or the server's new peer limit minds.
const PER_FRAME := 40
# How long replies are awaited after the last probe went out.
const WAIT_MS := 1500

var _udp := PacketPeerUDP.new()
var _targets: Array = []
var _next := 0
var _done_at := 0
var _seen := {}
var running := false

## The /24 networks this machine is on, as "a.b.c" prefixes: private IPv4
## addresses only, so a public address is never swept.
static func local_prefixes() -> Array:
	var out: Array = []
	for iface in IP.get_local_interfaces():
		for addr in iface.get("addresses", []):
			var a := str(addr)
			if not a.is_valid_ip_address() or a.contains(":"):
				continue
			var p := a.split(".")
			var b0 := int(p[0])
			var b1 := int(p[1])
			var private := b0 == 10 or (b0 == 172 and b1 >= 16 and b1 <= 31) \
					or (b0 == 192 and b1 == 168)
			var prefix := "%s.%s.%s" % [p[0], p[1], p[2]]
			if private and not out.has(prefix):
				out.append(prefix)
	return out

func start() -> bool:
	stop()
	_targets.clear()
	_seen.clear()
	for prefix in local_prefixes():
		for host in range(1, 255):
			for port in PORTS:
				_targets.append(["%s.%d" % [prefix, host], port])
	if _targets.is_empty() or _udp.bind(0) != OK:
		return false
	_next = 0
	_done_at = 0
	running = true
	return true

func stop() -> void:
	running = false
	if _udp.is_bound():
		_udp.close()

func _probe() -> PackedByteArray:
	return PackedByteArray([
		(PROTOCOL_ID >> 24) & 0xff, (PROTOCOL_ID >> 16) & 0xff,
		(PROTOCOL_ID >> 8) & 0xff, PROTOCOL_ID & 0xff,
		0, 0, 0,                # no peer id yet, channel 0
		3,                      # PACKET_TYPE_RELIABLE
		(SEQNUM_INITIAL >> 8) & 0xff, SEQNUM_INITIAL & 0xff,
		1,                      # PACKET_TYPE_ORIGINAL
		0, 0])                  # an empty NetworkPacket: command 0

func _disco(peer_id: int) -> PackedByteArray:
	return PackedByteArray([
		(PROTOCOL_ID >> 24) & 0xff, (PROTOCOL_ID >> 16) & 0xff,
		(PROTOCOL_ID >> 8) & 0xff, PROTOCOL_ID & 0xff,
		(peer_id >> 8) & 0xff, peer_id & 0xff, 0,
		0, 3])                  # PACKET_TYPE_CONTROL, CONTROLTYPE_DISCO

# The peer id a SET_PEER_ID reply gives, or -1. The reply comes reliable
# (type 3, seqnum, then the control packet) or, from older servers, bare.
static func _peer_id_in(b: PackedByteArray) -> int:
	if b.size() < 11:
		return -1
	var id := (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]
	if id != PROTOCOL_ID:
		return -1
	var i := 7
	if b[i] == 3:
		i += 3
	if b.size() >= i + 4 and b[i] == 0 and b[i + 1] == 1:
		return (b[i + 2] << 8) | b[i + 3]
	return -1

func _process(_delta: float) -> void:
	if not running:
		return
	var probe := _probe()
	var sent := 0
	while _next < _targets.size() and sent < PER_FRAME:
		var t: Array = _targets[_next]
		_next += 1
		sent += 1
		_udp.set_dest_address(str(t[0]), int(t[1]))
		_udp.put_packet(probe)
	if _next >= _targets.size() and _done_at == 0:
		_done_at = Time.get_ticks_msec() + WAIT_MS
	while _udp.get_available_packet_count() > 0:
		var b := _udp.get_packet()
		var host := _udp.get_packet_ip()
		var port := _udp.get_packet_port()
		var peer := _peer_id_in(b)
		if peer < 0:
			continue
		_udp.set_dest_address(host, port)
		_udp.put_packet(_disco(peer))
		var key := "%s:%d" % [host, port]
		if not _seen.has(key):
			_seen[key] = true
			found.emit(host, port)
	if _done_at > 0 and Time.get_ticks_msec() >= _done_at:
		stop()
		finished.emit(_seen.size())
