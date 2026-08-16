// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Image creation/decoding hooks used by the transplanted imagesource.cpp in
// place of Irrlicht's video driver. Images are Irrlicht's CPU-only CImage
// (irr/src/CImage.cpp), so the texture-modifier DSL runs verbatim; decoding
// of PNG/JPG/TGA/BMP bytes is done by Godot.

#include <string>

#include "irrlichttypes_bloated.h"
#include <IImage.h>

// New blank image (ref count 1).
video::IImage *goanna_create_image(video::ECOLOR_FORMAT format, const core::dimension2du &dim);
// Decode an image file's bytes; nullptr on failure. Name is used to pick the codec.
video::IImage *goanna_decode_image_memory(const std::string &bytes, const std::string &name);
// Load and decode a file from disk (texture packs, base pack); nullptr on failure.
video::IImage *goanna_load_image_file(const std::string &path);
