// Isolate the existing shader interface without duplicating shader files.
// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_render_scope.h"
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader_include.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;
namespace goanna {
RenderScope::RenderScope(uint64_t id) {
    auto *settings = ProjectSettings::get_singleton();
    auto *rs = RenderingServer::get_singleton();
    const std::map<String, RenderingServer::GlobalShaderParameterType> types = {
        {"float", RenderingServer::GLOBAL_VAR_TYPE_FLOAT},
        {"vec3", RenderingServer::GLOBAL_VAR_TYPE_VEC3},
        {"vec4", RenderingServer::GLOBAL_VAR_TYPE_VEC4},
        {"sampler2D", RenderingServer::GLOBAL_VAR_TYPE_SAMPLER2D},
        {"sampler3D", RenderingServer::GLOBAL_VAR_TYPE_SAMPLER3D},
    };
    for (const Variant &entry : settings->get_property_list()) {
        Dictionary property = entry;
        String key = property["name"];
        if (!key.begins_with("shader_globals/goanna_"))
            continue;
        Dictionary definition = settings->get_setting(key);
        String type = definition["type"];
        auto found = types.find(type);
        if (found == types.end()) {
            UtilityFunctions::push_error("Unsupported player shader global type: ", type);
            continue;
        }
        String original = key.trim_prefix("shader_globals/");
        String scoped = "view_" + String::num_uint64(id) + "_" + original;
        m_names.emplace(original, scoped);
        Variant value = definition["value"];
        if (type.begins_with("sampler"))
            value = Variant();
        rs->global_shader_parameter_add(scoped, found->second, value);
    }
}

RenderScope::~RenderScope() {
    m_shaders.clear();
    for (const auto &entry : m_names)
        RenderingServer::get_singleton()->global_shader_parameter_remove(entry.second);
}

String RenderScope::name(const String &original) const {
    auto it = m_names.find(original);
    return it == m_names.end() ? original : it->second;
}

void RenderScope::set(const StringName &original, const Variant &value) {
    RenderingServer::get_singleton()->global_shader_parameter_set(name(original), value);
}

String RenderScope::expand(const String &code, const String &path, int depth) {
    if (depth > 16) {
        UtilityFunctions::push_error("Shader include depth exceeded: ", path);
        return String();
    }
    String expanded;
    for (const String &line : code.split("\n")) {
        String trimmed = line.strip_edges();
        if (trimmed.begins_with("#include")) {
            String include_path = trimmed.get_slice("\"", 1);
            if (!include_path.begins_with("res://"))
                include_path = path.get_base_dir().path_join(include_path);
            Ref<ShaderInclude> include = ResourceLoader::get_singleton()->load(include_path);
            if (include.is_valid())
                expanded += expand(include->get_code(), include_path, depth + 1);
        } else {
            expanded += line;
            expanded += "\n";
        }
    }
    return expanded;
}

Ref<Shader> RenderScope::load(const String &path) {
    auto found = m_shaders.find(path);
    if (found != m_shaders.end())
        return found->second;
    Ref<Shader> source = ResourceLoader::get_singleton()->load(path);
    if (source.is_null())
        return source;
    String code = expand(source->get_code(), path, 0);
    // Replace complete identifiers, including uses in expanded includes.
    String rewritten;
    for (int64_t i = 0; i < code.length();) {
        char32_t c = code[i];
        bool identifier = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        int64_t start = i++;
        if (identifier) {
            while (i < code.length()) {
                c = code[i];
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '_'))
                    break;
                ++i;
            }
        }
        String token = code.substr(start, i - start);
        rewritten += identifier ? name(token) : token;
    }
    Ref<Shader> shader;
    shader.instantiate();
    shader->set_code(rewritten);
    m_shaders.emplace(path, shader);
    return shader;
}
}
