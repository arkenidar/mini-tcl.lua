cmake_minimum_required(VERSION 3.16)
project(mini-tcl VERSION 0.2.1 LANGUAGES C)

option(STATIC "Build a fully static binary" OFF)

set(MINILUA_URL "https://raw.githubusercontent.com/edubart/minilua/main/minilua.h")
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/minilua.h")
    message(STATUS "Downloading minilua.h ...")
    file(DOWNLOAD "${MINILUA_URL}" "${CMAKE_CURRENT_SOURCE_DIR}/minilua.h" STATUS dl)
    list(GET dl 0 dl_code)
    if(NOT dl_code EQUAL 0)
        file(REMOVE "${CMAKE_CURRENT_SOURCE_DIR}/minilua.h")
        message(FATAL_ERROR "Failed to download minilua.h: ${dl}")
    endif()
endif()

# The generated header lives in the source dir, same as in the Makefile build,
# so the two build systems never disagree about which embedded script is used.
set(SCRIPT_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/mini_tcl_script.h")
add_custom_command(
    OUTPUT "${SCRIPT_HEADER}"
    COMMAND ${CMAKE_COMMAND}
        -DIN=${CMAKE_CURRENT_SOURCE_DIR}/mini-tcl.lua
        -DOUT=${SCRIPT_HEADER}
        -DNAME=mini_tcl_script
        -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed.cmake
    DEPENDS mini-tcl.lua cmake/embed.cmake
    COMMENT "Embedding mini-tcl.lua"
)

# Second embedded chunk: the WebAssembly output adapter (browser only).
set(WASM_GLUE_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/wasm_glue.h")
add_custom_command(
    OUTPUT "${WASM_GLUE_HEADER}"
    COMMAND ${CMAKE_COMMAND}
        -DIN=${CMAKE_CURRENT_SOURCE_DIR}/wasm-glue.lua
        -DOUT=${WASM_GLUE_HEADER}
        -DNAME=wasm_glue
        -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed.cmake
    DEPENDS wasm-glue.lua cmake/embed.cmake
    COMMENT "Embedding wasm-glue.lua"
)

if(EMSCRIPTEN)
    # Configure with: emcmake cmake -B build-wasm && cmake --build build-wasm
    # Produces docs/minitcl-wasm.{js,wasm} (same artifact as `make wasm`).
    # main-wasm.c defines LUA_IMPL and #includes minilua.h itself, so no extra
    # compile flags are needed here (minilua.h has no include guard).
    add_executable(minitcl-wasm main-wasm.c "${SCRIPT_HEADER}" "${WASM_GLUE_HEADER}")
    set_target_properties(minitcl-wasm PROPERTIES
        OUTPUT_NAME minitcl-wasm
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/docs"
        SUFFIX ".js")
    target_link_options(minitcl-wasm PRIVATE
        "SHELL:-sASSERTIONS=1"
        "SHELL:-sMODULARIZE=1" "SHELL:-sEXPORT_NAME=createMiniTcl"
        "SHELL:-sENVIRONMENT=web,node" "SHELL:-sALLOW_MEMORY_GROWTH=1"
        "SHELL:-sEXPORTED_RUNTIME_METHODS=cwrap,UTF8ToString"
        "SHELL:-sEXPORTED_FUNCTIONS=_mini_tcl_eval,_malloc,_free")
    return()
endif()

add_executable(mini-tcl main.c "${SCRIPT_HEADER}")

find_library(MATH_LIBRARY m)
if(MATH_LIBRARY)
    target_link_libraries(mini-tcl PRIVATE ${MATH_LIBRARY})
endif()

if(STATIC)
    target_link_options(mini-tcl PRIVATE -static)
endif()

install(TARGETS mini-tcl RUNTIME DESTINATION bin)

enable_testing()
add_test(
    NAME smoke
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/run-tests.sh" "$<TARGET_FILE:mini-tcl>"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
)
