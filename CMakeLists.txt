cmake_minimum_required(VERSION 3.22)
project(goanna LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Without a default, an unqualified `cmake -S . -B build` produces a build
# with no optimisation at all, which makes the meshing and collision code
# look far slower than it is.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

# Platform and architecture as Godot names them, for the library filename
# that project/goanna.gdextension expects.
if(WIN32)
    set(GOANNA_PLATFORM "windows")
elseif(APPLE)
    set(GOANNA_PLATFORM "macos")
else()
    set(GOANNA_PLATFORM "linux")
endif()
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _goanna_arch)
if(_goanna_arch MATCHES "aarch64|arm64")
    set(GOANNA_ARCH "arm64")
else()
    set(GOANNA_ARCH "x86_64")
endif()

# godot-cpp (GDExtension bindings). Debug template while we spike.
set(GODOTCPP_TARGET "template_debug" CACHE STRING "" FORCE)
add_subdirectory(godot-cpp EXCLUDE_FROM_ALL)

include(cmake/luanti_core.cmake)

add_library(goanna SHARED
    src/register_types.cpp
    src/goanna_client.cpp
    src/goanna_session.cpp
    src/goanna_mesher.cpp
    src/goanna_light.cpp
    src/goanna_lod.cpp
    src/goanna_materials.cpp
    src/goanna_store.cpp
    src/goanna_occlusion.cpp
    src/goanna_models.cpp
    src/goanna_textures.cpp
    src/goanna_sky.cpp
    src/goanna_entities.cpp
    src/iris/iris_glsl.cpp
    src/iris/iris_pack.cpp
    src/iris/goanna_iris_effect.cpp
    src/transplant/collision.cpp
    src/transplant/environment_raycast.cpp
    src/transplant/localplayer.cpp
    src/transplant/client/mapblock_mesh.cpp
    src/transplant/client/content_mapblock.cpp
    src/transplant/client/node_visuals.cpp
    src/transplant/client/imagesource.cpp
    src/transplant/client/content_cao.cpp
    src/transplant/client/wieldmesh.cpp
    src/transplant/client/item_visuals_manager.cpp
    src/luanti_shims.cpp
)
target_include_directories(goanna PRIVATE src)

# Offline check of the ambient occlusion tracer against a dense reference
# integral. Not built by default: cmake --build build --target goanna_light_test
add_executable(goanna_light_test EXCLUDE_FROM_ALL
    src/goanna_light_test.cpp
    src/goanna_occlusion.cpp
)
target_include_directories(goanna_light_test PRIVATE src)
target_link_libraries(goanna_light_test PRIVATE luanti_core)

# Coarse voxel topology: recursive XYZ mips and exposed lower faces.
add_executable(goanna_lod_test EXCLUDE_FROM_ALL src/goanna_lod_test.cpp)
target_include_directories(goanna_lod_test PRIVATE src)
target_link_libraries(goanna_lod_test PRIVATE goanna luanti_core)
# transplanted client files use bare includes ("mapblock_mesh.h") that must
# resolve to Luanti's originals; goanna's own headers come first.
set_source_files_properties(
    src/transplant/client/mapblock_mesh.cpp src/transplant/client/content_mapblock.cpp
    src/transplant/client/node_visuals.cpp src/transplant/client/imagesource.cpp
    src/transplant/client/content_cao.cpp src/transplant/client/wieldmesh.cpp
    src/transplant/client/item_visuals_manager.cpp
    PROPERTIES INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/src;${CMAKE_SOURCE_DIR}/luanti/src/client")
target_link_libraries(goanna PRIVATE godot::cpp luanti_core)
# GNU ld only. MSVC's link.exe rejects both, and godot-cpp already adds
# --no-undefined itself on the toolchains that understand it.
if(NOT MSVC)
    target_link_options(goanna PRIVATE -Wl,--exclude-libs,ALL -Wl,--no-undefined)
endif()

# Output straight into the Godot project so the .gdextension finds it. A DLL
# is a RUNTIME artifact, not a LIBRARY one, so Windows needs both set. The
# $<1:...> wrapper stops multi-config generators appending Release/ or Debug/.
set_target_properties(goanna PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "$<1:${CMAKE_SOURCE_DIR}/project/bin>"
    RUNTIME_OUTPUT_DIRECTORY "$<1:${CMAKE_SOURCE_DIR}/project/bin>"
    OUTPUT_NAME "goanna.${GOANNA_PLATFORM}.${GODOTCPP_TARGET}.${GOANNA_ARCH}"
    PREFIX "lib"
)
