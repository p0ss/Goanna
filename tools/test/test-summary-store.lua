-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Exercise the store's real local functions without starting a game server.
-- Run from the repository root: luajit tools/test/test-summary-store.lua
local file = assert(io.open('goanna_server_mod/init.lua'))
local source = file:read('*a')
file:close()
local parts = {[[
local REC, AREA, AREA_BLOCKS = 92, 8, 512
local active, result, reads = nil, nil, 0
local settled, last_summarised, inflight, reoffer = {}, {}, {}, {}
local settled_dirty, async_summaries = false, false
local summary_stats = {reads=0, read_us=0, file_us=0}
local core = {
    get_us_time=function() return 0 end,
    hash_node_position=function(p) return p.x+8*p.y+64*p.z end,
    register_on_mapblocks_changed=function() end,
}
local function fdiv(a,b) return math.floor(a/b) end
local function now() return 0 end
local function load_area() return active end
local function pack_record(s) return s end
local function read_block() reads=reads+1;return {},{} end
local far_summary = {block=function() return result end}
]]}
for _, name in ipairs({'area_flags', 'area_known', 'area_available',
        'set_record', 'area_settled', 'land_summary', 'summarise'}) do
    parts[#parts+1] = assert(source:match(
        '(local function '..name..'%b()%s*.-\nend)'), name..' not found')
end
parts[#parts+1] = [[
local partial = string.char(16)..string.rep('\0',REC-1)
local complete = string.char(24)..string.rep('\0',REC-1)
local function reset()
    active = {key='0:0:0',blob=string.rep('\0',REC*AREA_BLOCKS),
        pending={},npending=0,known=0,checked={},nchecked=0,
        names={},name_index={}}
    settled, reads = {}, 0
end

reset()
for _=1,AREA_BLOCKS do set_record(active,0,partial) end
assert(active.known==0 and not area_settled(active),
    'rewriting one partial block must not complete an area')
set_record(active,0,complete)
set_record(active,0,complete)
assert(active.known==1,'complete rewrites must not inflate the count')
set_record(active,0,partial)
assert(active.known==0,'a partial replacement must reduce the count')

reset()
result=partial
assert(summarise(0,0,0,false,false))
for _=1,AREA_BLOCKS do assert(not summarise(0,0,0,false,false)) end
assert(reads==1 and active.known==0 and active.nchecked==1)
assert(not area_settled(active),'one checked block is not a checked area')
assert(area_flags(active,0)==16,'caching must preserve partial wire flags')
result=complete
assert(summarise(0,0,0,false,true),'generation must refresh partial data')
assert(reads==2 and active.known==1 and active.nchecked==0)
result=partial
assert(summarise(0,0,0,true,false),'node changes must force a fresh read')
assert(reads==3 and active.known==0 and active.nchecked==1)
assert(not summarise(0,0,0,false,false))

reset()
result=nil
assert(summarise(0,0,0,false,false))
assert(not summarise(0,0,0,false,false),'unknown blocks should stay cached')
result=complete
assert(summarise(0,0,0,false,true),'new terrain must replace unknown data')
assert(active.known==1 and active.nchecked==0)

reset()
result=partial
for i=0,AREA_BLOCKS-1 do
    land_summary(i%AREA,math.floor(i/AREA)%AREA,math.floor(i/64),result)
end
assert(active.known==0 and active.nchecked==AREA_BLOCKS)
assert(area_settled(active) and settled[active.key],
    'a checked area may stop backfill without pretending it is complete')

reset()
core.register_on_mapblocks_changed=nil
result=partial
assert(summarise(0,0,0,false,false))
assert(summarise(0,0,0,false,false),
    'older servers without change callbacks must still retry partials')
assert(reads==2 and active.known==0 and active.nchecked==0)
print('summary store counts, retries and invalidation: OK')
]]
assert(loadstring(table.concat(parts,'\n')))()
