#pragma once

// Turns Luanti tile texture strings into Godot materials, from media the
// session received. Stage-2: base texture only (text before the first '^');
// the texture-modifier DSL (imagesource.cpp) is transplanted later.

#include <map>
#include <string>

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>

#include "goanna_mesher.h"

namespace goanna {

class GoannaSession;

class MaterialCache {
public:
    // Returns a material for the surface, or a fallback vertex-colour material
    // when the texture cannot be resolved (yet).
    godot::Ref<godot::Material> get(GoannaSession &session, const SurfaceData &s);
    void clear();
    int size() const { return (int)m_materials.size(); }

private:
    struct Entry {
        godot::Ref<godot::StandardMaterial3D> mat;
        bool resolved = false;
    };
    godot::Ref<godot::ImageTexture> loadTexture(GoannaSession &session, const std::string &tile,
            bool &has_alpha, int &w, int &h);
    std::map<std::string, Entry> m_materials;
    std::map<std::string, godot::Ref<godot::ImageTexture>> m_textures;
    godot::Ref<godot::StandardMaterial3D> m_fallback;
};

std::string baseTextureName(const std::string &tile);

} // namespace goanna
