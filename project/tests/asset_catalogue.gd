extends SceneTree

const AssetStore := preload("res://asset_store.gd")

# The catalogue is served from the repository, not from the release that
# carries the archives, so a bundle url has nothing to resolve against. These
# are the invariants that makes that safe; asset_updater.gd only skips its
# base-directory join for a url that is already absolute.
func _fail(message: String) -> void:
	printerr("asset catalogue: FAIL: ", message)
	quit(1)

func _init() -> void:
	var bootstrap = JSON.parse_string(
			FileAccess.get_file_as_string("res://bootstrap_assets.json"))
	if bootstrap is not Dictionary:
		_fail("res://bootstrap_assets.json is not readable JSON")
		return
	var url := str(bootstrap.get("catalogue_url", ""))
	if not url.begins_with("https://"):
		_fail("catalogue_url is %s; it must be an absolute https url" % [url])
		return

	var path := OS.get_environment("GOANNA_TEST_CATALOGUE")
	if path == "":
		path = "../asset_bundles/catalogue.json"
	if path.is_relative_path():
		path = ProjectSettings.globalize_path("res://").path_join(path)
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		_fail("could not read the catalogue at %s" % [path])
		return
	var catalogue := AssetStore.parse_catalogue(text)
	if catalogue.is_empty():
		_fail("the catalogue does not parse against %s" % [AssetStore.CATALOGUE_SCHEMA])
		return
	if catalogue.bundles.is_empty():
		_fail("the catalogue lists no bundles")
		return
	for bundle in catalogue.bundles:
		var bundle_url := str(bundle.get("url", ""))
		if not bundle_url.begins_with("https://"):
			_fail("%s has a relative url %s, which would resolve against the "
					% [bundle.id, bundle_url]
					+ "catalogue's own location rather than the release")
			return
	print("asset catalogue: PASS, %d bundles, all absolute" % catalogue.bundles.size())
	quit()
