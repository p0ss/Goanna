-- Reading the baked tile cache, and turning elevation and climate into a
-- surface. Loaded into both the main environment and the mapgen environment,
-- so it must not assume anything either one has that the other lacks.

tdl = {}

local worldpath = core.get_worldpath()
local cache_dir = worldpath .. "/terrain_diffusion"

-- Settings. Nodes per native pixel sets the horizontal scale, and the vertical
-- scale follows it, so terrain is not stretched. One native pixel is 30 m, so
-- four nodes per pixel is 7.5 m per node.
local nodes_per_pixel = tonumber(core.settings:get("tdl_nodes_per_pixel")) or 30
local sea_level = tonumber(core.settings:get("tdl_sea_level")) or 0
local detail_metres = tonumber(core.settings:get("tdl_detail_metres")) or 20

tdl.nodes_per_pixel = nodes_per_pixel
tdl.sea_level = sea_level

-- Deep ocean stands in for anything outside the baked region, so the world
-- ends in water rather than a wall of nothing.
local OUTSIDE_ELEVATION = -1200

local manifest
do
        local handle = io.open(cache_dir .. "/manifest.json", "rb")
        if handle then
                local raw = handle:read("*a")
                handle:close()
                manifest = core.parse_json(raw)
        end
end

tdl.manifest = manifest
tdl.available = manifest ~= nil

if not manifest then
        core.log("error", "[terrain_diffusion] no manifest at " .. cache_dir ..
                "/manifest.json, run server/bake.py against this world first")
        return
end

local TILE_PX = manifest.tile_px
local CLIMATE_PX = manifest.climate_px
local CLIMATE_STEP = TILE_PX / CLIMATE_PX
local PLANE_BYTES = TILE_PX * TILE_PX * 2
local NO_WATER = manifest.no_water or -32768
local DRAINAGE_FACTOR = manifest.drainage_factor or 100
local HAND_FACTOR = manifest.hand_factor or 1

if (manifest.format or 1) < 4 then
        core.log("error", "[terrain_diffusion] tile cache is format " ..
                tostring(manifest.format) .. ". The smooth water distance field " ..
                "arrived in format 4. Rebake with the current server/bake.py.")
end

local metres_per_node = manifest.native_resolution / nodes_per_pixel
tdl.metres_per_node = metres_per_node

local spawn_i = manifest.spawn_px[1]
local spawn_j = manifest.spawn_px[2]

local tile_i0 = manifest.tile_i0
local tile_j0 = manifest.tile_j0
local tile_i1 = tile_i0 + manifest.tiles - 1
local tile_j1 = tile_j0 + manifest.tiles - 1

local climate_factors = manifest.climate_factors

-- How much catchment a channel needs before it is worth carving a bed for,
-- straight from the bake so the mapgen never disagrees with the field it is
-- reading. Below this a "river" is really just a wet patch of ground, and
-- the flat area it is next to (a pond, a lake, the sea) has no channel to
-- speak of: its bed is whatever the heightmap says, not an invented profile.
tdl.min_drainage_km2 = manifest.min_drainage_km2 or 8.0

-- Tile cache. Tiles are decoded once into flat arrays and kept, bounded so a
-- long flight does not grow without limit. Each emerge thread has its own copy
-- of this, which is the price of the mapgen environment being isolated.
local MAX_CACHED_TILES = 6
local tiles = {}
local tile_order = {}

local function signed16(low, high)
        local value = low + high * 256
        if value >= 32768 then
                return value - 65536
        end
        return value
end

local function load_tile(ti, tj)
        local path = cache_dir .. "/tiles/t_" .. ti .. "_" .. tj .. ".bin"
        local handle = io.open(path, "rb")
        if not handle then
                return false
        end
        local raw = handle:read("*a")
        handle:close()
        if #raw < PLANE_BYTES * 3 then
                core.log("error", "[terrain_diffusion] short tile file " .. path)
                return false
        end

        local byte = string.byte

        local function read_plane(base, count, factor)
                local plane = {}
                local at = 1
                for offset = base + 1, base + count * 2, 2 do
                        local low, high = byte(raw, offset, offset + 1)
                        plane[at] = signed16(low, high) / factor
                        at = at + 1
                end
                return plane
        end

        local cells = TILE_PX * TILE_PX
        local small = CLIMATE_PX * CLIMATE_PX
        local small_bytes = small * 2

        local elevation = read_plane(0, cells, 1)
        local water = read_plane(PLANE_BYTES, cells, 1)
        local water_distance = read_plane(PLANE_BYTES * 2, cells, 1)

        local climate = {}
        local base = PLANE_BYTES * 3
        for channel = 1, 4 do
                climate[channel] = read_plane(base, small, climate_factors[channel])
                base = base + small_bytes
        end
        local drainage = read_plane(base, small, DRAINAGE_FACTOR)
        base = base + small_bytes
        local hand = read_plane(base, small, HAND_FACTOR)

        local tile = {elevation = elevation, water = water,
                water_distance = water_distance,
                climate = climate, drainage = drainage, hand = hand}
        tiles[ti .. ":" .. tj] = tile
        tile_order[#tile_order + 1] = ti .. ":" .. tj
        if #tile_order > MAX_CACHED_TILES then
                tiles[table.remove(tile_order, 1)] = nil
        end
        return tile
end

local function get_tile(ti, tj)
        if ti < tile_i0 or ti > tile_i1 or tj < tile_j0 or tj > tile_j1 then
                return nil
        end
        local key = ti .. ":" .. tj
        local tile = tiles[key]
        if tile ~= nil then
                return tile
        end
        return load_tile(ti, tj) or nil
end

-- Elevation in metres at an integer native pixel.
local function pixel_elevation(pi, pj)
        local ti = math.floor(pi / TILE_PX)
        local tj = math.floor(pj / TILE_PX)
        local tile = get_tile(ti, tj)
        if not tile then
                return OUTSIDE_ELEVATION
        end
        local li = pi - ti * TILE_PX
        local lj = pj - tj * TILE_PX
        return tile.elevation[li * TILE_PX + lj + 1]
end

-- Two smooth fields describing where the water is: how far this point is from
-- the nearest of it, in metres, and what height that water sits at.
--
-- Nothing is carved into the baked elevation. Cutting channels at the model's
-- own resolution is what made rivers read as rectangles, because one pixel is
-- thirty metres square and at a metre a node that is a thirty by thirty gouge
-- with vertical sides. A distance field interpolates smoothly, so the mapgen
-- can cut a channel six metres across inside a thirty metre pixel, and put its
-- banks wherever the arithmetic says rather than on the pixel grid.
local function bilinear(plane_name, fi, fj, missing)
        local i0 = math.floor(fi)
        local j0 = math.floor(fj)
        local di = fi - i0
        local dj = fj - j0

        local function at(pi, pj)
                local ti = math.floor(pi / TILE_PX)
                local tj = math.floor(pj / TILE_PX)
                local tile = get_tile(ti, tj)
                if not tile then
                        return missing
                end
                return tile[plane_name][(pi - ti * TILE_PX) * TILE_PX
                        + (pj - tj * TILE_PX) + 1]
        end

        local v00, v01 = at(i0, j0), at(i0, j0 + 1)
        local v10, v11 = at(i0 + 1, j0), at(i0 + 1, j0 + 1)
        local top = v00 + (v01 - v00) * dj
        local bottom = v10 + (v11 - v10) * dj
        return top + (bottom - top) * di
end

function tdl.water_distance_at(fi, fj)
        return bilinear("water_distance", fi, fj, 30000)
end

function tdl.water_surface_at(fi, fj)
        return bilinear("water", fi, fj, -30000)
end

-- Bilinear elevation in metres at a fractional pixel position. The model works
-- at 30 m, so everything finer than that is interpolation, not new information.
function tdl.elevation_at(fi, fj)
        local i0 = math.floor(fi)
        local j0 = math.floor(fj)
        local di = fi - i0
        local dj = fj - j0

        local e00 = pixel_elevation(i0, j0)
        local e01 = pixel_elevation(i0, j0 + 1)
        local e10 = pixel_elevation(i0 + 1, j0)
        local e11 = pixel_elevation(i0 + 1, j0 + 1)

        -- Smoothstep rather than straight bilinear. Linear interpolation
        -- leaves a crease at every pixel boundary, and once the result is
        -- rounded to whole nodes those creases line up into contour stripes
        -- across the whole landscape.
        di = di * di * (3 - 2 * di)
        dj = dj * dj * (3 - 2 * dj)

        local top = e00 + (e01 - e00) * dj
        local bottom = e10 + (e11 - e10) * dj
        return top + (bottom - top) * di
end

-- Climate at a fractional pixel position, bilinear over the stored 1/8 grid.
-- Returns temperature (C), temperature seasonality, precipitation (mm/year)
-- and precipitation variability (percent).
function tdl.climate_at(fi, fj)
        local ti = math.floor(fi / TILE_PX)
        local tj = math.floor(fj / TILE_PX)
        local tile = get_tile(ti, tj)
        if not tile then
                return 4, 600, 900, 40
        end

        local ci = (fi - ti * TILE_PX) / CLIMATE_STEP - 0.5
        local cj = (fj - tj * TILE_PX) / CLIMATE_STEP - 0.5
        local i0 = math.floor(ci)
        local j0 = math.floor(cj)
        local di = ci - i0
        local dj = cj - j0

        local function clamp(v)
                if v < 0 then return 0 end
                if v > CLIMATE_PX - 1 then return CLIMATE_PX - 1 end
                return v
        end
        local ia, ib = clamp(i0), clamp(i0 + 1)
        local ja, jb = clamp(j0), clamp(j0 + 1)

        local out = {}
        for channel = 1, 4 do
                local plane = tile.climate[channel]
                local v00 = plane[ia * CLIMATE_PX + ja + 1]
                local v01 = plane[ia * CLIMATE_PX + jb + 1]
                local v10 = plane[ib * CLIMATE_PX + ja + 1]
                local v11 = plane[ib * CLIMATE_PX + jb + 1]
                local top = v00 + (v01 - v00) * dj
                local bottom = v10 + (v11 - v10) * dj
                out[channel] = top + (bottom - top) * di
        end
        return out[1], out[2], out[3], out[4]
end

-- How much water a place has access to, beyond what falls on it. Returns the
-- drainage area upstream in square kilometres and the height above the nearest
-- drainage in metres. Together they are what separates a river flat from the
-- hillside above it, which rainfall alone cannot: both get the same rain.
function tdl.wetness_at(fi, fj)
        local ti = math.floor(fi / TILE_PX)
        local tj = math.floor(fj / TILE_PX)
        local tile = get_tile(ti, tj)
        if not tile then
                return 0, 500
        end
        local ci = math.floor((fi - ti * TILE_PX) / CLIMATE_STEP)
        local cj = math.floor((fj - tj * TILE_PX) / CLIMATE_STEP)
        if ci < 0 then ci = 0 elseif ci > CLIMATE_PX - 1 then ci = CLIMATE_PX - 1 end
        if cj < 0 then cj = 0 elseif cj > CLIMATE_PX - 1 then cj = CLIMATE_PX - 1 end
        local at = ci * CLIMATE_PX + cj + 1
        -- Drainage is stored as log2 of the area plus one.
        return 2 ^ tile.drainage[at] - 1, tile.hand[at]
end

-- The same thing, interpolated. Channel width is derived from drainage, and
-- taking it from the nearest coarse cell makes the width of a river jump by a
-- step every 240 m, which shows as a blocky edge to the water. Interpolating in
-- the log domain keeps the growth smooth.
function tdl.drainage_at(fi, fj)
        local ti = math.floor(fi / TILE_PX)
        local tj = math.floor(fj / TILE_PX)
        local tile = get_tile(ti, tj)
        if not tile then
                return 0
        end
        local ci = (fi - ti * TILE_PX) / CLIMATE_STEP - 0.5
        local cj = (fj - tj * TILE_PX) / CLIMATE_STEP - 0.5
        local i0 = math.floor(ci)
        local j0 = math.floor(cj)
        local di = ci - i0
        local dj = cj - j0

        local function clamp(v)
                if v < 0 then return 0 end
                if v > CLIMATE_PX - 1 then return CLIMATE_PX - 1 end
                return v
        end
        local ia, ib = clamp(i0), clamp(i0 + 1)
        local ja, jb = clamp(j0), clamp(j0 + 1)

        local plane = tile.drainage
        local v00 = plane[ia * CLIMATE_PX + ja + 1]
        local v01 = plane[ia * CLIMATE_PX + jb + 1]
        local v10 = plane[ib * CLIMATE_PX + ja + 1]
        local v11 = plane[ib * CLIMATE_PX + jb + 1]
        local top = v00 + (v01 - v00) * dj
        local bottom = v10 + (v11 - v10) * dj
        return 2 ^ (top + (bottom - top) * di) - 1
end

-- Climate is sampled from further afield than the terrain when asked to be.
--
-- A 62 km world sits in one climate zone, which is why an honest one comes out
-- all taiga: real country that size does not hold both desert and tundra. That
-- is correct and it is also monotonous, so this stretches the climate lookup
-- away from spawn by a factor, letting a small world cross the climate
-- gradients of a much larger one. Elevation, rivers and wetness are untouched,
-- because those have to stay bolted to the terrain. Set it to 1 for a world
-- whose weather matches its size.
local climate_stretch = tonumber(core.settings:get("tdl_climate_stretch")) or 1
tdl.climate_stretch = climate_stretch

function tdl.climate_pixel(x, z)
        local fi = spawn_i + z / nodes_per_pixel * climate_stretch
        local fj = spawn_j + x / nodes_per_pixel * climate_stretch
        return fi, fj
end

-- Node position to fractional pixel position. Luanti's origin sits on the land
-- pixel the baker picked, so players do not start in the middle of an ocean.
function tdl.node_to_pixel(x, z)
        return spawn_i + z / nodes_per_pixel, spawn_j + x / nodes_per_pixel
end

function tdl.surface_y(elevation_metres)
        return math.floor(elevation_metres / metres_per_node + 0.5) + sea_level
end

tdl.detail_metres = detail_metres
tdl.outside_elevation = OUTSIDE_ELEVATION
