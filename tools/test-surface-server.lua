-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Run with luajit tools/test-surface-server.lua. No world or engine needed.
local saved, sent, announced, message, tick, sampled = {}, {}, {}, nil, nil, 0
local pos = {x = 0, z = 0}
local clock = 0
core = {
	register_on_modchannel_message = function(fn) message = fn end,
	register_globalstep = function(fn) tick = fn end,
	get_player_by_name = function(name)
		if name == "player" then return {get_pos = function() return pos end} end
	end,
	get_us_time = function() clock = clock + 10; return clock end,
	encode_base64 = function(raw) return "encoded:" .. raw end,
	sha1 = function(raw) return raw end,
}
goanna_announce = function(k, v) announced[k] = v end
local storage = {
	get_string = function(_, k) return saved[k] or "" end,
	set_string = function(_, k, v) saved[k] = v end,
}
local channel = {
	is_writeable = function() return true end,
	send_all = function(_, wire) sent[#sent + 1] = wire end,
}
local function load(enabled, revision)
	local register = dofile("goanna_server_mod/surface.lua")(channel, enabled, 4096, storage)
	register(function(x, z)
		sampled = sampled + 1
		return math.floor((x + z) / 32), "stone", 10, "dirt"
	end, {water = "water", revision = revision})
end
local function ask(step, x, z, rev)
	message("goanna:v1", "player", string.format("surface? 1 %s %d %d %d", rev or "abc", step, x, z))
end
load(true, "abc")
assert(announced.surface_tiles == "1")
ask(128, -1, 0)
ask(128, -1, 0) -- duplicate collapsed
for _ = 1, 10 do tick() end
assert(#sent == 1 and sampled == 256, "one column tile expanded or sampled twice")
assert(sent[1]:find("surface player 1 abc 128 -1 0 stone,dirt,water|", 1, true))
ask(128, -1, 0)
tick()
assert(#sent == 2 and sampled == 256, "memory cache missed")
load(true, "abc")
ask(128, -1, 0)
tick()
assert(#sent == 3 and sampled == 256, "persistent cache missed after restart")
ask(128, 100, 100) -- outside grant
ask(32, 0, 0) -- unsupported resolution
ask(128, 0, 0, "def") -- wrong bake
for _ = 1, 10 do tick() end
assert(#sent == 3 and sampled == 256, "invalid request consumed provider work")
load(true, "def")
ask(128, -1, 0, "def")
for _ = 1, 10 do tick() end
assert(#sent == 4 and sampled == 512, "new revision reused stale surface")
load(false, "abc")
ask(128, -1, 0)
tick()
assert(#sent == 4, "disabled far rendering served terrain")
load(true, nil)
ask(128, -1, 0)
tick()
assert(#sent == 4, "provider without identity served cacheable terrain")
load(true, "abc")
for x = 0, 20 do ask(4, x, 0) end
for _ = 1, 100 do tick() end
assert(#sent == 12, "per-player in-flight bound failed")
print("surface server: grants, bounds, identity and cold/warm cache PASS")

-- The forest callback may yield many times; its work must span ticks and a
-- cached reply must not run it again. Version one still works on this provider.
local forest_calls=0
core.compress=function(raw,mode) assert(mode=="deflate"); return raw end
core.log=function(_,msg) error(msg) end
local register=dofile("goanna_server_mod/surface.lua")(channel,true,4096,storage)
register(function() return 0,"soil",nil,"soil" end,{revision="fed",forest=function(x,z,step)
 forest_calls=forest_calls+1
 for _=1,5 do coroutine.yield() end
 return {{x=x-step/2,z=z-step/2,bottom=1,top=8,name="leaves",param2=3,size=2,coverage=255}}
end})
assert(announced.surface_tiles=="2")
local before=#sent
message("goanna:v1","player","surface? 2 fed 8 0 0")
tick()
assert(#sent==before and forest_calls<256,"forest work blocked a whole tile in one tick")
for _=1,30 do tick() end
assert(#sent==before+1 and forest_calls==256,"forest tile failed to finish")
assert(sent[#sent]:find("surface player 2 fed 8 0 0 soil,leaves|",1,true))
message("goanna:v1","player","surface? 2 fed 8 0 0");tick()
assert(#sent==before+2 and forest_calls==256,"forest cache rebuilt geometry")
message("goanna:v1","player","surface? 1 fed 8 0 0")
for _=1,10 do tick() end
assert(#sent==before+3 and forest_calls==256,"legacy request invoked forest generation")
print("surface server: forest protocol, cooperative budget and compatibility PASS")

-- A dense tile is transmitted intact across bounded packets, not dropped or
-- replaced with a coarser forest. Use incompressible output in this fixture.
saved={};sent={}
core.compress=function() return string.rep('x',150000) end
local register=dofile('goanna_server_mod/surface.lua')(channel,true,4096,storage)
register(function() return 1,'grass',nil,'dirt' end,
 {revision='feed',forest=function() return {} end})
message('goanna:v1','player','surface? 2 feed 4 0 0')
for _=1,20 do tick() end
assert(#sent==3,'large tile was not split into three parts')
local body={}
for i,wire in ipairs(sent) do
 assert(#wire<65535,'surface part exceeded packet bound')
 local n,total,chunk=wire:match('^surface_part player 2 feed 4 0 0 (%d+) (%d+) (.+)$')
 assert(tonumber(n)==i-1 and tonumber(total)==3,'multipart header lost its identity')
 body[#body+1]=chunk
end
assert(table.concat(body)=='grass,dirt|encoded:'..string.rep('x',150000),'multipart lost forest bytes')
print('surface server: oversized forests survive bounded multipart delivery PASS')
