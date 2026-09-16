// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Compact authored forms and transient impact damage. The subcube grid is
// reconstructed only while meshing; it is never stored per world node.
// Authored box/extents/bore fields retain Kythen's existing bake semantics.
// Impacts deform a shared surface lattice: one vector per face, edge and corner.
// The legacy 16-bit face word cannot encode arbitrary impact positions, and is
// not implicitly read from ordinary nodes' lighting/facedir parameters.

#include <cstdint>
#include <vector>

namespace goanna {

// Legacy face-word indices. Corner indices here are NOT 26-plane indices.
enum FormAxis {
    AXIS_XN = 0, AXIS_XP, AXIS_YN, AXIS_YP, AXIS_ZN, AXIS_ZP,
    AXIS_NNN, AXIS_NNP, AXIS_NPN, AXIS_NPP,
    AXIS_PNN, AXIS_PNP, AXIS_PPN, AXIS_PPP,
    FORM_AXIS_COUNT
};

constexpr int FORM_FACE_COUNT = 6;

// Twenty six directions: six face normals, twelve edge midpoints, eight corner
// diagonals. Both a cutting plane (`box`) and a carve slice (`extents`) is
// indexed by one of these, so the two fields share one axis table.
constexpr int FORM_PLANE_COUNT = 26;

// The thirteen bore axes: every one of the twenty six plane directions paired
// with its opposite, because a hole has no front and back. Three through the
// faces, six through the edge midpoints, four through the body diagonals.
constexpr int FORM_BORE_COUNT = 13;

// A box in node local coordinates on [-0.5, 0.5], as a nodebox would give it.
struct FormBox {
    float x1, y1, z1, x2, y2, z2;
};

// Inward displacement along each axis at a fixed surface lattice point.
// Edge/corner controls are shared by adjacent faces; components remain independent.
struct FormDisplacement {
    float axis[3] = {0, 0, 0};
};

// Convex box planes, authored radial slices, and bores keep separate meanings.
struct RadialForm {
    float origin[3] = {0.0f, 0.0f, 0.0f};
    float box[FORM_PLANE_COUNT] = {
        1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f,
        1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f,
        1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f
    };
    // Authored radial slices, in node units; negative means untouched.
    float extents[FORM_PLANE_COUNT];
    // A bore is what a carve becomes when it reaches the origin. The carve is
    // star shaped about the origin, so material along a direction runs from 0
    // out to the radius; once the radius is 0 the crater has bottomed out in
    // the middle of the block and there is nothing left to take. Past that it
    // is a hole, and a hole is neither a convex clip nor a star shaped carve.
    //
    // Radius per axis, 0 for no hole. Derived from the word, never stored in
    // it: both faces of an axis dug all the way IS the statement "dug through
    // from both sides", so the word already says it and costs no bit.
    float bore[FORM_BORE_COUNT] = {
        0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f
    };
    FormDisplacement displacement[FORM_PLANE_COUNT];
    int resolution = 8;

    RadialForm() {
        for (int i = 0; i < FORM_PLANE_COUNT; ++i) { extents[i] = -1.0f; }
    }
};

// Legacy six-face damage decoder. Zero is pristine; high bits are ignored.
RadialForm formFromWord(uint16_t word);

uint16_t wordFromParams(uint8_t param1, uint8_t param2);

// Add quantised face damage to a legacy word, saturating each face.
uint16_t digWord(uint16_t base, FormAxis face, float progress);

// Bilinear inward displacement on a face, using its four nearest lattice controls.
// Faces use FormAxis order (-X,+X,-Y,+Y,-Z,+Z), not Luanti mesh face order.
float formInset(const RadialForm &form, int face, float px, float py, float pz);

// Distribute a blow across the nearest controls. face=-1 infers the cube face
// from the hit position; live raycasts supply the actual normal at edge ties.
RadialForm strike(const RadialForm &form, float px, float py, float pz,
        float depth, int face = -1);

// Remove the fraction of material corresponding to health lost at contacts.
// The caller resets this when digging ends or the target changes.
struct FormDig {
    RadialForm form;
    float applied_progress = 0;
    float remaining_volume = 1;
    int initial_cells = -1;
    bool advance(float damage, float px, float py, float pz, int face = -1);
};

// One greedy rectangle of the exposed surface. Face order matches Luanti:
// +Y, -Y, +X, -X, +Z, -Z. backing >= 0 identifies the neighbour whose own
// material closes an opened boundary; face is then the opposite normal.
struct FormSurface {
    FormBox box;
    int face;
    int backing = -1;
};
std::vector<FormSurface> formSurfaces(const std::vector<bool> &grid, int n,
        uint8_t visible_boundary = 63, uint8_t backing_boundary = 0);

// Is this point, in node local coordinates on [-0.5, 0.5], material?
bool formSolid(const RadialForm &form, float px, float py, float pz);

// The occupancy grid flattened to resolution^3, indexed k * n * n + j * n + i.
std::vector<bool> formGrid(const RadialForm &form, int resolution);

// Greedy boxes for baked nodeboxes. Live cuts use formSurfaces to omit internal faces.
std::vector<FormBox> formBoxes(const RadialForm &form, int resolution);

// Fraction of occupied subcubes at the requested resolution.
float formVolume(const RadialForm &form, int resolution);

} // namespace goanna
