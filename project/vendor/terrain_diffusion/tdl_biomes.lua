-- Turning elevation, climate and slope into a surface material.
--
-- A Lua port of BiomeClassifier.java from the upstream Minecraft mod, which is
-- itself a port of _classify_biome in minecraft_api.py. The derived quantities
-- are theirs and are worth keeping: potential evapotranspiration from
-- temperature, an aridity index from that, a growing season length from
-- temperature and its seasonality, and tree cover from the two together. It is
-- a Koppen style classification rather than a lookup table, which is why the
-- results follow coastlines and rain shadows properly.
--
-- What differs: this returns a pair of node names for a Luanti game rather than
-- a Minecraft biome id, and the noise perturbations upstream applies to
-- temperature and precipitation are left out for now, so biome edges here are
-- cleaner than they should be.

local classify = {}

-- How fast it gets colder with height, in degrees per kilometre. The real
-- figure is about 6.5 and the model's own temperature channel already carries
-- some of that, so this double counts a little on purpose. Altitude is the one
-- climate gradient a 62 km world genuinely has: real country that size holds
-- one climate horizontally, but three kilometres of relief runs from temperate
-- valley floor to permanent snow, and that is where the variety in a world this
-- size has to come from.
local lapse_rate = tonumber(core.settings:get("tdl_lapse_rate")) or 6.0

-- How much wetter it gets with height. Air rising over ground drops its water,
-- which is why mountains are green and the plains behind them are not.
local orographic = tonumber(core.settings:get("tdl_orographic")) or 0.5

local function clamp(value, low, high)
        if value < low then return low end
        if value > high then return high end
        return value
end

-- Height first, before anything reads temperature or rainfall. Exposed because
-- the palette needs the same adjusted figures: a game's biomes are placed in
-- heat and humidity, and asking for them at the valley floor's temperature
-- while standing on a peak gets a valley floor's biome on a mountain.
function classify.adjust(elevation, temp, precip)
        local altitude = math.max(0, elevation)
        return temp - lapse_rate * altitude / 1000,
                math.max(0, precip) * (1 + orographic * altitude / 2000)
end

-- Returns a material name. Mapping to nodes happens in the mapgen script, so
-- this file stays free of any particular game's node names.
function classify.material(elevation, slope, temp, t_season, precip, p_cv,
                           drainage_km2, hand_m)
        if elevation < 0 then
                if temp < -5 then return "ocean_frozen" end
                if temp < 5 then return "ocean_cold" end
                if temp >= 20 then return "ocean_warm" end
                return "ocean"
        end

        temp, precip = classify.adjust(elevation, temp, precip)
        local altitude = math.max(0, elevation)
        local t_std = t_season / 100
        local t_eff = math.max(0, temp + 0.5 * t_std)
        local pet = math.max(250, 250 + 25 * t_eff + 0.7 * t_eff * t_eff)
        local aridity = precip / math.max(1, pet)
        local season_penalty = 1 - 0.35 * math.min(1, p_cv / 100)
        local tree_moisture = aridity * season_penalty

        -- Water the ground has access to that did not fall on it. A river flat
        -- and the hillside above it get the same rain, and look nothing alike,
        -- because one of them is sitting on the water table. Height above the
        -- nearest drainage is what separates them, weighted by how much country
        -- is upstream: a gully carries less than a river.
        --
        -- This is what puts a green ribbon through a desert.
        if drainage_km2 and hand_m then
                -- Falls off over about thirty metres above the water, and
                -- counts for nothing behind a gully: it takes real catchment
                -- to keep a valley floor green through a dry season. A hundred
                -- square kilometres upstream is worth the full bonus.
                local low = clamp(1 - hand_m / 30, 0, 1)
                local fed = clamp(math.log(drainage_km2 + 1) / math.log(2) / 7, 0, 1)
                local riparian = low * fed
                tree_moisture = tree_moisture + 1.5 * riparian
        end

        -- Days above 5 C, from a sinusoidal year with the given seasonality.
        local amplitude = t_std * 1.414
        local growing_season
        if amplitude < 0.1 then
                growing_season = temp > 5 and 365 or 0
        else
                local x = (5 - temp) / amplitude
                if x <= -1 then
                        growing_season = 365
                elseif x >= 1 then
                        growing_season = 0
                else
                        growing_season = 365 * (0.5 - math.asin(clamp(x, -1, 1)) / math.pi)
                end
        end

        local gs_factor = clamp((growing_season - 60) / 90, 0, 1)
        local eff_tree_moisture = tree_moisture * gs_factor

        local moisture_factor = clamp((tree_moisture - 0.35) / 0.45, 0, 1)
        local bare_threshold = 0.7 + 0.49 * moisture_factor

        local trees_none = eff_tree_moisture < 0.2
        local too_arid = tree_moisture < 0.05
        local too_cold = growing_season < 60
        local barren = too_arid or too_cold
        local trees_sparse = not trees_none and eff_tree_moisture < 0.5
        local trees_forest = not trees_none and eff_tree_moisture >= 0.5 and eff_tree_moisture < 0.8
        local trees_dense = not trees_none and eff_tree_moisture >= 0.8 and eff_tree_moisture < 1.3
        local trees_rain = not trees_none and eff_tree_moisture >= 1.3

        local slope_medium = slope >= 0.62 and slope < bare_threshold
        local slope_bare = slope >= bare_threshold
        if slope_medium then
                if trees_forest or trees_dense or trees_rain then
                        trees_sparse = true
                end
                trees_forest = false
                trees_dense = false
                trees_rain = false
        end
        if slope_bare then
                trees_none = true
                trees_sparse = false
                trees_forest = false
                trees_dense = false
                trees_rain = false
        end

        local steep = slope > 0.78
        local has_snow = temp < 0 and precip > 150 and not steep

        local mountains = altitude > 2500
        local lowland = altitude < 200
        local frozen = temp < -5
        local cold = temp >= -5 and temp < 5
        local cool = temp >= 5 and temp < 12
        local temperate = temp >= 12 and temp < 20
        local warm = temp >= 20 and temp < 26
        local hot = temp >= 26

        -- Waterlogged ground, before the general rules get to it. A valley floor
        -- sitting on the water table is a swamp whatever the rainfall says,
        -- which is the other thing terrain can tell you that climate cannot.
        if hand_m and hand_m < 5 and altitude < 400 and temp > 2
                and tree_moisture > 0.30 and slope < 0.12 then
                return "swamp"
        end

        if slope_bare and not mountains then
                return has_snow and "frozen_peaks" or "stony"
        end

        if mountains then
                if slope_bare then
                        return has_snow and "frozen_peaks" or "stony"
                elseif has_snow then
                        if trees_none then return "snowy_slopes" end
                        return "snowy_taiga"
                elseif trees_none then
                        if barren then return "stony" end
                        if tree_moisture < 0.35 or precip < 350 then return "grove" end
                        return "plains"
                elseif trees_sparse or trees_forest then
                        return "taiga"
                else
                        return "taiga"
                end
        end

        if has_snow and trees_none then
                return "snowy_plains"
        elseif has_snow then
                return "snowy_taiga"
        elseif trees_none then
                if warm or hot then
                        if precip < 120 and p_cv > 80 then return "badlands" end
                        return "desert"
                end
                if barren and not lowland and (cold or cool or temperate) then return "grove" end
                if tree_moisture < 0.35 or precip < 350 then return "grove" end
                return "plains"
        elseif trees_sparse or trees_forest then
                if hot then return "jungle" end
                if warm and trees_sparse and not slope_medium then return "savanna" end
                if warm or temperate then return "forest" end
                return "taiga"
        elseif trees_dense then
                if hot then return "jungle" end
                if warm and lowland then return "swamp" end
                if cool or cold then return "taiga" end
                return "forest"
        else
                if hot or (warm and temp >= 18 and t_std < 5) then return "jungle" end
                if lowland then return "swamp" end
                if cool or cold then return "taiga" end
                return "forest"
        end
end

tdl_classify = classify
