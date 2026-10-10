-- Disposable Minetest Game world, built entirely from ordinary server nodes.
local air = core.get_content_id("air")
local dirt = core.get_content_id("default:dirt")
local green = core.get_content_id("default:dirt_with_grass")
local dry = core.get_content_id("default:dirt_with_dry_grass")
local stone = core.get_content_id("default:stonebrick")
local sand = core.get_content_id("default:sand")
local water = core.get_content_id("default:water_source")
local snow = core.get_content_id("default:dirt_with_snow")
local function height(x,z)
    return 78 + math.floor(2.8*math.sin(x*0.037)+3.2*math.sin(z*0.026)+1.5*math.sin((x+z)*0.09))
end
core.register_on_generated(function(minp,maxp)
    if minp.y > 96 or maxp.y < 64 then return end
    local vm,emin,emax = core.get_mapgen_object("voxelmanip")
    local area = VoxelArea:new({MinEdge=emin,MaxEdge=emax})
    local data = vm:get_data()
    for z=minp.z,maxp.z do for x=minp.x,maxp.x do
        local top=height(x,z)
        local surface = x>30 and dry or green
        if x>=-3 and x<=0 then surface=sand end
        if x>=8 and x<=14 and z>=8 and z<=16 then surface=snow end
        for y=minp.y,maxp.y do
            local n=air
            if y<top then n=dirt elseif y==top then n=surface end
            if x>=17 and x<=27 and z>=-16 and z<=-5 and y>=top-2 and y<=top then n=water end
            if x>=-12 and x<=-9 and z>=-3 and z<=2 and y>top and y<=top+3 then n=stone end
            data[area:index(x,y,z)]=n
        end
    end end
    vm:set_data(data)
    vm:calc_lighting()
    vm:write_to_map()
end)
core.register_on_joinplayer(function(player)
    core.set_player_privs(player:get_player_name(),{interact=true,shout=true,fly=true,fast=true,noclip=true,teleport=true,settime=true,server=true})
    player:set_pos({x=6,y=height(6,0)+2,z=0})
    core.set_timeofday(0.38)
end)

-- Physical mover for the interaction review. Assets are copied to /tmp by
-- the runner from an installed Animalia game; no third-party assets vendored.
core.register_entity("grass_review:sheep", {
    initial_properties = {
        physical=true, collide_with_objects=true, visual="mesh",
        mesh="animalia_sheep.b3d", visual_size={x=10,y=10},
        textures={"animalia_sheep.png^animalia_sheep_wool.png"},
        collisionbox={-0.35,0,-0.45,0.35,0.9,0.45}, static_save=false,
    },
    on_activate=function(self)
        self.origin=self.object:get_pos()
        self.age=0
    end,
    on_step=function(self,dt)
        self.age=self.age+dt
        local x=self.origin.x+2*math.sin(self.age*0.45)
        local z=self.origin.z
        self.object:set_pos({x=x,y=height(x,z)+0.51,z=z})
    end,
})
core.register_chatcommand("grass_actor", {
    privs={server=true},
    func=function(name,param)
        local x,z=param:match("^([%d.-]+) +([%d.-]+)$")
        if not x then return false,"Supply x z" end
        x,z=tonumber(x),tonumber(z)
        core.add_entity({x=x,y=height(x,z)+0.51,z=z},"grass_review:sheep")
        return true,"Grass interaction mover spawned"
    end,
})

-- Permanent soil keeps the water comparison independent of the game's
-- grass-decay ABM. The geometry straddles both X and Y mapblock boundaries.
core.register_node("grass_review:water_test_grass", {
    description="Grass water review soil",
    tiles=core.registered_nodes["default:dirt_with_grass"].tiles,
    groups={soil=1,cracky=1},
})
core.register_chatcommand("grass_water", {
    privs={server=true},
    params="[dry]",
    func=function(_, param)
        local minp,maxp={x=10,y=124,z=-8},{x=22,y=132,z=4}
        local vm=core.get_voxel_manip(minp,maxp)
        local emin,emax=vm:get_emerged_area()
        local area=VoxelArea:new({MinEdge=emin,MaxEdge=emax})
        local data=vm:get_data()
        local soil=core.get_content_id("grass_review:water_test_grass")
        for z=minp.z,maxp.z do for y=minp.y,maxp.y do for x=minp.x,maxp.x do
            local pool=x>=13 and x<=19 and z>=-5 and z<=1
            local top=pool and 126 or 128
            local content=air
            if y<top then content=dirt elseif y==top then content=soil end
            if pool and y>top and y<=128 and param~="dry" then content=water end
            data[area:index(x,y,z)]=content
        end end end
        vm:set_data(data)
        vm:calc_lighting()
        vm:write_to_map()
        return true,"Grass/water review pool at 16,128,-2"
    end,
})
