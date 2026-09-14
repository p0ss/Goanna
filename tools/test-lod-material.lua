-- Run with luajit tools/test-lod-material.lua.
local reduce = dofile("goanna_server_mod/surface_material.lua")
local function crown(x, y, z)
	if y == 3 then return "leaves" end
	if x == 1 and z == 1 then return "wood" end
end
assert(reduce(4, crown) == "leaves", "buried trunk repainted the canopy")
assert(reduce(4, function(x, y, z)
	if x == 1 and z == 1 then return "wood" end
end) == "wood", "exposed log lost its material")
assert(reduce(4, function(x, y, z)
	return y == 3 and "grass" or "stone"
end) == "grass", "buried stone repainted the surface")
assert(reduce(4, function() end) == nil, "empty cell invented a material")
print("LOD surface materials: canopy, exposed wood, ground and air PASS")
