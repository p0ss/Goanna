-- Borrowing whatever the game already knows about its own ground.
--
-- Every Luanti game that works with the engine mapgens publishes its palette
-- through core.register_biome: a top node, a filler, their depths, a riverbed,
-- a height range and a point in heat and humidity. Asuna registers 166 of them,
-- Mineclonia 187, Minetest Game 43. Hardcoding node names per game throws all
-- of that away and has to be redone for each one.
--
-- So this mod decides what the climate is, from terrain the game has no access
-- to, and then asks the game what that climate looks like. The division is the
-- point: elevation, rivers, the water table and the lapse rate are ours, and
-- every node name is theirs.

tdl_palette = {}

local entries = {}

-- Luanti's heat and humidity are both nominally 0 to 100, which the installed
-- games agree on: medians land near 45 and 50 in Asuna, Minetest Game and
-- Mineclonia alike. Mapping onto that is a choice, and this one puts 10 C and
-- 1000 mm a year in the middle of the range, which is temperate.
function tdl_palette.heat(temp_c)
        local heat = (temp_c + 10) * 2.5
        if heat < 0 then return 0 end
        if heat > 100 then return 100 end
        return heat
end

function tdl_palette.humidity(precip_mm)
        local humidity = precip_mm / 20
        if humidity < 0 then return 0 end
        if humidity > 100 then return 100 end
        return humidity
end

local function usable(def)
        -- Games park special biomes at absurd points to keep them out of the
        -- normal running. Mineclonia uses 1000 for its Nether and End.
        local heat = def.heat_point
        local humidity = def.humidity_point
        if type(heat) ~= "number" or type(humidity) ~= "number" then
                return false
        end
        return heat >= -20 and heat <= 120 and humidity >= -20 and humidity <= 120
end

local function id_of(name)
        if type(name) ~= "string" or name == "" then
                return nil
        end
        local ok, id = pcall(core.get_content_id, name)
        if ok then return id end
        return nil
end

function tdl_palette.load()
        entries = {}
        for _, def in pairs(core.registered_biomes or {}) do
                if usable(def) then
                        local top = id_of(def.node_top)
                        local filler = id_of(def.node_filler)
                        if top then
                                entries[#entries + 1] = {
                                        name = def.name,
                                        heat = def.heat_point,
                                        humidity = def.humidity_point,
                                        y_min = def.y_min or -31000,
                                        y_max = def.y_max or 31000,
                                        top = top,
                                        top_name = def.node_top,
                                        depth_top = def.depth_top or 1,
                                        filler = filler or top,
                                        filler_name = def.node_filler or def.node_top,
                                        depth_filler = def.depth_filler or 3,
                                        riverbed = id_of(def.node_riverbed),
                                        stone = id_of(def.node_stone),
                                }
                        end
                end
        end
        return #entries
end

function tdl_palette.count()
        return #entries
end

-- Nearest point in heat and humidity, among the biomes that reach this height.
-- This is what the engine's own biome manager does, so a game's biomes land
-- where their author expected them to.
function tdl_palette.pick(heat, humidity, y)
        -- Loaded on first use rather than at mod load: in the main environment
        -- other mods may still be registering biomes when this file runs.
        if #entries == 0 then
                tdl_palette.load()
        end

        local best, best_distance = nil, math.huge
        for index = 1, #entries do
                local entry = entries[index]
                if y >= entry.y_min and y <= entry.y_max then
                        local dh = heat - entry.heat
                        local dm = humidity - entry.humidity
                        local distance = dh * dh + dm * dm
                        if distance < best_distance then
                                best_distance = distance
                                best = entry
                        end
                end
        end
        return best
end
