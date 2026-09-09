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
	for bundle in catalogue.bundles:
		if _installed(bundle):
			continue
		for stem in bundle.get("provides", []):
			if names.has(str(stem)):
				_queue.append(bundle)
				break
	_download_next()

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
