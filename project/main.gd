extends Node3D

func _ready() -> void:
	var c := GoannaClient.new()
	add_child(c)
	print(c.hello())
	print(c.luanti_version())
	if OS.get_environment("GOANNA_SMOKE") != "":
		get_tree().quit()
