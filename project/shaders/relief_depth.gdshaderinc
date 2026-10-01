// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// The parallax depth table, shared by the node array shaders
// (nodes_array_common.gdshaderinc) and the entity ones
// (entity_common.gdshaderinc), so a block and a mob of one material march
// the same depth when their map gives none of its own.

// Depth of the height map's full range, in nodes, by material class. The
// classes are src/goanna_materials.h's: 0 none, 1 stone, 2 wood, 3 leaves,
// 4 glass, 5 sand, 6 gravel, 7 snow, 8 ice, 9 soil, 10 metal, 11 cloth.
// Real relief, not map amplitude: an authored map and a baked one both span
// the byte, and what differs between a cobble and a beach is how far that
// byte reaches into the node.
// Judged on the close-up ramp with the authored sets: at 0.08 the stone
// class turned cobble and gravel into rubble and brick joints into caves;
// 0.045 is where a joint reads as a joint. The frames the look was settled
// on ran at 0.04 for everything.
float goanna_class_depth(int cls) {
	if (cls == 1)
		return 0.045;
	if (cls == 6)
		return 0.05;
	if (cls == 9)
		return 0.035;
	if (cls == 2)
		return 0.025;
	if (cls == 3)
		return 0.04;
	if (cls == 7 || cls == 8)
		return 0.02;
	if (cls == 5 || cls == 11 || cls == 10)
		return 0.01;
	if (cls == 4)
		return 0.0;
	return 0.035;
}
