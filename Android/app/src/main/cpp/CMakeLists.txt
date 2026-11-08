cmake_minimum_required(VERSION 3.22)
project(lighttouch_android LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(LT_NATIVE_JOBS 2 CACHE STRING "Maximum concurrent native compile/link jobs")
set_property(GLOBAL PROPERTY JOB_POOLS "lt_native=${LT_NATIVE_JOBS}")
set(CMAKE_JOB_POOL_COMPILE lt_native)
set(CMAKE_JOB_POOL_LINK lt_native)
if(NOT EXISTS "${LT_PORTABLE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Set -PportableDir to the shared Portable source checkout")
endif()
set(LT_BUILD_TESTS OFF CACHE BOOL "" FORCE)
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(LIGHTTOUCH_ENABLE_DEBUG_QMP ON CACHE BOOL "" FORCE)
else()
    set(LIGHTTOUCH_ENABLE_DEBUG_QMP OFF CACHE BOOL "" FORCE)
endif()
add_subdirectory("${LT_PORTABLE_DIR}" "${CMAKE_BINARY_DIR}/portable")
add_library(un1box_jni SHARED un1box_jni.cpp)
# Optimize frame conversion and the shared publisher/control loop in Debug
# without replacing its symbols/assertion flags or changing release policy.
# Runtime.cpp belongs to the Portable target's source-property directory.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR
   (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND
    CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "GNU"))
    set(LT_ANDROID_DEBUG_OPTIMIZATION "$<$<CONFIG:Debug>:-O2>")
    set_property(SOURCE un1box_jni.cpp APPEND PROPERTY
                 COMPILE_OPTIONS "${LT_ANDROID_DEBUG_OPTIMIZATION}")
    set_property(SOURCE "${LT_PORTABLE_DIR}/src/Runtime.cpp"
                 TARGET_DIRECTORY lighttouch_runtime APPEND PROPERTY
                 COMPILE_OPTIONS "${LT_ANDROID_DEBUG_OPTIMIZATION}")
endif()
target_include_directories(un1box_jni PRIVATE "${LT_PORTABLE_DIR}/include")
target_link_libraries(un1box_jni PRIVATE lighttouch_runtime android log jnigraphics)
target_link_options(un1box_jni PRIVATE "-Wl,-z,max-page-size=16384")
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_definitions(un1box_jni PRIVATE LT_ANDROID_DEBUG=1)
    target_sources(un1box_jni PRIVATE "${LIGHTTOUCH_QEMU_SOURCE}/contrib/portable/engine-qmp-snapshot.c")
    set_source_files_properties("${LIGHTTOUCH_QEMU_SOURCE}/contrib/portable/engine-qmp-snapshot.c" PROPERTIES COMPILE_DEFINITIONS LIGHTTOUCH_QMP_SNAPSHOT_NO_MAIN=1)
    add_library(lighttouch_probe SHARED tcg_probe.cpp)
    target_link_libraries(lighttouch_probe PRIVATE dl)
    target_link_options(lighttouch_probe PRIVATE "-Wl,-z,max-page-size=16384")
endif()
# Real Bionic engine closure supplied by the backend build, never host glibc libs.
if(NOT EXISTS "${LT_ENGINE_ROOT}/${ANDROID_ABI}/libqemu-arm.so")
    message(FATAL_ERROR "Missing real engine at engineRoot/${ANDROID_ABI}/libqemu-arm.so")
endif()
file(GLOB LT_ENGINE_LIBRARIES "${LT_ENGINE_ROOT}/${ANDROID_ABI}/*.so")
foreach(LT_LIBRARY IN LISTS LT_ENGINE_LIBRARIES)
    get_filename_component(LT_NAME "${LT_LIBRARY}" NAME_WE)
    if(LT_NAME STREQUAL "libc++_shared")
        continue() # AGP packages the same pinned NDK runtime via ANDROID_STL.
    endif()
    add_library("${LT_NAME}" SHARED IMPORTED)
    set_target_properties("${LT_NAME}" PROPERTIES IMPORTED_LOCATION "${LT_LIBRARY}")
    target_link_libraries(un1box_jni PRIVATE "${LT_NAME}")
    if(TARGET lighttouch_probe)
        target_link_libraries(lighttouch_probe PRIVATE "${LT_NAME}")
    endif()
endforeach()
# The prebuilt engine libs carry no SONAME, so linking by path bakes the build
# host's absolute path into DT_NEEDED and the device's linker then fails with
# "library C:/... not found". AGP's C++ model rejects -l:name linker flags, so
# fix the linked binaries in place instead: rewrite every DT_NEEDED that points
# at an engine library to its bare filename (same-length NUL padding, dynstr
# offsets untouched).
find_program(LT_PATCH_PYTHON NAMES python3 python)
if(LT_PATCH_PYTHON)
    add_custom_command(TARGET un1box_jni POST_BUILD
        COMMAND "${LT_PATCH_PYTHON}" "${CMAKE_CURRENT_SOURCE_DIR}/patch-needed.py"
                "$<TARGET_FILE:un1box_jni>" "${LT_ENGINE_ROOT}/${ANDROID_ABI}"
        VERBATIM)
    if(TARGET lighttouch_probe)
        add_custom_command(TARGET lighttouch_probe POST_BUILD
            COMMAND "${LT_PATCH_PYTHON}" "${CMAKE_CURRENT_SOURCE_DIR}/patch-needed.py"
                    "$<TARGET_FILE:lighttouch_probe>" "${LT_ENGINE_ROOT}/${ANDROID_ABI}"
            VERBATIM)
    endif()
else()
    message(WARNING "python not found: DT_NEEDED entries will keep build-host paths")
endif()
