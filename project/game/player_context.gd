# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Helpers that keep a node inside its own player's world under split screen.
## Preloaded by game/main.gd, ui/game_ui.gd and the effects scripts. Each
## local player has its own SubViewport (game/player_slot.gd), so a group
## lookup must be narrowed to the caller's viewport, and a shader global must
## go through the player's GoannaClient, which renames it per player.
extends RefCounted

## The first member of the group that shares node's viewport, or null. Used
## for "goanna_main" and "goanna_particles", which every player slot has one of.
static func find(node: Node, group: StringName) -> Node:
	if not node.is_inside_tree():
		return null
	var viewport := node.get_viewport()
	for candidate in node.get_tree().get_nodes_in_group(group):
		if candidate.get_viewport() == viewport:
			return candidate
	return null

## Sets a global shader parameter for this player only. Godot's shader
## globals span every World3D, so GoannaClient.set_view_shader_parameter maps
## the name to this player's copy (src/goanna_render_scope.h).
static func shader_parameter(client: Variant, key: StringName, value: Variant) -> void:
	# Pure weather fixtures use stand-ins with no rendering API.
	if is_instance_valid(client) and client.has_method("set_view_shader_parameter"):
		client.set_view_shader_parameter(key, value)
	else:
		RenderingServer.global_shader_parameter_set(key, value)
