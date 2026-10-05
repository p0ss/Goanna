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

# Speech to text for voice typing (src/goanna_speech_input.cpp): whisper.cpp,
# a submodule pinned to a release, linked statically on the CPU. ggml builds
# for the machine compiling it by default, which would crash another CPU, so
# the instruction set is fixed instead: AVX2 with FMA and F16C, which every
# x86-64 PC since about 2013 and the Steam Deck have. OpenMP is off so the
# release carries no extra runtime library; ggml uses its own thread pool.
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
if(GOANNA_ARCH STREQUAL "x86_64")
    foreach(_goanna_ggml_isa GGML_AVX GGML_AVX2 GGML_FMA GGML_F16C)
        set(${_goanna_ggml_isa} ON CACHE BOOL "" FORCE)
    endforeach()
endif()
# Static: whisper.cpp and ggml declare BUILD_SHARED_LIBS with option(), which
# under their older policy settings ignores a value set here unless CMP0077
# is NEW, and a shared libwhisper is a file the release would not carry.
set(_goanna_shared_libs ${BUILD_SHARED_LIBS})
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
set(BUILD_SHARED_LIBS OFF)
add_subdirectory(whisper.cpp EXCLUDE_FROM_ALL)
set(BUILD_SHARED_LIBS ${_goanna_shared_libs})

add_library(goanna SHARED
    src/register_types.cpp
    src/goanna_client.cpp
    src/goanna_render_scope.cpp
    src/goanna_lava.cpp
    src/goanna_flame.cpp
    src/goanna_session.cpp
    src/goanna_mesher.cpp
    src/goanna_radial_form.cpp
    src/goanna_mesh_pool.cpp
    src/goanna_light.cpp
    src/goanna_lod.cpp
    src/goanna_lod_storage.cpp
    src/goanna_horizon.cpp
    src/goanna_fine.cpp
    src/goanna_client_fine.cpp
    src/goanna_surface.cpp
    src/goanna_client_surface.cpp
    src/goanna_materials.cpp
    src/goanna_grass.cpp
    src/goanna_store.cpp
    src/goanna_occlusion.cpp
    src/goanna_animation.cpp
    src/goanna_models.cpp
    src/goanna_textures.cpp
    src/goanna_sky.cpp
    src/goanna_entities.cpp
    src/goanna_overlay_companions.cpp
    src/goanna_texture_size.cpp
    src/goanna_upright_sprite.cpp
    src/goanna_icon_raster.cpp
    src/goanna_item_icons.cpp
    src/goanna_ripples.cpp
    src/goanna_limbs.cpp
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
    src/goanna_speech_input.cpp
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

add_executable(goanna_lod_storage_test EXCLUDE_FROM_ALL src/goanna_lod_storage_test.cpp)
target_include_directories(goanna_lod_storage_test PRIVATE src)
target_link_libraries(goanna_lod_storage_test PRIVATE goanna luanti_core)

# Node item icons through upstream's node visuals and item mesh and Goanna's
# rasteriser, from node definitions alone: a mesh node on an atlas must not
# come out as a folded cube. Not built by default:
# cmake --build build --target goanna_item_icon_test
add_executable(goanna_item_icon_test EXCLUDE_FROM_ALL src/goanna_item_icon_test.cpp)
target_include_directories(goanna_item_icon_test PRIVATE src)
# godot-cpp only for the inline code its headers bring in; nothing in the
# test calls into Godot, and the extension's own copy stays private to it.
target_link_libraries(goanna_item_icon_test PRIVATE goanna luanti_core godot::cpp)

# Which tiles and sprites take the flame material. Links godot-cpp for the
# same reason as the icon test.
add_executable(goanna_flame_test EXCLUDE_FROM_ALL src/goanna_flame_test.cpp)
target_include_directories(goanna_flame_test PRIVATE src)
target_link_libraries(goanna_flame_test PRIVATE goanna luanti_core godot::cpp)

# Which array shader a tile is drawn with: by the tile's own layer, not by
# whether its array holds a cut-out anywhere. Links godot-cpp for the same
# reason as the icon test; nothing in it calls into Godot.
add_executable(goanna_array_route_test EXCLUDE_FROM_ALL src/goanna_array_route_test.cpp)
target_include_directories(goanna_array_route_test PRIVATE src)
target_link_libraries(goanna_array_route_test PRIVATE goanna luanti_core godot::cpp)

# The one scheduling rule every queue shares: the Z mirror crossing into
# Godot space, class bands, and a view cone that weights rather than filters.
add_executable(goanna_horizon_test EXCLUDE_FROM_ALL
    src/goanna_horizon_test.cpp
    src/goanna_horizon.cpp)
target_include_directories(goanna_horizon_test PRIVATE src)

add_executable(goanna_schedule_test EXCLUDE_FROM_ALL src/goanna_schedule_test.cpp)
target_include_directories(goanna_schedule_test PRIVATE src)
target_link_libraries(goanna_schedule_test PRIVATE luanti_core)

# The mesh worker pool's contract: no job lost, none run twice, resubmission
# replaces, cancel drops, priority orders.
add_executable(goanna_shared_cache_test EXCLUDE_FROM_ALL src/goanna_shared_cache_test.cpp)
target_include_directories(goanna_shared_cache_test PRIVATE src)
target_link_libraries(goanna_shared_cache_test PRIVATE Threads::Threads)

add_executable(goanna_mesh_pool_test EXCLUDE_FROM_ALL
    src/goanna_mesh_pool_test.cpp
    src/goanna_mesh_pool.cpp
)
target_include_directories(goanna_mesh_pool_test PRIVATE src)
target_link_libraries(goanna_mesh_pool_test PRIVATE luanti_core)

# Sub node form. Mostly a check that this and the Lua in Kythen bake the same
# authored shapes: they disagreeing is a block that changes shape on connect,
# which no screenshot of either half would show. Pure arithmetic, so it links
# nothing.
add_executable(goanna_radial_form_test EXCLUDE_FROM_ALL
    src/goanna_radial_form_test.cpp
    src/goanna_radial_form.cpp
)
target_include_directories(goanna_radial_form_test PRIVATE src)
# Overlay stacks and their composited LabPBR companions, for mob skins drawn
# as several layers. Pure arithmetic, so it links nothing.
add_executable(goanna_overlay_companions_test EXCLUDE_FROM_ALL
    src/goanna_overlay_companions_test.cpp
    src/goanna_overlay_companions.cpp
)
target_include_directories(goanna_overlay_companions_test PRIVATE src)
# The texture resolution tier's reduction: which maps are over the cap, and
# the filters that bring them to it. The arithmetic links nothing; the cap
# through the texture source links the extension, like the tile companion
# test, with no Godot runtime.
add_executable(goanna_texture_size_test EXCLUDE_FROM_ALL src/goanna_texture_size_test.cpp)
target_include_directories(goanna_texture_size_test PRIVATE src)
target_link_libraries(goanna_texture_size_test PRIVATE goanna luanti_core godot::cpp)
# The upright_sprite object visual's two quads against the vanilla client's.
# Pure arithmetic, so it links nothing.
add_executable(goanna_upright_sprite_test EXCLUDE_FROM_ALL
    src/goanna_upright_sprite_test.cpp
    src/goanna_upright_sprite.cpp
)
target_include_directories(goanna_upright_sprite_test PRIVATE src)
# Which companion a node tile string draws with: the base image's, or one
# composed for an authored overlay, a [combine or a [transform, through the
# extension's texture source with no Godot runtime.
add_executable(goanna_tile_companion_test EXCLUDE_FROM_ALL src/goanna_tile_companion_test.cpp)
target_include_directories(goanna_tile_companion_test PRIVATE src)
target_link_libraries(goanna_tile_companion_test PRIVATE goanna luanti_core godot::cpp)
add_executable(goanna_mining_cycle_test EXCLUDE_FROM_ALL
    src/goanna_mining_cycle_test.cpp src/goanna_radial_form.cpp)
target_include_directories(goanna_mining_cycle_test PRIVATE src)

# Luanti 5.17's animation tracks without Godot: AO_CMD_* animation messages
# through the transplanted active object, tracks resolved against a mesh by
# number and by name, and the joints they pose, by priority, blended, and
# back at rest once stopped.
add_executable(goanna_animation_test EXCLUDE_FROM_ALL
    src/goanna_animation_test.cpp
    src/goanna_animation.cpp
    src/transplant/client/content_cao.cpp
    src/transplant/collision.cpp
    src/transplant/localplayer.cpp
    src/luanti_shims.cpp)
target_include_directories(goanna_animation_test PRIVATE src)
target_link_libraries(goanna_animation_test PRIVATE luanti_core)

# transplanted client files use bare includes ("mapblock_mesh.h") that must
# resolve to Luanti's originals; goanna's own headers come first.
set_source_files_properties(
    src/transplant/client/mapblock_mesh.cpp src/transplant/client/content_mapblock.cpp
    src/transplant/client/node_visuals.cpp src/transplant/client/imagesource.cpp
    src/transplant/client/content_cao.cpp src/transplant/client/wieldmesh.cpp
    src/transplant/client/item_visuals_manager.cpp
    PROPERTIES INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/src;${CMAKE_SOURCE_DIR}/luanti/src/client")
target_link_libraries(goanna PRIVATE godot::cpp luanti_core whisper)
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

add_executable(goanna_surface_test EXCLUDE_FROM_ALL src/goanna_surface_test.cpp)
target_include_directories(goanna_surface_test PRIVATE src)
target_link_libraries(goanna_surface_test PRIVATE goanna luanti_core)

# The ripple field's physics: still water sleeps, a moving body pushes a
# crest ahead and leaves a V, banks stop waves, the sponge soaks them up.
add_executable(goanna_ripples_test EXCLUDE_FROM_ALL src/goanna_ripples_test.cpp)
target_include_directories(goanna_ripples_test PRIVATE src)
target_link_libraries(goanna_ripples_test PRIVATE goanna godot::cpp)

# Player limbs split at the knee and elbow, and the swim and tread poses.
add_executable(goanna_limbs_test EXCLUDE_FROM_ALL src/goanna_limbs_test.cpp)
target_include_directories(goanna_limbs_test PRIVATE src)
target_link_libraries(goanna_limbs_test PRIVATE goanna luanti_core godot::cpp)

# Leaves side by side through the transplanted mesh generator: one face per
# shared plane. Links godot-cpp for the same reason as the icon test.
add_executable(goanna_allfaces_test EXCLUDE_FROM_ALL src/goanna_allfaces_test.cpp)
target_include_directories(goanna_allfaces_test PRIVATE src)
target_link_libraries(goanna_allfaces_test PRIVATE goanna luanti_core godot::cpp)

# Every native test, built and then run by `cmake --build build --target
# check`. The tests are EXCLUDE_FROM_ALL, so the default build never touches
# them, and on 2026-09-19 a run of ./build/<test> executed binaries from 16
# September against sources three days newer. A target that depends on each
# test makes the build system, which knows every test's real inputs, decide
# what is stale, rather than a person remembering to rebuild by name.
set(GOANNA_NATIVE_TESTS
    goanna_allfaces_test
    goanna_animation_test
    goanna_array_route_test
    goanna_flame_test
    goanna_horizon_test
    goanna_item_icon_test
    goanna_light_test
    goanna_limbs_test
    goanna_lod_storage_test
    goanna_lod_test
    goanna_mesh_pool_test
    goanna_overlay_companions_test
    goanna_shared_cache_test
    goanna_texture_size_test
    goanna_tile_companion_test
    goanna_mining_cycle_test
    goanna_radial_form_test
    goanna_ripples_test
    goanna_schedule_test
    goanna_surface_test
    goanna_upright_sprite_test
)

# A test source with no entry above would build by name and never run under
# check, which is the stale binary problem again in another form. An entry
# with no source is the other half: build/goanna_trees_test outlived its
# source, and anything that globbed build/ for tests would have run it.
file(GLOB _goanna_test_sources RELATIVE "${CMAKE_SOURCE_DIR}/src"
    "${CMAKE_SOURCE_DIR}/src/goanna_*_test.cpp")
foreach(_source IN LISTS _goanna_test_sources)
    string(REGEX REPLACE "\\.cpp$" "" _test "${_source}")
    if(NOT _test IN_LIST GOANNA_NATIVE_TESTS)
        message(FATAL_ERROR "src/${_source} is not in GOANNA_NATIVE_TESTS; "
            "add it there so the check target builds and runs it")
    endif()
endforeach()

# Arguments a test needs under check, as <test>_ARGS. The radial form
# reference moved to tools/test/dig-review with the tools regrouping; the
# binary's own default still names tools/dig-review.
set(goanna_radial_form_test_ARGS tools/test/dig-review/reference_v3.json)

set(_goanna_check_commands)
foreach(_test IN LISTS GOANNA_NATIVE_TESTS)
    if(NOT TARGET ${_test})
        message(FATAL_ERROR "GOANNA_NATIVE_TESTS names ${_test}, which has no target")
    endif()
    list(APPEND _goanna_check_commands
        COMMAND ${CMAKE_COMMAND} -E echo "== ${_test}"
        COMMAND $<TARGET_FILE:${_test}> ${${_test}_ARGS})
endforeach()
# Run from the repository root, where the tests have always been run from,
# since some of them read Luanti's files by relative path. The first failing
# test stops the target with its exit status.
add_custom_target(check
    ${_goanna_check_commands}
    COMMAND ${CMAKE_COMMAND} -E echo "== all native tests passed"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
add_dependencies(check ${GOANNA_NATIVE_TESTS})
