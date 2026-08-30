# Goanna: the shared authorities behind the sky, the fog and the clouds.
#
# Before this class, every lighting band in _apply_sky was a ramp over the
# raw astronomical sun elevation with its own hand tuned constants, each
# calibrated against a symptom in isolation. The picture disagreed with
# itself at dawn and dusk because the layers could not: the cloud undersides
# and the glow around the disc were unrelated luminances, and the fog
# between the camera and a ridge glowed with a beam that never reached it.
#
# Two ideas replace that clock (see docs/sky-orchestration.md):
#
# - The beam. One function of solar altitude gives the transmitted sun's
#   hue and its strength after the grazing path through the air. Every warm
#   term consumes it: the disc tint, the dome's haze band, the cloud
#   undersides, the fog's sun scatter, the sun light itself. Two layers can
#   no longer disagree about how bright the sun is.
#
# - Per layer horizons. Each layer hands beam_strength its own altitude,
#   relative to the horizon that layer actually sees. The ground uses the
#   terrain ridge toward the sun's azimuth; the cloud deck sees over that
#   ridge by its own altitude, so it lights first and darkens last by
#   geometry rather than by a constant; the dome's haze band is air beyond
#   and above the ridge, so it answers only to the false horizon, lifted by
#   AIR_LIFT because high air stays sunlit well after ground level is dark.
#
# The hue script stays keyed to the astronomical elevation: the colour of
# twilight is a property of the whole air mass, not of any one horizon.
# Only the strength is per layer.
#
# No class_name on purpose: consumers preload this script, because global
# class registration needs an editor import pass and the offline fixtures
# run scenes straight from the command line.
extends RefCounted

# The colour of the transmitted sun as it crosses the horizon: white high
# up, gold approaching it, hot orange upon it, then pink, magenta and night
# blue below. Grown from the old cloud twilight stop table; the top entries
# carry what sun.light_color's warm lerp used to, so the land's golden hour
# keeps its hue.
const BEAM_STOPS := [
	[0.32, Color(1.0, 0.98, 0.94)],
	[0.16, Color(1.0, 0.86, 0.70)],
	[0.06, Color(1.0, 0.78, 0.45)],
	[0.0, Color(1.0, 0.52, 0.22)],
	[-0.06, Color(0.95, 0.38, 0.42)],
	[-0.16, Color(0.62, 0.28, 0.48)],
	[-0.30, Color(0.30, 0.22, 0.42)],
	[-0.42, Color(0.14, 0.14, 0.24)],
]

# How much higher the high air's effective horizon-relative altitude sits
# than the ground's: the dome's haze band keeps its beam until the sun is
# this far below the false horizon, which is the predawn and the afterglow.
const AIR_LIFT := 0.25


static func beam_tint(elev: float) -> Color:
	var stops := BEAM_STOPS
	if elev >= stops[0][0]:
		return stops[0][1]
	if elev <= stops[-1][0]:
		return stops[-1][1]
	for i in stops.size() - 1:
		var a: Array = stops[i]
		var b: Array = stops[i + 1]
		if elev <= a[0] and elev >= b[0]:
			return (a[1] as Color).lerp(b[1], inverse_lerp(a[0], b[0], elev))
	return stops[-1][1]


# How much of the direct beam reaches a layer whose sun altitude, relative
# to that layer's own horizon, is `alt`. One shared ramp: a little light
# leaks before the crest (the disc has diameter, the crest has notches) and
# it is full strength a few degrees above.
static func beam_strength(alt: float) -> float:
	return smoothstep(-0.05, 0.04, alt)


# The premultiplied beam a layer is lit by. Hue from the astronomical
# elevation, strength from the layer's own altitude.
static func beam(elev: float, alt: float) -> Color:
	return beam_tint(elev) * beam_strength(alt)


# The day/night bands, unchanged shapes from the old _apply_sky, now taking
# whichever altitude the caller's layer answers to.
#   day        the full daylight ramp
#   night      the ground night ramp
#   dawn       the narrow band either side of the crossing (sky colours)
#   tw         the wide twilight window the colour script plays out over
#   dusk_hold  the golden hour hold on the sun's energy
static func bands(alt: float) -> Dictionary:
	var tw_rise: float = smoothstep(-0.42, -0.06, alt)
	var tw_fall: float = 1.0 - smoothstep(0.02, 0.28, alt)
	return {
		"day": smoothstep(-0.02, 0.18, alt),
		"night": smoothstep(0.02, -0.25, alt),
		"dawn": clampf(1.0 - absf(alt) / 0.22, 0.0, 1.0),
		"tw": clampf(tw_rise * tw_fall, 0.0, 1.0),
		"dusk_hold": smoothstep(-0.06, -0.005, alt) \
				* (1.0 - smoothstep(0.02, 0.10, alt)),
	}


# The cloud deck's horizon in sun elevation units: the angle the ridge
# subtends as seen from cloud altitude. Negative over open terrain (the
# deck sees past the horizon, so it lights first), positive only when the
# ridge tops the deck. Falls back to a flat world lead when nothing is
# known about the ridge.
static func cloud_horizon(ridge_h: float, ridge_dist: float, deck_h: float) -> float:
	if ridge_dist <= 1.0:
		return -0.20
	var dy := ridge_h - deck_h
	return clampf(dy / sqrt(ridge_dist * ridge_dist + dy * dy), -0.30, 0.30)
