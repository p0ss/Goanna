# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless checks for Goanna's own updater (updater.gd): which versions count
# as newer, that only the maintainer's signature is accepted, and that the
# file swap is all or nothing. Nothing is downloaded and nothing is run.
extends SceneTree

const Updater := preload("res://updater.gd")
var failures := 0
var base := ""


func _initialize() -> void:
	base = OS.get_temp_dir().path_join("goanna-updater-%d" % OS.get_process_id())
	_versions()
	_signatures()
	_swap()
	_swap_rolls_back()
	_remove(base)
	if failures == 0:
		print("updater: PASS")
		quit(0)
	else:
		quit(1)


func _versions() -> void:
	_assert(Updater.newer("v0.11.0-alpha", "v0.10.0-alpha"), "0.11 is newer than 0.10")
	_assert(Updater.newer("v0.10.1", "v0.10.0-alpha"), "a patch release is newer")
	_assert(Updater.newer("v1.0.0", "v0.99.9"), "a major release is newer")
	_assert(not Updater.newer("v0.10.0-alpha", "v0.10.0-alpha"), "the same version is not newer")
	_assert(not Updater.newer("v0.9.0-alpha", "v0.10.0-alpha"), "0.9 is not newer than 0.10")
	_assert(not Updater.newer("assets-2026.10.1", "v0.10.0-alpha"), "an asset epoch is not a version")
	_assert(not Updater.newer("v0.11.0", ""), "nothing is newer than an unknown version")


func _signatures() -> void:
	# A key made here, standing in for the maintainer's.
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var public := key.save_to_string(true)
	var manifest := '{"version": "v9.9.9"}'.to_utf8_buffer()
	var signature := crypto.sign(HashingContext.HASH_SHA256, Updater.sha256_bytes(manifest), key)
	_assert(Updater.signature_valid(manifest, signature, public), "a good signature is accepted")
	var altered := manifest.duplicate()
	altered[3] = 65
	_assert(not Updater.signature_valid(altered, signature, public), "an altered manifest is refused")
	var other := crypto.generate_rsa(2048)
	var forged := crypto.sign(HashingContext.HASH_SHA256, Updater.sha256_bytes(manifest), other)
	_assert(not Updater.signature_valid(manifest, forged, public), "another key's signature is refused")
	_assert(not Updater.signature_valid(manifest, signature, ""), "no key refuses everything")
	_assert(FileAccess.get_file_as_string(Updater.KEY_PATH).begins_with("-----BEGIN PUBLIC KEY-----"),
		"the built in key is a public key")


func _swap() -> void:
	var root := base.path_join("swap/root")
	var new := base.path_join("swap/new")
	_file(root.path_join("Goanna/Goanna.x86_64"), "old program")
	_file(root.path_join("Goanna/version.json"), "old")
	_file(root.path_join("Goanna/keep.txt"), "untouched")
	_file(new.path_join("Goanna/Goanna.x86_64"), "new program")
	_file(new.path_join("Goanna/version.json"), "new")
	_file(new.path_join("luanti/textures/base/pack/a.png"), "added")
	_assert(Updater.swap_in(new, root) == "", "the swap succeeded")
	_assert(FileAccess.get_file_as_string(root.path_join("Goanna/Goanna.x86_64")) == "new program",
		"the program was replaced")
	_assert(FileAccess.get_file_as_string(root.path_join("Goanna/Goanna.x86_64" + Updater.OLD_SUFFIX)) == "old program",
		"the old program was renamed aside")
	_assert(FileAccess.get_file_as_string(root.path_join("Goanna/keep.txt")) == "untouched",
		"a file the update does not carry is left alone")
	_assert(FileAccess.file_exists(root.path_join("luanti/textures/base/pack/a.png")),
		"a new file was added")


func _swap_rolls_back() -> void:
	var root := base.path_join("rollback/root")
	var new := base.path_join("rollback/new")
	_file(root.path_join("a.txt"), "old a")
	_file(root.path_join("b/c.txt"), "old c")
	_file(new.path_join("a.txt"), "new a")
	_file(new.path_join("b/c.txt"), "new c")
	# A directory where a file must go makes that file's move fail.
	DirAccess.remove_absolute(root.path_join("b/c.txt"))
	DirAccess.make_dir_recursive_absolute(root.path_join("b/c.txt/blocked"))
	_assert(Updater.swap_in(new, root) != "", "a failed swap reports an error")
	_assert(FileAccess.get_file_as_string(root.path_join("a.txt")) == "old a",
		"a failed swap puts back the files it had replaced")


func _file(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _remove(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for name in d.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in d.get_directories():
		_remove(path.path_join(name))
	DirAccess.remove_absolute(path)


func _assert(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("updater: " + message)
