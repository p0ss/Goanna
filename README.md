# Goanna

A Godot 4 client for Luanti worlds. Goanna carries Luanti's own client
logic — networking, world handling, movement, node meshing, formspec parsing
— into Godot as a GDExtension, and renders it with the Forward+ pipeline:
PBR, SDFGI, SSAO/SSIL, volumetric fog, real shadows.

Connects to ordinary Luanti servers. Visuals first; Vulkan required; no
low-spec fallback (that is what the vanilla client is for).

Status: pre-alpha, spike stage. See `PLAN.md`.

License: LGPL-2.1-or-later (transplanted Luanti client code); godot-cpp is MIT.
