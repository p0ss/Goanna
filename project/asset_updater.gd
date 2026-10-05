# SPDX-License-Identifier: MIT
extends Node

const AssetStore := preload("res://asset_store.gd")
const CFG_PATH := "user://goanna.cfg"

signal bundle_installed(bundle_id: String)
# Once a session: nothing more is coming for this connection. The catalogue
# could not be had or the updates are off, or the server's media asked for
# nothing new, or every bundle it asked for has been fetched or has failed.
# main.gd holds the join until then (or until the player skips).
signal settled()

# Seconds the catalogue may take before the join stops waiting for it.
const CATALOGUE_TIMEOUT_S := 15.0

var client: Node
# "host:port" of the server this session joined, set by main.gd. Empty for a
# run that has no server to remember a game for.
var server_address := ""
# Where remembered games are kept; a test points it at a scratch file.
var cfg_path := CFG_PATH
var catalogue := {}
var _catalogue_url := ""
var _http: HTTPRequest
var _queue: Array = []
var _current := {}
var _observed := false
var _settled := false
# What this session learned and fetched, for main.gd: the server's game, and
# the bundles installed since it joined.
var game := ""
# Every game the matched bundles share, in catalogue order: more than one when
# a game goes by two names (minetest, minetest_game), where game is "".
var games: Array = []
var installed_now: Array = []
var _total := 0
# The menu's instance: upgrade every bundle already installed to the
# catalogue's version as soon as the catalogue arrives, without waiting for a
# server to announce its media. In a session, a newer bundle was only fetched
# once a server asked for its textures and only applied at the next connect,
# so a player who had pack 1.1.0 played on it for one more session after
# 1.2.0 was published, and a player who only plays from the menu could stay
# on it (reported 2026-10-01).
var upgrade_installed := false

func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	if not bool(cfg.get_value("settings", "asset_updates", true)):
		_settle.call_deferred()
		return
	_catalogue_url = OS.get_environment("GOANNA_ASSET_CATALOGUE_URL")
	if _catalogue_url == "":
		var bootstrap = JSON.parse_string(FileAccess.get_file_as_string("res://bootstrap_assets.json"))
		if bootstrap is Dictionary:
			_catalogue_url = str(bootstrap.get("catalogue_url", ""))
	if _catalogue_url == "":
		_settle.call_deferred()
		return
	_http = HTTPRequest.new()
	_http.timeout = CATALOGUE_TIMEOUT_S
	add_child(_http)
	_http.request_completed.connect(_on_catalogue)
	if _http.request(_catalogue_url) != OK:
		_settle.call_deferred()

func _settle() -> void:
	if not _settled:
		_settled = true
		settled.emit()

func is_settled() -> bool:
	return _settled

# How far the downloads this session started have got: which bundle of how
# many, and its bytes so far and in all (-1 until the server says).
func progress() -> Dictionary:
	if _http == null or _current.is_empty():
		return {}
	return {"bundle": _total - _queue.size(), "count": _total,
		"bytes": _http.get_downloaded_bytes(), "size": _http.get_body_size()}

static func install_bootstrap() -> void:
	var bootstrap = JSON.parse_string(FileAccess.get_file_as_string("res://bootstrap_assets.json"))
	if bootstrap is not Dictionary:
		return
	for row in bootstrap.get("bundles", []):
		var archive := ProjectSettings.globalize_path("res://../assets").path_join(str(row.file))
		if FileAccess.file_exists(archive):
			var error := AssetStore.install_archive(archive, str(row.sha256))
			if error != "":
				push_warning(error)

func _process(_delta: float) -> void:
	if _observed or catalogue.is_empty() or client == null:
		return
	var status: Dictionary = client.status()
	var announced := int(status.get("media_announced", 0))
	if announced == 0:
		# A server with no media at all never announces any: once the session
		# is past that stage there is nothing to match, so nothing to wait for.
		if str(status.get("state", "")) in ["content-ready", "ready", "denied", "disconnected", "error"]:
			_observed = true
			_settle()
		return
	var announced_names: PackedStringArray = client.announced_media_names()
	if announced_names.size() < announced:
		return
	_observed = true
	var names := {}
	for filename in announced_names:
		names[str(filename).get_file().get_basename()] = true
	# Worked out once from the catalogue, not once per announced name: an
	# inventory runs to a thousand of them, and this is the one pass we make
	# over it.
	var ambiguous := ambiguous_stems(catalogue.bundles)
	for id in unreachable_bundles(catalogue.bundles, ambiguous):
		push_warning(("Catalogue bundle %s provides no name that is its own, "
			+ "so no announcement can ask for it.") % id)
	var matched := newest_only(one_game(bundles_for_stems(catalogue.bundles, names, ambiguous),
		names, ambiguous))
	for bundle in matched:
		if not _installed(bundle):
			_queue.append(bundle)
	_total = _queue.size()
	game = game_of(matched)
	games = common_games(matched)
	if game != "" and server_address != "":
		remember_game(server_address, game, cfg_path)
	if _queue.is_empty():
		_settle()
	_download_next()

# The one game every matched bundle is for, or "" when they name none or
# disagree. The protocol never tells a client the server's game, so this is
# the only evidence a remote join has: the bundles its media asked for.
# The newest version of each bundle. The catalogue keeps older versions for
# the clients that pinned them, and both matched, so a join fetched Minetest
# Game's terrain 1.1.0 and then 2.0.0 over it.
static func newest_only(bundles: Array) -> Array:
	var newest := {}
	for bundle in bundles:
		var id := str(bundle.id)
		if not newest.has(id) or _version_after(str(bundle.version), str(newest[id].version)):
			newest[id] = bundle
	return bundles.filter(func(b: Dictionary) -> bool: return newest[str(b.id)] == b)

static func _version_after(a: String, b: String) -> bool:
	var x := a.split(".")
	var y := b.split(".")
	for i in maxi(x.size(), y.size()):
		var p := int(x[i]) if i < x.size() else 0
		var q := int(y[i]) if i < y.size() else 0
		if p != q:
			return p > q
	return false

static func common_games(bundles: Array) -> Array:
	var common: Array = []
	var first := true
	for bundle in bundles:
		var named: Array = bundle.get("games", []).map(func(g) -> String: return str(g))
		if first:
			common = named
			first = false
		else:
			common = common.filter(func(g: String) -> bool: return g in named)
	return common

# A server runs one game, so the matched bundles are cut to the game whose
# bundles answer most of the announcement. A name only one bundle provides
# counts for that bundle's game, but games borrow names: Mineclonia's pack
# carries Minetest Game's default_tool_* textures, so a Minetest Game server
# matched it on 17 names against its own terrain bundle's 182 and fetched an
# 84 MB pack it would never use. A tie keeps nothing, since the game is then
# not known.
static func one_game(matched: Array, names: Dictionary, ambiguous: Dictionary) -> Array:
	var score := {}
	for bundle in matched:
		var counted := {}
		for stem in bundle.get("provides", []):
			var stem_name := str(stem)
			if names.has(stem_name) and not ambiguous.has(stem_name):
				counted[stem_name] = true
		for g in bundle.get("games", []):
			var per: Dictionary = score.get(str(g), {})
			per.merge(counted)
			score[str(g)] = per
	var best := 0
	for g in score:
		best = maxi(best, (score[g] as Dictionary).size())
	var winners := []
	for g in score:
		if (score[g] as Dictionary).size() == best:
			winners.append(g)
	# Several winners are one game under several names only if a bundle
	# carries all of them; otherwise the announcement is evenly split.
	var kept := matched.filter(func(b: Dictionary) -> bool:
		return winners.all(func(g: String) -> bool: return str(g) in b.get("games", []).map(func(x) -> String: return str(x))))
	return kept

static func game_of(bundles: Array) -> String:
	var common := {}
	var first := true
	for bundle in bundles:
		var games := {}
		for g in bundle.get("games", []):
			games[str(g)] = true
		if first:
			common = games
			first = false
			continue
		for g in common.keys():
			if not games.has(g):
				common.erase(g)
	return str(common.keys()[0]) if common.size() == 1 else ""

# The game a server was last seen running, kept per address in goanna.cfg,
# so Join Game can hand that game's installed materials to set_texture_path
# before connecting, which is the only time a pack can be given.
static func _server_key(address: String) -> String:
	var key := ""
	for c in address.to_lower():
		key += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "_"
	return key

static func remember_game(address: String, game: String, path := CFG_PATH) -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)
	if str(cfg.get_value("server_games", _server_key(address), "")) == game:
		return
	cfg.set_value("server_games", _server_key(address), game)
	cfg.save(path)

static func remembered_game(address: String, path := CFG_PATH) -> String:
	var cfg := ConfigFile.new()
	cfg.load(path)
	return str(cfg.get_value("server_games", _server_key(address), ""))

# Stems a bundle cannot be queued on, because the catalogue does not agree on
# which game they belong to. Mineclonia and Minetest Game both ship a
# default_cobble, so that name is evidence for neither, and queueing on it
# would fetch a hundred megabytes of material maps that
# AssetStore.installed_for_game then ignores. Filtering by game instead is
# not open to us: a remote server's game is unknown at the launcher, so
# menu.gd leaves GOANNA_GAME empty for a remote join.
#
# Tranches of one game may legitimately list the same name, and there the
# answer is not in doubt, so a stem is only discounted when the bundles
# providing it have no game in common.
static func ambiguous_stems(bundles: Array) -> Dictionary:
	var counts := {}
	for bundle in bundles:
		for stem in bundle.get("provides", []):
			var stem_name := str(stem)
			counts[stem_name] = int(counts.get(stem_name, 0)) + 1
	# Only a name more than one bundle provides can be in doubt, and a
	# catalogue of a few thousand names holds a few dozen of those, so the
	# game sets are intersected for those alone.
	var agreed := {}
	for bundle in bundles:
		var games := {}
		for game in bundle.get("games", []):
			games[str(game)] = true
		for stem in bundle.get("provides", []):
			var stem_name := str(stem)
			if int(counts[stem_name]) < 2:
				continue
			if not agreed.has(stem_name):
				agreed[stem_name] = games.duplicate()
				continue
			var kept: Dictionary = agreed[stem_name]
			for game in kept.keys():
				if not games.has(game):
					kept.erase(game)
	var result := {}
	for stem_name in agreed:
		if (agreed[stem_name] as Dictionary).is_empty():
			result[stem_name] = true
	return result

# The bundles an announcement asks for, in catalogue order.
static func bundles_for_stems(bundles: Array, names: Dictionary,
		ambiguous: Dictionary) -> Array:
	var result := []
	for bundle in bundles:
		for stem in bundle.get("provides", []):
			var stem_name := str(stem)
			if names.has(stem_name) and not ambiguous.has(stem_name):
				result.append(bundle)
				break
	return result

# Bundle IDs no announcement can ever ask for, because every name they
# provide is one another game's bundle also provides, or because they provide
# nothing. That is a fault in the catalogue rather than in a connection, and
# its symptom is silence, so it is reported rather than left to be noticed
# when a bundle never arrives.
static func unreachable_bundles(bundles: Array, ambiguous: Dictionary) -> Array:
	var result := []
	for bundle in bundles:
		var reachable := false
		for stem in bundle.get("provides", []):
			if not ambiguous.has(str(stem)):
				reachable = true
				break
		if not reachable:
			result.append(str(bundle.get("id", "")))
	return result

# Whether some version of this bundle is installed: only those are upgraded
# from the menu, since a bundle a player never used may be for another game.
static func _has_any_version(id: String) -> bool:
	var dir := AssetStore.root().path_join(id)
	for version in DirAccess.get_directories_at(dir):
		if FileAccess.file_exists(dir.path_join(version).path_join("manifest.json")):
			return true
	return false

func _installed(bundle: Dictionary) -> bool:
	return FileAccess.file_exists(AssetStore.root().path_join(str(bundle.id)).path_join(
		str(bundle.version)).path_join("manifest.json"))

func _on_catalogue(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("Enhanced-material catalogue could not be downloaded; continuing without updates.")
		_settle()
		return
	catalogue = AssetStore.parse_catalogue(body.get_string_from_utf8())
	if catalogue.is_empty():
		push_warning("Enhanced-material catalogue is invalid; continuing without updates.")
		_settle()
		return
	# Bundles can be large and slow; only the catalogue is held to a timeout.
	_http.timeout = 0.0
	if upgrade_installed:
		for bundle in newest_only(catalogue.bundles):
			if _has_any_version(str(bundle.id)) and not _installed(bundle):
				_queue.append(bundle)
		_download_next()

func _download_next() -> void:
	if _queue.is_empty() or _http == null:
		return
	_current = _queue.pop_front()
	var downloads := AssetStore.root().path_join("downloads")
	DirAccess.make_dir_recursive_absolute(downloads)
	var target := downloads.path_join("%s-%s.zip.part" % [_current.id, _current.version])
	# _on_bundle calls this again for the next bundle in the queue, by which
	# time the catalogue handler is long gone and this one is already on, so
	# both sides have to be idempotent: Godot pushes an error for
	# disconnecting a connection that is not there and for connecting one
	# that already is. A Kythen server queues three bundles at once.
	if _http.request_completed.is_connected(_on_catalogue):
		_http.request_completed.disconnect(_on_catalogue)
	if not _http.request_completed.is_connected(_on_bundle):
		_http.request_completed.connect(_on_bundle)
	_http.download_file = target
	_current["target"] = target
	var url := str(_current.url)
	if not url.begins_with("http://") and not url.begins_with("https://"):
		url = _catalogue_url.get_base_dir().path_join(url)
	if _http.request(url) != OK:
		push_warning("Could not start enhanced-material download.")

func _on_bundle(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	var target := str(_current.get("target", ""))
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var error := AssetStore.install_archive(target, str(_current.sha256))
		if error != "":
			push_warning(error)
		else:
			installed_now.append(str(_current.id))
			bundle_installed.emit(str(_current.id))
	else:
		push_warning("Enhanced-material download failed; it will be retried on a later connection.")
	if target != "":
		DirAccess.remove_absolute(target)
	_current = {}
	_http.download_file = ""
	if _queue.is_empty():
		_settle()
	_download_next()
