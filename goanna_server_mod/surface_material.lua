-- A summary has one material per coarse voxel. Use its visible top area:
-- opaque nodes buried under foliage or soil do not vote through that surface.
return function(edge, sample)
	local counts, order = {}, {}
	for z = 0, edge - 1 do
		for x = 0, edge - 1 do
			for y = edge - 1, 0, -1 do
				local content = sample(x, y, z)
				if content then
					if not counts[content] then
						order[#order + 1] = content
						counts[content] = 0
					end
					counts[content] = counts[content] + 1
					break
				end
			end
		end
	end
	local chosen, best = nil, 0
	for _, content in ipairs(order) do
		if counts[content] >= best then chosen, best = content, counts[content] end
	end
	return chosen
end
