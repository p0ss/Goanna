# Compiles the subset of Luanti's engine that Goanna transplants, as a
# static library with server-build semantics (MT_BUILDTARGET=2), so no
# Irrlicht render/GUI/scene types are pulled in. Header-only Irrlicht math
# types (irr/include) are kept.

set(LUANTI_DIR "${CMAKE_SOURCE_DIR}/luanti")
set(LUANTI_SRC "${LUANTI_DIR}/src")
set(LUANTI_GEN "${CMAKE_BINARY_DIR}/luanti_gen")
file(MAKE_DIRECTORY "${LUANTI_GEN}")

# Version and feature flags — none of the optional subsystems.
set(PROJECT_NAME_CAPITALIZED "Luanti")
set(VERSION_MAJOR 5)
set(VERSION_MINOR 16)
set(VERSION_PATCH 1)
set(VERSION_EXTRA "goanna")
set(VERSION_STRING "5.16.1-goanna")
set(SHAREDIR ".")
set(LOCALEDIR ".")
set(ICONDIR ".")
foreach(flag RUN_IN_PLACE DEVELOPMENT_BUILD ENABLE_UPDATE_CHECKER USE_GETTEXT USE_CURL
        USE_SOUND USE_CURSES USE_LEVELDB USE_LUAJIT USE_POSTGRESQL USE_PROMETHEUS USE_SPATIAL
        USE_SYSTEM_GMP USE_SYSTEM_JSONCPP USE_REDIS USE_OPENSSL HAVE_STRLCPY
        CURSES_HAVE_CURSES_H CURSES_HAVE_NCURSES_H CURSES_HAVE_NCURSES_NCURSES_H
        CURSES_HAVE_NCURSES_CURSES_H CURSES_HAVE_NCURSESW_NCURSES_H CURSES_HAVE_NCURSESW_CURSES_H
        BUILD_UNITTESTS BUILD_BENCHMARKS BUILD_WITH_TRACY)
    set(${flag} 0)
endforeach()
set(HAVE_ENDIAN_H 1)
set(HAVE_MALLOC_TRIM 1)
# cmake_config.h.in expects PROJECT_NAME etc. from the luanti project scope; emulate.
set(_saved_project_name "${PROJECT_NAME}")
set(PROJECT_NAME "luanti")
configure_file("${LUANTI_SRC}/cmake_config.h.in" "${LUANTI_GEN}/cmake_config.h")
set(PROJECT_NAME "${_saved_project_name}")

execute_process(COMMAND git -C "${LUANTI_DIR}" rev-parse --short HEAD
    OUTPUT_VARIABLE LUANTI_GITHASH OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
file(WRITE "${LUANTI_GEN}/cmake_config_githash.h"
    "#pragma once\n#define VERSION_GITHASH \"${VERSION_STRING}-${LUANTI_GITHASH}\"\n")

add_subdirectory("${LUANTI_DIR}/lib/gmp" "${CMAKE_BINARY_DIR}/lib_gmp" EXCLUDE_FROM_ALL)
add_subdirectory("${LUANTI_DIR}/lib/sha256" "${CMAKE_BINARY_DIR}/lib_sha256" EXCLUDE_FROM_ALL)
add_subdirectory("${LUANTI_DIR}/lib/jsoncpp" "${CMAKE_BINARY_DIR}/lib_jsoncpp" EXCLUDE_FROM_ALL)
target_include_directories(gmp INTERFACE "${LUANTI_DIR}/lib/gmp")
target_include_directories(jsoncpp INTERFACE "${LUANTI_DIR}/lib/jsoncpp")

find_package(ZLIB REQUIRED)
find_library(ZSTD_STATIC_LIB NAMES libzstd.a zstd HINTS /home/linuxbrew/.linuxbrew/opt/zstd/lib)
find_path(ZSTD_INCLUDE_DIR zstd.h HINTS /home/linuxbrew/.linuxbrew/opt/zstd/include)
if(NOT ZSTD_STATIC_LIB)
    message(FATAL_ERROR "zstd not found")
endif()

set(LUANTI_CORE_SRCS
    # plumbing
    debug.cpp log.cpp profiler.cpp settings.cpp porting.cpp filesys.cpp version.cpp
    gettext.cpp translation.cpp
    threading/thread.cpp threading/semaphore.cpp threading/event.cpp
    util/auth.cpp util/base64.cpp util/hashing.cpp util/numeric.cpp util/serialize.cpp
    util/sha1.cpp util/srp.cpp util/string.cpp util/timetaker.cpp util/ieee_float.cpp
    util/enum_string.cpp util/metricsbackend.cpp util/pointedthing.cpp util/directiontables.cpp
    # network (common part only; no server/client packet handlers)
    network/address.cpp network/connection.cpp network/mtp/impl.cpp network/mtp/threads.cpp
    network/networkpacket.cpp network/networkprotocol.cpp network/socket.cpp
    # world data
    serialization.cpp nameidmapping.cpp mapnode.cpp mapblock.cpp nodedef.cpp itemdef.cpp
    tool.cpp inventory.cpp itemstackmetadata.cpp metadata.cpp nodemetadata.cpp
    staticobject.cpp nodetimer.cpp tileanimation.cpp texture_override.cpp light.cpp
    content_nodemeta.cpp noise.cpp gettext_plural_form.cpp content_mapnode.cpp sound_spec.cpp voxel.cpp
    util/pointabilities.cpp convert_json.cpp map.cpp mapsector.cpp voxelalgorithms.cpp rollback_interface.cpp
)
list(TRANSFORM LUANTI_CORE_SRCS PREPEND "${LUANTI_SRC}/")

add_library(luanti_core STATIC ${LUANTI_CORE_SRCS})
target_include_directories(luanti_core PUBLIC
    "${LUANTI_SRC}" "${LUANTI_DIR}/irr/include" "${LUANTI_GEN}" "${ZSTD_INCLUDE_DIR}")
target_compile_definitions(luanti_core PUBLIC USE_CMAKE_CONFIG_H MT_BUILDTARGET=2)
target_compile_options(luanti_core PRIVATE -fvisibility=hidden -Wno-deprecated-declarations)
target_link_libraries(luanti_core PUBLIC gmp sha256 jsoncpp ZLIB::ZLIB "${ZSTD_STATIC_LIB}" pthread)
set_target_properties(gmp sha256 jsoncpp PROPERTIES POSITION_INDEPENDENT_CODE ON)
