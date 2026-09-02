extends SceneTree

func _init() -> void:
	var script := FileAccess.get_file_as_string("res://player_agent_channel.gd")
	assert(script.contains('const COMMANDS := ["hello", "observe"]'))
	assert(script.contains('"actions": []'))
	assert(not script.contains("_dispatch("))
	assert(not script.contains("callv("))
	assert(not script.contains("Expression.new("))
	assert(not script.contains("GDScript.new("))
	print("player-agent boundary: PASS")
	quit()
