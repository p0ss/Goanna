# SPDX-License-Identifier: MIT
extends Node

const AssetStore := preload("res://asset_store.gd")
const CFG_PATH := "user://goanna.cfg"

var client: Node
var catalogue := {}
var _catalogue_url := ""
var _http: HTTPRequest
var _queue: Array = []
var _current := {}
var _observed := false

func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	if not bool(cfg.get_value("settings", "asset_updates", true)):
		return
	_catalogue_url = OS.get_environment("GOANNA_ASSET_CATALOGUE_URL")
	if _catalogue_url == "":
		var bootstrap = JSON.parse_string(FileAccess.get_file_as_string("res://bootstrap_assets.json"))
		if bootstrap is Dictionary:
			_catalogue_url = str(bootstrap.get("catalogue_url", ""))
	if _catalogue_url == "":
		return
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_catalogue)
	_http.request(_catalogue_url)

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
	for bundle in bundles_for_stems(catalogue.bundles, names, ambiguous):
		if not _installed(bundle):
			_queue.append(bundle)
	_download_next()

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

func _installed(bundle: Dictionary) -> bool:
	return FileAccess.file_exists(AssetStore.root().path_join(str(bundle.id)).path_join(
		str(bundle.version)).path_join("manifest.json"))

func _on_catalogue(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("Enhanced-material catalogue could not be downloaded; continuing without updates.")
		return
	catalogue = AssetStore.parse_catalogue(body.get_string_from_utf8())
	if catalogue.is_empty():
		push_warning("Enhanced-material catalogue is invalid; continuing without updates.")

func _download_next() -> void:
	if _queue.is_empty() or _http == null:
		return
	_current = _queue.pop_front()
	var downloads := AssetStore.root().path_join("downloads")
	DirAccess.make_dir_recursive_absolute(downloads)
	var target := downloads.path_join("%s-%s.zip.part" % [_current.id, _current.version])
	_http.request_completed.disconnect(_on_catalogue)
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
		push_warning("Enhanced-material download failed; it will be retried on a later connection.")
	if target != "":
		DirAccess.remove_absolute(target)
	_current = {}
	_http.download_file = ""
	_download_next()
