// Per-player shader state. Godot shader globals span every World3D, so local
// players need distinct names even when their scene trees are separate.
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once

#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <cstdint>
#include <map>

namespace goanna {
class RenderScope {
public:
    explicit RenderScope(uint64_t id);
    ~RenderScope();
    godot::Ref<godot::Shader> load(const godot::String &path);
    void set(const godot::StringName &name, const godot::Variant &value);
    godot::String name(const godot::String &original) const;
private:
    std::map<godot::String, godot::String> m_names;
    std::map<godot::String, godot::Ref<godot::Shader>> m_shaders;
    godot::String expand(const godot::String &code, const godot::String &path, int depth);
};
}
