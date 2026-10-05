-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The director's items adapter for Mineclonia: enchantments, names the
-- way its anvil gives them, armour points, and the chest a reward goes in.
--
-- Read against Mineclonia release 38561. It calls public functions of
-- mcl_enchanting and tt; none of their authors is involved. Detection tests
-- for those functions, not for a game's name, so another game that carries
-- the same mods (VoxeLibre forked them) is matched if they still fit.

return function()
	local A = {name = "mcl_items", kind = "items", priority = 10}

	function A.detect()
		local e = rawget(_G, "mcl_enchanting")
		local tt = rawget(_G, "tt")
		return e ~= nil and type(e.enchant) == "function" and type(e.can_enchant) == "function"
			and type(e.enchantments) == "table"
			and tt ~= nil and type(tt.reload_itemstack_description) == "function"
	end

	function A.enchantments()
		local out = {}
		for name, def in pairs(mcl_enchanting.enchantments) do
			out[#out + 1] = {name = name, desc = def.name, max_level = def.max_level,
				curse = def.curse or false, treasure = def.treasure or false}
		end
		return out
	end

	-- list: {{name =, level =}, ...}. Every enchantment is checked against
	-- the item and those already on it before any is applied, so a refused
	-- list leaves nothing half done (the caller's stack is a copy anyway).
	function A.enchant(stack, list)
		for _, e in ipairs(list) do
			local level = math.floor(tonumber(e.level) or 1)
			local ok, why = mcl_enchanting.can_enchant(stack, e.name, level)
			if not ok then
				return nil, ("%s %d: %s"):format(tostring(e.name), level, tostring(why))
			end
			stack = mcl_enchanting.enchant(stack, e.name, level)
		end
		return stack
	end

	-- The name in the place the anvil writes it, so the game's tooltip
	-- shows it as a renamed item; extra lines go after the tooltip.
	function A.describe(stack, name, lines)
		local meta = stack:get_meta()
		if name then
			meta:set_string("name", name)
		end
		tt.reload_itemstack_description(stack)
		if lines and #lines > 0 then
			local desc = meta:get_string("description")
			if desc == "" then
				desc = stack:get_definition().description or stack:get_name()
			end
			meta:set_string("description", desc .. "\n" .. table.concat(lines, "\n"))
		end
		return stack
	end

	-- Armour points, and a tool's tier: Mineclonia's tools carry no dig
	-- level in their groupcaps, but dig_speed_class runs from 1 (wood) to 6
	-- (netherite) on every tool and weapon.
	function A.item_facts(name)
		local out = {}
		local points = core.get_item_group(name, "mcl_armor_points")
		if points > 0 then
			out.armour = points
		end
		local class = core.get_item_group(name, "dig_speed_class")
		if class > 0 then
			out.level = class
		end
		return out
	end

	-- A single chest, which on_construct turns into a working one with a
	-- "main" list.
	function A.container()
		if core.registered_nodes["mcl_chests:chest_small"] then
			return "mcl_chests:chest_small", "main"
		end
		return nil
	end

	return A
end
