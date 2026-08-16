cmake_minimum_required(VERSION 3.22)
project(goanna LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# godot-cpp (GDExtension bindings). Debug template while we spike.
set(GODOTCPP_TARGET "template_debug" CACHE STRING "" FORCE)
add_subdirectory(godot-cpp EXCLUDE_FROM_ALL)

include(cmake/luanti_core.cmake)

add_library(goanna SHARED
    src/register_types.cpp
    src/goanna_client.cpp
    src/goanna_session.cpp
    src/goanna_mesher.cpp
    src/goanna_textures.cpp
    src/goanna_sky.cpp
    src/goanna_active_object.cpp
    src/goanna_entities.cpp
    src/transplant/collision.cpp
    src/transplant/environment_raycast.cpp
    src/transplant/localplayer.cpp
    src/transplant/client/mapblock_mesh.cpp
    src/transplant/client/content_mapblock.cpp
    src/transplant/client/node_visuals.cpp
    src/transplant/client/imagesource.cpp
    src/luanti_shims.cpp
)
target_include_directories(goanna PRIVATE src)
# transplanted client files use bare includes ("mapblock_mesh.h") that must
# resolve to Luanti's originals; goanna's own headers come first.
set_source_files_properties(
    src/transplant/client/mapblock_mesh.cpp src/transplant/client/content_mapblock.cpp
    src/transplant/client/node_visuals.cpp src/transplant/client/imagesource.cpp
    PROPERTIES INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/src;${CMAKE_SOURCE_DIR}/luanti/src/client")
target_link_libraries(goanna PRIVATE godot::cpp luanti_core)
target_link_options(goanna PRIVATE -Wl,--exclude-libs,ALL -Wl,--no-undefined)

# Output straight into the Godot project so the .gdextension finds it.
set_target_properties(goanna PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/project/bin"
    OUTPUT_NAME "goanna.linux.template_debug.x86_64"
    PREFIX "lib"
)
