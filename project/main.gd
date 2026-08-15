extends Node3D

var client: GoannaClient
var t := 0.0
var last_print := -1.0

func _ready() -> void:
	client = GoannaClient.new()
	add_child(client)
	print(client.hello())
	print(client.luanti_version())
	var host := OS.get_environment("GOANNA_HOST")
	if host == "":
		host = "127.0.0.1"
	var port := int(OS.get_environment("GOANNA_PORT")) if OS.get_environment("GOANNA_PORT") != "" else 30000
	var pname := OS.get_environment("GOANNA_NAME")
	if pname == "":
		pname = "goanna"
	print("connecting to ", host, ":", port, " as ", pname)
	client.connect_to(host, port, pname, OS.get_environment("GOANNA_PASS"))

func _process(delta: float) -> void:
	t += delta
	if t - last_print >= 1.0:
		last_print = t
		var s: Dictionary = client.status()
		print("[%5.1fs] %s | %s | proto %d | nodes %d items %d media %d | blocks %d | pos %s" % [
			t, s.get("state"), s.get("message"), s.get("proto_ver", 0), s.get("node_defs", 0),
			s.get("item_defs", 0), s.get("media_announced", 0), s.get("blocks_received", 0),
			str(s.get("player_pos", Vector3()))])
	var limit := float(OS.get_environment("GOANNA_SMOKE")) if OS.get_environment("GOANNA_SMOKE") != "" else 0.0
	if limit > 0.0 and t > limit:
		client.disconnect_from_server()
		get_tree().quit()
