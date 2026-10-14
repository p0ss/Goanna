# SPDX-License-Identifier: LGPL-2.1-or-later
## Join progress distinguishes local cache reads, transfers and preparation.
extends RefCounted

static func describe(status: Dictionary) -> Dictionary:
	var total := int(status.get("media_announced", 0))
	var available := int(status.get("media_received", 0))
	var cached := int(status.get("media_cached", 0))
	var downloaded := int(status.get("media_downloaded", 0))
	if not bool(status.get("media_cache_checked", false)):
		return {"title": "Loading cached media",
			"detail": "%d of %d files loaded from cache." % [cached, total],
			"progress": float(cached) / maxi(total, 1)}
	if available >= total:
		return {"title": "Preparing world",
			"detail": "Media ready: %d cached, %d downloaded. Preparing textures and models." % [cached, downloaded],
			"progress": 1.0}
	var needed := maxi(total - cached, 1)
	return {"title": "Downloading media",
		"detail": "%d of %d files downloaded; %d loaded from cache." % [downloaded, needed, cached],
		"progress": float(downloaded) / needed}
