extends SceneTree

const AssetStore := preload("res://asset_store.gd")
const AssetUpdater := preload("res://asset_updater.gd")

# The updater asks the session two questions, so answering those two covers
# the queueing rule with no connection, no server and no client extension.
class StubClient extends Node:
	var media := PackedStringArray()

	func status() -> Dictionary:
		return {"media_announced": media.size()}

	func announced_media_names() -> PackedStringArray:
		return media

var _root := ""

# A tripped assert halts the engine without reaching quit(), which reads as a
# hang rather than a failure, so every check reports and exits non-zero.
func _fail(message: String) -> void:
	printerr("asset updater: FAIL: ", message)
	quit(1)

func _init() -> void:
	_root = ProjectSettings.globalize_path(
			"user://asset-updater-test-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_root)
	# Nothing is installed in this scratch root, so a bundle is only skipped
	# when the test itself puts one there.
	OS.set_environment("GOANNA_ASSET_ROOT", _root)
	for check in [_shared_stems_queue_nothing, _one_game_may_have_tranches,
			_a_lone_bundle_owns_every_stem, _unreachable_is_reported,
			_installed_is_skipped, _real_catalogue_separates_its_games,
			_game_is_inferred, _game_is_remembered_per_server]:
		var error: String = check.call()
		if error != "":
			_fail(error)
			return
	print("asset updater: PASS")
	quit()

func _bundle(id: String, games: Array, provides: Array) -> Dictionary:
	return {"id": id, "version": "1.0.0", "sha256": "0".repeat(64),
		"url": "https://example.invalid/%s-1.0.0.zip" % id,
		"games": games, "provides": provides}

func _catalogue(bundles: Array) -> Dictionary:
	return AssetStore.parse_catalogue(JSON.stringify({
		"schema": AssetStore.CATALOGUE_SCHEMA, "bundles": bundles}))

func _media(stems: Array) -> PackedStringArray:
	var result := PackedStringArray()
	for stem in stems:
		result.append("%s.png" % stem)
	return result

# What the updater would download, given what a server announced. The queue
# is read rather than the download: _download_next has no HTTPRequest here
# and returns before touching the network.
func _queued(bundles: Array, media: PackedStringArray) -> Array:
	var updater := AssetUpdater.new()
	updater.catalogue = _catalogue(bundles)
	var stub := StubClient.new()
	stub.media = media
	updater.client = stub
	updater._process(0.0)
	var ids := []
	for bundle in updater._queue:
		ids.append(str(bundle.id))
	stub.free()
	updater.free()
	return ids

func _games(bundle: Dictionary) -> Dictionary:
	var result := {}
	for game in bundle.get("games", []):
		result[str(game)] = true
	return result

# The defect this suite exists for. Mineclonia and Minetest Game both ship a
# default_cobble, and the Mineclonia bundle is 103.8 MB, so a stem both
# provide must count for neither.
func _shared_stems_queue_nothing() -> String:
	var bundles := [
		_bundle("test.mineclonia", ["mineclonia"],
			["mcl_stone", "mcl_dirt", "default_cobble", "default_sand"]),
		_bundle("test.minetest-game", ["minetest", "minetest_game"],
			["default_cobble", "default_sand", "default_stone", "default_tree"]),
	]
	var queued := _queued(bundles, _media(["default_cobble", "default_sand",
		"default_stone", "default_tree"]))
	if queued != ["test.minetest-game"]:
		return "a Minetest Game announcement queued %s" % [queued]
	queued = _queued(bundles, _media(["mcl_stone", "mcl_dirt",
		"default_cobble", "default_sand"]))
	if queued != ["test.mineclonia"]:
		return "a Mineclonia announcement queued %s" % [queued]
	queued = _queued(bundles, _media(["default_cobble", "default_sand"]))
	if not queued.is_empty():
		return "the shared stems alone queued %s" % [queued]
	return ""

# Two tranches of one game may legitimately list the same name. The game is
# not in doubt there, so the name still counts, for both of them.
func _one_game_may_have_tranches() -> String:
	var bundles := [
		_bundle("test.kythen.terrain", ["kythen"], ["kythen_stone", "kythen_leaf"]),
		_bundle("test.kythen.item", ["kythen"], ["kythen_sword", "kythen_leaf"]),
	]
	var queued := _queued(bundles, _media(["kythen_leaf"]))
	if queued != ["test.kythen.terrain", "test.kythen.item"]:
		return "a shared name within one game queued %s" % [queued]
	return ""

# A catalogue of one bundle has nothing to be ambiguous with, so it behaves
# as it did before the rule existed.
func _a_lone_bundle_owns_every_stem() -> String:
	var bundles := [_bundle("test.only", ["minetest_game"], ["default_cobble"])]
	var queued := _queued(bundles, _media(["default_cobble"]))
	if queued != ["test.only"]:
		return "the only bundle in the catalogue queued %s" % [queued]
	return ""

# A bundle whose every name another game's bundle also provides can never be
# asked for. That is a catalogue fault and its symptom is silence, so the
# updater names it.
func _unreachable_is_reported() -> String:
	var bundles := [
		_bundle("test.shadowed", ["a"], ["shared_one", "shared_two"]),
		_bundle("test.shadowing", ["b"], ["shared_one", "shared_two", "own_stem"]),
		_bundle("test.empty", ["c"], []),
	]
	var ambiguous := AssetUpdater.ambiguous_stems(bundles)
	var unreachable := AssetUpdater.unreachable_bundles(bundles, ambiguous)
	if unreachable != ["test.shadowed", "test.empty"]:
		return "unreachable bundles reported as %s" % [unreachable]
	var queued := _queued(bundles, _media(["shared_one", "shared_two"]))
	if not queued.is_empty():
		return "a shadowed bundle's names queued %s" % [queued]
	queued = _queued(bundles, _media(["shared_one", "own_stem"]))
	if queued != ["test.shadowing"]:
		return "the shadowing bundle's own name queued %s" % [queued]
	return ""

func _installed_is_skipped() -> String:
	var bundles := [_bundle("test.installed", ["minetest_game"], ["default_cobble"])]
	var installed := _root.path_join("test.installed").path_join("1.0.0")
	DirAccess.make_dir_recursive_absolute(installed)
	var manifest := FileAccess.open(installed.path_join("manifest.json"),
			FileAccess.WRITE)
	if manifest == null:
		return "could not write a manifest into %s" % installed
	manifest.store_string("{}")
	manifest = null
	var queued := _queued(bundles, _media(["default_cobble"]))
	if not queued.is_empty():
		return "an installed bundle was queued again as %s" % [queued]
	return ""

# The same rule against the catalogue that ships, where the shared names are
# the 30 default_* stems the Mineclonia pack and the Minetest Game terrain
# bundle have in common. Announcing everything one bundle provides must queue
# that bundle, and must never queue a bundle for an unrelated game.
func _real_catalogue_separates_its_games() -> String:
	var path := OS.get_environment("GOANNA_TEST_CATALOGUE")
	if path == "":
		path = "../asset_bundles/catalogue.json"
	if path.is_relative_path():
		path = ProjectSettings.globalize_path("res://").path_join(path)
	var catalogue := AssetStore.parse_catalogue(FileAccess.get_file_as_string(path))
	if catalogue.is_empty():
		return "could not read a usable catalogue at %s" % path
	for bundle in catalogue.bundles:
		var stems: Array = bundle.get("provides", [])
		if stems.is_empty():
			return "%s provides nothing, so it can never be asked for" % bundle.id
		var queued := _queued(catalogue.bundles, _media(stems))
		if not (str(bundle.id) in queued):
			return "%s is not queued by its own announcement" % bundle.id
		var games := _games(bundle)
		for other in catalogue.bundles:
			if not (str(other.id) in queued):
				continue
			var shares := false
			for game in _games(other):
				if games.has(game):
					shares = true
					break
			if not shares:
				return "%s queues %s, which serves %s" % [bundle.id, other.id,
					other.get("games", [])]
	return ""

# Join Game can only hand a pack over before connecting, and the protocol
# never names the server's game, so the game is inferred from the bundles the
# announcement matched: one game when they agree, none when they do not.
func _game_is_inferred() -> String:
	var mcl := _bundle("mcl.pack", ["mineclonia"], ["mcl_a"])
	var mcl_items := _bundle("mcl.items", ["mineclonia", "voxelibre"], ["mcl_b"])
	var mtg := _bundle("mtg.terrain", ["minetest_game"], ["default_a"])
	if AssetUpdater.game_of([mcl, mcl_items]) != "mineclonia":
		return "two Mineclonia bundles did not agree on mineclonia"
	if AssetUpdater.game_of([mcl, mtg]) != "":
		return "bundles of two games were taken as one game"
	if AssetUpdater.game_of([mcl_items]) != "":
		return "a bundle for two games was taken as one of them"
	if AssetUpdater.game_of([]) != "":
		return "no bundles named a game"
	return ""

# The session records the game against the address it joined, in the file it
# is given, and a second address is untouched.
func _game_is_remembered_per_server() -> String:
	var cfg_path := _root.path_join("goanna.cfg")
	var updater := AssetUpdater.new()
	updater.catalogue = _catalogue([_bundle("mcl.pack", ["mineclonia"], ["mcl_a"])])
	updater.server_address = "play.example.org:30001"
	updater.cfg_path = cfg_path
	var stub := StubClient.new()
	stub.media = _media(["mcl_a", "other"])
	updater.client = stub
	updater._process(0.0)
	stub.free()
	updater.free()
	var seen := AssetUpdater.remembered_game("play.example.org:30001", cfg_path)
	if seen != "mineclonia":
		return "the joined server was remembered as %s, not mineclonia" % seen
	if AssetUpdater.remembered_game("play.example.org:30000", cfg_path) != "":
		return "another port on the same host inherited the game"
	return ""
