// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Impostors for the trees goanna_trees.h finds: what gets drawn where a tree
// is, once its geometry is too far away to be worth meshing.
//
// The usual impostor is a picture of the object from a ring of angles, chosen
// by whichever is nearest the camera. That suits a model with millions of
// triangles, where rendering it even once is the expense being avoided. A
// Luanti tree is not that. It is a few thousand voxels, small enough to keep
// whole, so this keeps it whole: the impostor is the tree's own occupancy in a
// little volume, and the shader marches it.
//
// That is worth the difference because a ring of pictures is only right at the
// angles it was baked from. Between them the silhouette pops, and a tree seen
// from above, from a hill or in flight, is not in the ring at all. Marching the
// real voxels gives the true silhouette from every direction including straight
// down, with real parallax between trunk and crown, and no popping to hide.
//
// It is also cheap in the way that matters. At the distance an impostor is for,
// a tree covers a few pixels, so the march is a few steps in a few fragments,
// and one 24 by 40 by 24 slot is 92 KB.
//
// What a slot holds is a species, not an individual. Sharing slots between
// trees that are byte for byte identical was tried first and does not work:
// measured over a real Asuna wood, 146 trees held 137 distinct shapes, because
// the generator rotates each one at random, picks a height from a range, and
// the ground clips whatever it grows through. That filled a 5.7 MB atlas to 2%
// and still left 76 trees with nowhere to go.
//
// A volume does not need to carry its own size, because a marched volume is
// scale free: the instance carries the height and crown radius the detector
// measured, and the shader scales the march to them. So one oak serves every
// oak, standing at each one's own place, at each one's own height and width,
// turned to its own angle. The same wood then needs one slot per species
// rather than one per tree.
//
// What that gives up is that two oaks of the same height, seen from the same
// angle, are the same picture. At the range an impostor is used that is a
// difference of well under a pixel, and it is the price of the atlas being a
// fixed cost instead of one that grows with how many trees are in view.

#pragma once

#include "goanna_trees.h"

#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>

namespace goanna {

// One tree's voxels, ready to be packed. Colour is resolved here rather than in
// the shader so the atlas holds what a node actually looks like in this game,
// including its palette and tint.
struct TreeVolume {
    v3s16 size;
    std::vector<uint32_t> voxel;  // 0xAARRGGBB, alpha 0 where empty
    // What decides whether two volumes share a slot. buildTreeVolume fills it
    // from the shape and its colours, which is what an authored tree list
    // wants, where two trees of one species really are identical. A caller
    // reading trees out of a world instead overwrites it with
    // treePrototypeKey, so one oak stands for every oak.
    uint64_t key = 0;
};

// The sharing key for "any tree of this species", with `variant` to keep a few
// different oaks rather than one, since the same picture repeated across a
// hillside is a pattern the eye finds.
uint64_t treePrototypeKey(content_t trunk, content_t leaves, int variant = 0);

// The colour of a node, as the horizon bake paints it: lodFlatColour in the
// client, a stub in the tests.
using TreeColourFn = std::function<uint32_t(content_t)>;

TreeVolume buildTreeVolume(const TreeMask &mask, const TreeColourFn &colour);

// A grid of equal slots in one 3D texture. Equal because the shader indexes a
// slot by multiplying, and a packer that fitted each tree exactly would cost a
// per tree offset lookup to save memory that is already small.
class TreeAtlas {
public:
    // The default slot holds Luanti's tallest ordinary trees whole. Anything
    // larger is reduced to fit rather than dropped: a jungle giant drawn
    // slightly coarsely is better than one drawn as a box.
    // Thirty six slots at 24 by 40 by 24 is 3.2 MB. Measured over a real Asuna
    // wood, 146 trees wanted 26 prototypes, so sixteen slots was not enough and
    // thirty six leaves room. A prototype is a species and a variant, not a
    // tree, so this does not grow with how many trees are in view.
    TreeAtlas(v3s16 slot = v3s16(24, 40, 24), int columns = 6, int rows = 6);

    // Returns the slot a volume was given, or -1 when the atlas is full. An
    // identical tree already present returns its existing slot rather than
    // taking a second one.
    int add(const TreeVolume &volume);
    int slotOf(uint64_t key) const;

    v3s16 slotSize() const { return m_slot; }
    int columns() const { return m_columns; }
    int rows() const { return m_rows; }
    int capacity() const { return m_columns * m_rows; }
    int used() const { return (int)m_slots.size(); }

    // The packed voxels, x fastest then y then z, ready for an ImageTexture3D.
    v3s16 size() const {
        return v3s16(m_slot.X * m_columns, m_slot.Y, m_slot.Z * m_rows);
    }
    const std::vector<uint32_t> &voxels() const { return m_voxels; }

    // Where a slot sits in the atlas, in voxels, for the shader's own maths.
    v3s16 slotOrigin(int slot) const;

    // How much of the atlas carries anything, which is the number worth
    // watching if the slot size is ever changed.
    float occupancy() const;

private:
    v3s16 m_slot;
    int m_columns, m_rows;
    std::vector<uint32_t> m_voxels;
    std::vector<uint64_t> m_slots;
    std::unordered_map<uint64_t, int> m_by_key;
};

} // namespace goanna
