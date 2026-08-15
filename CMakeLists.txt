cmake_minimum_required(VERSION 3.22)
project(goanna LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# godot-cpp (GDExtension bindings). Debug template while we spike.
set(GODOTCPP_TARGET "template_debug" CACHE STRING "" FORCE)
add_subdirectory(godot-cpp EXCLUDE_FROM_ALL)

add_library(goanna SHARED
    src/register_types.cpp
    src/goanna_client.cpp
)
target_include_directories(goanna PRIVATE src)
target_link_libraries(goanna PRIVATE godot::cpp)

# Output straight into the Godot project so the .gdextension finds it.
set_target_properties(goanna PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/project/bin"
    OUTPUT_NAME "goanna.linux.template_debug.x86_64"
    PREFIX "lib"
)
