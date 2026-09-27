-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Copyright (C) 2026 the Goanna contributors
-- Loaded only into the benchmark's disposable Mineclonia world copy.
core.register_on_mods_loaded(function()
    core.after(0, function()
        if mcl_weather then
            assert(mcl_weather.change_weather("none", core.get_gametime()+86400,
                "local_benchmark"))
        end
    end)
end)
local scene = core.settings:get("goanna_benchmark_scene") or "circle"
local fixture = scene ~= "circle" and scene ~= "dusk" and scene ~= "clouds"
local ready = not fixture
local started = false
local centre = {x=-72, y=64, z=-378}
local lo = {x=-96, y=56, z=-402}
local hi = {x=-48, y=80, z=-354}
local function build()
    local names = {"air", "mcl_core:stonebrick", "mcl_core:water_source",
        "mcl_core:dirt_with_grass", "mcl_core:ice", "mcl_core:lava_source",
        "mcl_core:leaves", "mcl_torches:torch"}
    local ids = {}
    for _, name in ipairs(names) do
        assert(core.registered_nodes[name], "Missing fixture node: " .. name)
        ids[name] = core.get_content_id(name)
    end
    local vm = VoxelManip()
    local emin, emax = vm:read_from_map(lo, hi)
    local area = VoxelArea:new({MinEdge=emin, MaxEdge=emax})
    local data = vm:get_data()
    for z=lo.z,hi.z do
        for y=lo.y,hi.y do
            for x=lo.x,hi.x do
                local dx, dz = x-centre.x, z-centre.z
                local node = y <= 60 and "mcl_core:stonebrick" or "air"
                if scene == "grass" and y == 60 then
                    node = "mcl_core:dirt_with_grass"
                elseif scene == "underwater" and y > 60 and y <= 68 then
                    node = "mcl_core:water_source"
                elseif scene == "magma" and y == 60 then
                    node = "mcl_core:lava_source"
                elseif scene == "wet" and y == 60 and dx > 0 then
                    node = "mcl_core:water_source"
                elseif scene == "ice" and y >= 61 and y <= 65 and
                        ((math.abs(dx) <= 2) or (math.abs(dz) <= 2)) then
                    node = "mcl_core:ice"
                elseif scene == "foliage" and y >= 61 and y <= 64 and
                        dx % 5 <= 1 and dz % 5 <= 1 then
                    node = "mcl_core:leaves"
                elseif scene == "occlusion" then
                    if y == 68 or (y <= 68 and (math.abs(dx) == 16 or math.abs(dz) == 16)) or
                            (dz == 0 and y >= 61 and y <= 67 and math.abs(dx) <= 16 and
                            not (dx >= 3 and dx <= 5 and y <= 64)) then
                        node = "mcl_core:stonebrick"
                    elseif x == centre.x and y == 61 and z == centre.z+4 then
                        node = "mcl_torches:torch"
                    end
                elseif scene == "night" then
                    if y == 68 or (y <= 68 and (math.abs(dx) == 16 or math.abs(dz) == 16)) then
                        node = "mcl_core:stonebrick"
                    elseif y == 61 and dx % 8 == 4 and dz % 8 == 4 then
                        node = "mcl_torches:torch"
                    end
                end
                if (scene == "underwater" and y <= 69 or
                        (scene == "wet" or scene == "magma") and y == 60) and
                        (math.abs(dx) == 24 or math.abs(dz) == 24) then
                    node = "mcl_core:stonebrick"
                end
                data[area:index(x,y,z)] = ids[node]
            end
        end
    end
    vm:set_data(data)
    vm:write_to_map()
    vm:update_map()
    ready = true
    core.log("action", "GOANNA_FIXTURE_READY " .. scene)
end
core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    if scene == "clouds" then
        core.after(2, function()
            local current = core.get_player_by_name(name)
            if current then
                current:set_clouds({height=128, thickness=16, density=0.55})
            end
        end)
    end
    core.set_player_privs(name, {interact=true, shout=true, fly=true, fast=true, teleport=true})
    player:set_pos(centre)
    if scene == "night" then
        player:set_wielded_item("mcl_torches:torch 1")
    end
    if fixture and not started then
        started = true
        core.emerge_area(lo, hi, function(_, _, remaining)
            if remaining == 0 then build() end
        end)
    end
end)
core.register_chatcommand("perf_ready", {func=function() return true, tostring(ready) end})

-- A controlled edit for checking that visibility follows block changes.
core.register_chatcommand("perf_wall", {func=function(_, parameter)
    if scene ~= "occlusion" then return false, "Not the occlusion fixture" end
    for y=61,64 do
        for x=centre.x-1,centre.x+1 do
            core.set_node({x=x,y=y,z=centre.z}, {name=parameter == "open" and "air" or "mcl_core:stonebrick"})
        end
    end
    return true, "Wall updated"
end})
