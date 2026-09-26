# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# A top down map of what shelters the ground from rain around the player:
# for each node column, the top face of the highest node that would stop a
# raindrop (GoannaClient::rain_cover_rows says which nodes those are). The
# precipitation shader draws a drop only above it, so there is no rain
# indoors or under a canopy, and the ground and water shaders splash and
# ripple only where it is open to the sky. docs/weather.md has the whole
# picture.
#
# One texel per node, SIZE across, centred on the player. The sky light the
# mesh already carries answers "is this under a roof" too, but only at the
# faces of solid nodes; rain falls through the air in front of a doorway,
# where there is no face to ask, so the shader needs a height to compare a
# drop against.
#
# The scan is spread over frames, ROWS_PER_STEP rows at a time, into a
# pending buffer that replaces the live one only when it is whole: a map
# half old and half new would draw a seam of rain through a roof for a
# frame. It is rescanned about once a second while anything uses it, and
# at once when the player has moved far enough that its edge is close.
extends RefCounted

const SIZE := 64
const ROWS_PER_STEP := 8
# How far above and below the player a column is scanned. Rain falling past
# a roof higher than this is drawn, which is right for a tall tree well
# overhead and wrong only for a cave ceiling fifty nodes up.
const SCAN_UP := 48
const SCAN_DOWN := 32
const REFRESH_SECONDS := 1.0
# Recentre when the player has moved this far from the map's centre.
const RECENTRE_H := 6
const RECENTRE_V := 10

# Anything with rain_cover_rows(x0, z0, width, rows, y_top, y_bottom): the
# GoannaClient in the game, a stand in in project/tests/weather.gd.
var source: Object

var image: Image
var texture: ImageTexture
# World xz of texel (0, 0)'s outer corner, the size in nodes, and 1 once a
# complete map has been published.
var area := Vector4.ZERO
var ready := false

var _live := PackedFloat32Array()
var _live_origin := Vector3i.ZERO   # column (x0, y centre, z0) of the live map
var _pending := PackedFloat32Array()
var _pending_origin := Vector3i.ZERO
var _row := -1                      # next pending row, -1 when idle
var _since := 0.0


func _init(src: Object = null) -> void:
	source = src
	image = Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RF)


# Advance the scan by one band. Returns true when this step completed a map
# and published it, which is when the caller should hand out the texture.
func step(centre: Vector3, delta: float) -> bool:
	if source == null or not source.has_method("rain_cover_rows"):
		return false
	_since += delta
	var c := Vector3i(floori(centre.x + 0.5), floori(centre.y + 0.5), floori(centre.z + 0.5))
	if _row < 0:
		if not _due(c):
			return false
		_pending_origin = Vector3i(c.x - SIZE / 2, c.y, c.z - SIZE / 2)
		_pending.resize(SIZE * SIZE)
		_row = 0
		_since = 0.0
	var rows := mini(ROWS_PER_STEP, SIZE - _row)
	var band: PackedFloat32Array = source.rain_cover_rows(_pending_origin.x,
			_pending_origin.z + _row, SIZE, rows,
			_pending_origin.y + SCAN_UP, _pending_origin.y - SCAN_DOWN)
	var base := _row * SIZE
	var open := float(_pending_origin.y - SCAN_DOWN) - 0.5
	for i in SIZE * rows:
		_pending[base + i] = band[i] if i < band.size() else open
	_row += rows
	if _row < SIZE:
		return false
	_row = -1
	_publish()
	return true


func _due(c: Vector3i) -> bool:
	if not ready:
		return true
	var mid := _live_origin + Vector3i(SIZE / 2, 0, SIZE / 2)
	if absi(c.x - mid.x) >= RECENTRE_H or absi(c.z - mid.z) >= RECENTRE_H \
			or absi(c.y - mid.y) >= RECENTRE_V:
		return true
	return _since >= REFRESH_SECONDS


func _publish() -> void:
	var swap := _live
	_live = _pending
	_pending = swap
	_live_origin = _pending_origin
	image.set_data(SIZE, SIZE, false, Image.FORMAT_RF, _live.to_byte_array())
	if texture == null:
		texture = ImageTexture.create_from_image(image)
	else:
		texture.update(image)
	# Texel i covers node x0 + i, which spans x0 + i - 0.5 to x0 + i + 0.5.
	area = Vector4(float(_live_origin.x) - 0.5, float(_live_origin.z) - 0.5, float(SIZE), 1.0)
	ready = true


# The cover height over a world position, or `fallback` off the map or
# before the first map is whole. The same lookup the shaders make.
func height_at(x: float, z: float, fallback: float = -INF) -> float:
	if not ready:
		return fallback
	var i := floori(x - area.x)
	var j := floori(z - area.y)
	if i < 0 or j < 0 or i >= SIZE or j >= SIZE:
		return fallback
	return _live[j * SIZE + i]


# Whether a point is open to the sky: at or above the cover over it. A
# surface sits on the node that is its own cover, so its top face is equal
# to it; the margin is for liquid surfaces, which sit a little below.
func exposed(p: Vector3) -> bool:
	return p.y >= height_at(p.x, p.z, -INF) - 0.55


# Share of the map's columns open to the sky at height y, 0 to 1. Standing
# on an open beach this is near 1; if it is near 0 there, the map is hiding
# the rain, which is the first thing to rule out when rain cannot be seen.
func open_share(y: float) -> float:
	if not ready or _live.is_empty():
		return 0.0
	var open := 0
	for h in _live:
		if y >= h - 0.55:
			open += 1
	return float(open) / float(_live.size())


func clear() -> void:
	ready = false
	_row = -1
	area = Vector4.ZERO
