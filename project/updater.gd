# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Updates Goanna itself from its GitHub releases, so a fix does not mean every
# player going back to GitHub to download the client again.
#
# A release carries the zip for each platform, a manifest naming each zip's
# size and SHA-256, and the manifest's signature, made with the maintainer's
# private key by tools/sign-release.sh. This checks the signature against the
# public key built into Goanna (res://update_key.pub.pem) before it trusts
# anything in the manifest, and the zip against the manifest before it
# unpacks anything. So an update installs only if the maintainer signed it,
# even if the GitHub account or the download were tampered with. It never
# installs a version that is not newer than the running one, so an old signed
# manifest cannot roll a player back.
#
# Only a packaged release updates: the package writes Goanna/version.json
# (tools/package-release.sh), and a source checkout has none. The update
# replaces the package's files in place, the running program and library
# included, by renaming each old file aside and moving the new one in, which
# both Linux and Windows allow while they run. The renamed files are deleted
# on the next start. Worlds, settings and materials live in Goanna's data
# folder, not the package, and are not touched.
extends Node

signal state_changed

const LocalServer := preload("res://local_server.gd")
const RELEASES_API := "https://api.github.com/repos/p0ss/Goanna/releases?per_page=15"
const KEY_PATH := "res://update_key.pub.pem"
const CFG_PATH := "user://goanna.cfg"
# How long a "no update" answer is trusted before GitHub is asked again. The
# API allows 60 unauthenticated requests an hour per address.
const RECHECK_S := 6 * 3600
const OLD_SUFFIX := ".goanna-old"

# idle, checking, available, downloading, installing, installed, failed, none
var state := "idle"
var message := ""
var available := {}          # the verified manifest, plus "notes"
var current_version := ""
var _http: HTTPRequest
var _api_url := RELEASES_API


# The running package's version, or "" for a source checkout.
static func package_dir() -> String:
	return OS.get_executable_path().get_base_dir()

static func installed_version() -> String:
	var info = JSON.parse_string(FileAccess.get_file_as_string(package_dir().path_join("version.json")))
	return str(info.get("version", "")) if info is Dictionary else ""

static func platform() -> String:
	return "windows" if OS.get_name() == "Windows" else "linux"

# "v0.10.0-alpha" -> [0, 10, 0]; [] when it is not a version.
static func parse_version(tag: String) -> Array:
	var core := tag.trim_prefix("v").get_slice("-", 0)
	var parts := core.split(".")
	if parts.size() != 3:
		return []
	var out := []
	for p in parts:
		if not p.is_valid_int():
			return []
		out.append(int(p))
	return out

static func newer(a: String, b: String) -> bool:
	var x := parse_version(a)
	var y := parse_version(b)
	if x.is_empty() or y.is_empty():
		return false
	for i in 3:
		if x[i] != y[i]:
			return x[i] > y[i]
	return false

static func sha256_bytes(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()

# Whether `signature` is the maintainer's signature of `manifest`.
static func signature_valid(manifest: PackedByteArray, signature: PackedByteArray,
		key_pem: String) -> bool:
	var key := CryptoKey.new()
	if key_pem == "" or key.load_from_string(key_pem, true) != OK:
		return false
	return Crypto.new().verify(HashingContext.HASH_SHA256, sha256_bytes(manifest), signature, key)

static func _key_pem() -> String:
	# A test points this at its own key. Anything able to set this process's
	# environment can already run code as the player, so it opens nothing.
	var override := OS.get_environment("GOANNA_UPDATE_KEY")
	return FileAccess.get_file_as_string(override if override != "" else KEY_PATH)


func _ready() -> void:
	current_version = installed_version()
	cleanup_old(package_dir())
	if OS.get_environment("GOANNA_UPDATE_API") != "":
		_api_url = OS.get_environment("GOANNA_UPDATE_API")
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)


# Ask GitHub for the newest release, unless asked recently or turned off.
func check(force := false) -> void:
	if current_version == "" or state in ["checking", "downloading", "installing", "installed"]:
		return
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	if not bool(cfg.get_value("updates", "check", true)) and not force:
		return
	var last := int(cfg.get_value("updates", "last_check", 0))
	if not force and str(cfg.get_value("updates", "last_result", "")) == "none:" + current_version \
			and Time.get_unix_time_from_system() - last < RECHECK_S:
		return
	_set_state("checking", "")
	var releases = await _get_json(_api_url)
	if not releases is Array:
		_set_state("failed", "Could not reach GitHub to look for updates.")
		return
	for release in releases:
		if not release is Dictionary or bool(release.get("draft", false)):
			continue
		var tag := str(release.get("tag_name", ""))
		if not tag.begins_with("v") or not newer(tag, current_version):
			continue
		var urls := {}
		for asset in release.get("assets", []):
			urls[str(asset.get("name", ""))] = str(asset.get("browser_download_url", ""))
		if not urls.has("manifest.json") or not urls.has("manifest.json.sig"):
			continue
		var manifest := await _get_bytes(urls["manifest.json"])
		var signature := await _get_bytes(urls["manifest.json.sig"])
		if not signature_valid(manifest, signature, _key_pem()):
			_set_state("failed", "The update to %s is not signed by Goanna's maintainer, so it was not offered." % tag)
			return
		var info = JSON.parse_string(manifest.get_string_from_utf8())
		if not info is Dictionary or str(info.get("version", "")) != tag \
				or not (info.get("assets", {}) as Dictionary).has(platform()):
			continue
		info["notes"] = str(release.get("body", "")).get_slice("\n\n", 1).strip_edges()
		available = info
		_set_state("available", "Goanna %s is ready." % tag)
		return
	cfg.set_value("updates", "last_check", int(Time.get_unix_time_from_system()))
	cfg.set_value("updates", "last_result", "none:" + current_version)
	cfg.save(CFG_PATH)
	_set_state("none", "Goanna %s is up to date." % current_version)


# Download, check and install the available update. Restarts into it unless
# `restart` is false.
func install(restart := true) -> void:
	if state != "available":
		return
	var asset: Dictionary = available["assets"][platform()]
	var root := package_dir().get_base_dir()
	if not _writable(root):
		_set_state("failed", "Goanna cannot write to %s, where it is installed. Download %s from the releases page instead." % [root, available["version"]])
		return
	var work := ProjectSettings.globalize_path("user://updates")
	LocalServer._remove_tree(work)
	DirAccess.make_dir_recursive_absolute(work)
	var archive := work.path_join("update.zip")
	_set_state("downloading", "Downloading Goanna %s (%.0f MB) ..." % [available["version"], int(asset["bytes"]) / 1000000.0])
	_http.download_file = archive
	_http.request(str(asset["url"]))
	var reply: Array = await _http.request_completed
	_http.download_file = ""
	if reply[0] != HTTPRequest.RESULT_SUCCESS or reply[1] != 200:
		_set_state("failed", "The download failed (HTTP %d). Check your connection and try again." % reply[1])
		return
	_set_state("installing", "Checking and installing ...")
	if FileAccess.get_sha256(archive).to_lower() != str(asset["sha256"]).to_lower():
		_set_state("failed", "The download did not match the signed manifest, so it was discarded.")
		LocalServer._remove_tree(work)
		return
	var unpacked := LocalServer._unpack_one_folder(archive, work)
	DirAccess.remove_absolute(archive)
	if unpacked.has("error"):
		_set_state("failed", str(unpacked["error"]))
		return
	var error := swap_in(str(unpacked["folder"]), root)
	LocalServer._remove_tree(work)
	if error != "":
		_set_state("failed", error)
		return
	_set_state("installed", "Goanna %s is installed." % available["version"])
	if restart and OS.get_environment("GOANNA_UPDATE_NO_RESTART") == "":
		OS.create_process(OS.get_executable_path(), OS.get_cmdline_args())
		get_tree().quit()


# Moves every file under `source` into the same place under `root`, renaming
# any file already there aside first. All or nothing: a failure part way puts
# back every file it had replaced. Returns "" or an error for the player.
static func swap_in(source: String, root: String) -> String:
	var files: Array = []
	_list_files(source, "", files)
	var done: Array = []   # [target, had_old]
	for rel in files:
		var target := root.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var had_old := FileAccess.file_exists(target)
		if had_old:
			DirAccess.remove_absolute(target + OLD_SUFFIX)
			if DirAccess.rename_absolute(target, target + OLD_SUFFIX) != OK:
				_roll_back(done)
				return "Could not replace %s." % target
		if DirAccess.rename_absolute(source.path_join(rel), target) != OK:
			if had_old:
				DirAccess.rename_absolute(target + OLD_SUFFIX, target)
			_roll_back(done)
			return "Could not install %s." % target
		done.append([target, had_old])
	# A zip does not keep the bit that lets a program run.
	if OS.get_name() != "Windows":
		for rel in files:
			var name := str(rel).get_file()
			if name == "Goanna.x86_64" or name == "luantiserver":
				FileAccess.set_unix_permissions(root.path_join(rel), 493)
	return ""

static func _roll_back(done: Array) -> void:
	for i in range(done.size() - 1, -1, -1):
		var target: String = done[i][0]
		DirAccess.remove_absolute(target)
		if done[i][1]:
			DirAccess.rename_absolute(target + OLD_SUFFIX, target)

static func _list_files(base: String, rel: String, out: Array) -> void:
	var d := DirAccess.open(base.path_join(rel))
	if d == null:
		return
	for name in d.get_files():
		out.append(rel.path_join(name) if rel != "" else name)
	for name in d.get_directories():
		_list_files(base, rel.path_join(name) if rel != "" else name, out)

# The files the last update renamed aside, gone now that nothing runs them.
static func cleanup_old(package: String) -> void:
	if installed_version() == "":
		return
	var found: Array = []
	_list_files(package.get_base_dir(), "", found)
	for rel in found:
		if str(rel).ends_with(OLD_SUFFIX):
			DirAccess.remove_absolute(package.get_base_dir().path_join(rel))

static func _writable(dir: String) -> bool:
	var probe := dir.path_join(".goanna-write-test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f = null
	DirAccess.remove_absolute(probe)
	return true


func _get_json(url: String) -> Variant:
	var body := await _get_bytes(url)
	return JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null

func _get_bytes(url: String) -> PackedByteArray:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.cancel_request()
	if _http.request(url, ["Accept: application/vnd.github+json", "User-Agent: Goanna"]) != OK:
		return PackedByteArray()
	var reply: Array = await _http.request_completed
	return reply[3] if reply[0] == HTTPRequest.RESULT_SUCCESS and reply[1] == 200 else PackedByteArray()

func _set_state(new_state: String, text: String) -> void:
	state = new_state
	message = text
	state_changed.emit()
