extends SceneTree

const AssetStore := preload("res://asset_store.gd")
const AssetUpdater := preload("res://asset_updater.gd")

# The updater asks the session two questions, so answering those two covers
# the queueing rule with no connection, no server and no client extension.
class StubClient extends Node:
	var media := PackedStringArray()
	var state := "definitions"

	func status() -> Dictionary:
		return {"media_announced": media.size(), "state": state}

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
			_game_is_inferred, _game_is_remembered_per_server, _settles_when_nothing_is_needed,
			_waits_while_a_bundle_is_due, _settles_without_media, _settles_without_a_catalogue,
			_borrowed_names_do_not_win]:
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

# Whether an updater settled (the join may go on) after one look at what the
# stub says the server announced, and what it queued.
func _settles(bundles: Array, media: PackedStringArray, state := "definitions") -> Array:
	var updater := AssetUpdater.new()
	updater.catalogue = _catalogue(bundles)
	var stub := StubClient.new()
	stub.media = media
	stub.state = state
	updater.client = stub
	var heard := [false]
	updater.settled.connect(func() -> void: heard[0] = true)
	updater._process(0.0)
	var result := [heard[0], updater.is_settled(), updater._queue.size()]
	stub.free()
	updater.free()
	return result

# The join waits for the materials a server asks for. When it asks for none
# that are missing, it must not wait at all.
func _settles_when_nothing_is_needed() -> String:
	var bundles := [_bundle("test.other", ["mineclonia"], ["mcl_stone"])]
	var got := _settles(bundles, _media(["default_dirt"]))
	if got != [true, true, 0]:
		return "nothing wanted did not settle at once: %s" % [got]
	return ""

func _waits_while_a_bundle_is_due() -> String:
	var bundles := [_bundle("test.due", ["minetest_game"], ["default_dirt"])]
	var got := _settles(bundles, _media(["default_dirt"]))
	if got != [false, false, 1]:
		return "a bundle still to fetch settled: %s" % [got]
	return ""

# A server with no media announces none; past that stage there is nothing
# to wait for, and waiting would hold the join for ever.
func _settles_without_media() -> String:
	var bundles := [_bundle("test.due", ["minetest_game"], ["default_dirt"])]
	if _settles(bundles, PackedStringArray(), "definitions")[0]:
		return "settled before the server could have announced its media"
	if not _settles(bundles, PackedStringArray(), "content-ready")[0]:
		return "a server with no media held the join"
	return ""

func _settles_without_a_catalogue() -> String:
	var updater := AssetUpdater.new()
	var heard := [false]
	updater.settled.connect(func() -> void: heard[0] = true)
	updater._on_catalogue(HTTPRequest.RESULT_CANT_RESOLVE, 0, PackedStringArray(), PackedByteArray())
	updater.free()
	if not heard[0]:
		return "an unreachable catalogue held the join"
	return ""

# The case that fetched 84 MB of Mineclonia art for every Minetest Game
# player: a few of the Minetest Game textures a server announces are names
# only the Mineclonia pack provides. The game with most names wins.
func _borrowed_names_do_not_win() -> String:
	var mtg_names := []
	for i in 30:
		mtg_names.append("default_thing_%d" % i)
	var bundles := [
		_bundle("test.mcl", ["mineclonia"], ["mcl_stone", "default_tool_steelpick", "default_tool_steelaxe"]),
		_bundle("test.mtg", ["minetest", "minetest_game"], mtg_names),
	]
	var queued := _queued(bundles, _media(mtg_names + ["default_tool_steelpick", "default_tool_steelaxe"]))
	if queued != ["test.mtg"]:
		return "a Minetest Game announcement with borrowed names queued %s" % [queued]
	var old := _bundle("test.mtg", ["minetest", "minetest_game"], mtg_names)
	var newer := old.duplicate()
	newer["version"] = "2.0.0"
	var newest := AssetUpdater.newest_only([old, newer])
	if newest.size() != 1 or newest[0].version != "2.0.0":
		return "an older version of a bundle was kept beside the newer: %s" % [newest]
	if AssetUpdater.common_games([bundles[1]]) != ["minetest", "minetest_game"]:
		return "a game's two names were not both kept"
	queued = _queued(bundles, _media(["mcl_stone", "default_tool_steelpick", "default_tool_steelaxe"]))
	if queued != ["test.mcl"]:
		return "a Mineclonia announcement queued %s" % [queued]
	return ""

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
