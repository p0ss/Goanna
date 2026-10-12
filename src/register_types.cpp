// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The GDExtension's entry point, goanna_library_init, named in
// project/goanna.gdextension. It registers the six classes GDScript can
// make: GoannaClient (the whole client), GoannaIrisEffect,
// GoannaIrisGbuffers, GoannaIrisShadow, GoannaRipples and
// GoannaSpeechInput. Godot calls it
// on the main thread as the extension loads, at the scene initialisation
// level.

#include "goanna_client.h"
#include "goanna_ripples.h"
#include "goanna_speech_input.h"
#include "iris/goanna_iris_effect.h"
#include "iris/goanna_iris_gbuffers.h"
#include "iris/goanna_iris_shadow.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_goanna(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
        return;
    GDREGISTER_CLASS(goanna::GoannaClient);
    GDREGISTER_CLASS(goanna::GoannaIrisEffect);
    GDREGISTER_CLASS(goanna::GoannaIrisGbuffers);
    GDREGISTER_CLASS(goanna::GoannaIrisShadow);
    GDREGISTER_CLASS(goanna::GoannaRipples);
    GDREGISTER_CLASS(goanna::GoannaSpeechInput);
}

static void uninitialize_goanna(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
        return;
}

extern "C" {
GDExtensionBool GDE_EXPORT goanna_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_goanna);
    init_obj.register_terminator(uninitialize_goanna);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
