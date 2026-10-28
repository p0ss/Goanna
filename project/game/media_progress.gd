# SPDX-License-Identifier: LGPL-2.1-or-later
## Join progress distinguishes local cache reads, transfers and preparation.
extends RefCounted

static func describe(status: Dictionary) -> Dictionary:
	var total := int(status.get("media_announced", 0))
	var available := int(status.get("media_received", 0))
	var cached := int(status.get("media_cached", 0))
	var downloaded := int(status.get("media_downloaded", 0))
	if total <= 0 and not bool(status.get("media_cache_checked", false)):
		return {"title": "Receiving world definitions",
			"detail": "Waiting for the server to announce its media.",
			"progress": 0.0, "indeterminate": true}
	if not bool(status.get("media_cache_checked", false)):
		return {"title": "Loading cached media",
			"detail": "%d of %d files loaded from cache." % [cached, total],
			"progress": float(cached) / maxi(total, 1), "indeterminate": false}
	if available >= total:
		return {"title": "Preparing world",
			"detail": "%s. Media ready: %d cached, %d downloaded." % [
				status.get("preparation_stage", "Preparing textures and models"), cached, downloaded],
			"progress": float(status.get("preparation_done", 0)) / maxi(int(status.get("preparation_total", 0)), 1),
			"indeterminate": int(status.get("preparation_total", 0)) <= 0}
	var needed := maxi(total - cached, 1)
	return {"title": "Downloading media",
		"detail": "%d of %d files downloaded; %d loaded from cache." % [downloaded, needed, cached],
		"progress": float(downloaded) / needed, "indeterminate": false}
