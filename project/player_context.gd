# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends RefCounted

static func find(node: Node, group: StringName) -> Node:
	if not node.is_inside_tree():
		return null
	var viewport := node.get_viewport()
	for candidate in node.get_tree().get_nodes_in_group(group):
		if candidate.get_viewport() == viewport:
			return candidate
	return null

static func shader_parameter(client: Variant, key: StringName, value: Variant) -> void:
	# Pure weather fixtures use stand-ins with no rendering API.
	if is_instance_valid(client) and client.has_method("set_view_shader_parameter"):
		client.set_view_shader_parameter(key, value)
	else:
		RenderingServer.global_shader_parameter_set(key, value)
