cmake_minimum_required(VERSION 3.20)

project(stellac_self_hosted LANGUAGES NONE)
enable_testing()

set(STELLAC_EXECUTABLE "" CACHE FILEPATH
    "Stella compiler executable used to build the self-hosted compiler")

if(NOT STELLAC_EXECUTABLE)
    find_program(_found_stellac NAMES stellac)
    if(_found_stellac)
        set(STELLAC_EXECUTABLE "${_found_stellac}" CACHE FILEPATH
            "Stella compiler executable used to build the self-hosted compiler" FORCE)
    endif()
endif()

if(NOT STELLAC_EXECUTABLE OR NOT EXISTS "${STELLAC_EXECUTABLE}")
    message(FATAL_ERROR
        "Could not find stellac executable on PATH. "
        "Install stellac or pass -DSTELLAC_EXECUTABLE=<path>.")
endif()

message(STATUS "Using stellac: ${STELLAC_EXECUTABLE}")

set(STELLA_BINDINGS_DIR "" CACHE PATH
    "Installed Stella bindings directory")

if(NOT STELLA_BINDINGS_DIR)
    get_filename_component(_stellac_bin_dir "${STELLAC_EXECUTABLE}" DIRECTORY)
    get_filename_component(_stellac_prefix "${_stellac_bin_dir}" DIRECTORY)
    find_path(_found_stella_bindings
        NAMES llvm/core.sl
        HINTS "${_stellac_prefix}/share/stella/bind"
        PATHS /usr/local/share/stella/bind /usr/share/stella/bind
        NO_DEFAULT_PATH
    )
    if(_found_stella_bindings)
        set(STELLA_BINDINGS_DIR "${_found_stella_bindings}" CACHE PATH
            "Installed Stella bindings directory" FORCE)
    endif()
endif()

if(NOT STELLA_BINDINGS_DIR OR NOT EXISTS "${STELLA_BINDINGS_DIR}")
    message(FATAL_ERROR
        "Could not find installed Stella bindings directory. "
        "Install Stella bindings or pass -DSTELLA_BINDINGS_DIR=<path>.")
endif()

message(STATUS "Using Stella bindings: ${STELLA_BINDINGS_DIR}")

set(STELLAC_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(STELLAC_ENTRY "${STELLAC_SRC_DIR}/main.sl")
set(STELLAC_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/stellac")
set(STELLAC_DEPFILE "${CMAKE_CURRENT_BINARY_DIR}/stellac.d")

set(STELLAC_INCLUDE_ARGS
    "--src.include=${STELLAC_SRC_DIR}"
    "--src.include=${STELLA_BINDINGS_DIR}"
)

add_custom_command(
    OUTPUT "${STELLAC_OUTPUT}"
    COMMAND "${STELLAC_EXECUTABLE}"
            "${STELLAC_ENTRY}"
            "--build.output=${STELLAC_OUTPUT}"
            "--emit.depfile=${STELLAC_DEPFILE}"
            "--opt.level=high"
            "--opt.lto=full"
            "--opt.function-sections"
            "--link.icf=all"
            "--link.lib=LLVM-23"
            "--link.driver=clang"
            "--link.program=lld"
            ${STELLAC_INCLUDE_ARGS}
    DEPENDS "${STELLAC_ENTRY}"
    DEPFILE "${STELLAC_DEPFILE}"
    COMMENT "Building self-hosted stellac"
    VERBATIM
)

add_custom_target(stellac_bin ALL DEPENDS "${STELLAC_OUTPUT}")

install(PROGRAMS "${STELLAC_OUTPUT}" DESTINATION bin)

add_test(
    NAME lexer
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/lexer.sh"
            "${STELLAC_OUTPUT}"
            "${CMAKE_CURRENT_BINARY_DIR}/test_work/lexer"
)

add_test(
    NAME diagnostics
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/diagnostics.sh"
            "${STELLAC_OUTPUT}"
            "${CMAKE_CURRENT_BINARY_DIR}/test_work/diagnostics"
)

add_test(
    NAME parser
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/parser.sh"
            "${STELLAC_OUTPUT}"
            "${CMAKE_CURRENT_BINARY_DIR}/test_work/parser"
            "${STELLAC_SRC_DIR}"
)

add_test(
    NAME sema
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/sema.sh"
            "${STELLAC_OUTPUT}"
            "${CMAKE_CURRENT_BINARY_DIR}/test_work/sema"
)

add_test(
    NAME codegen
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/codegen.sh"
            "${STELLAC_OUTPUT}"
            "${CMAKE_CURRENT_BINARY_DIR}/test_work/codegen"
)

add_test(
    NAME parity
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/parity.sh"
            "${STELLAC_OUTPUT}"
            "${STELLAC_EXECUTABLE}"
            "${CMAKE_CURRENT_BINARY_DIR}/test_work/parity"
            "${STELLAC_SRC_DIR}"
            "${CMAKE_CURRENT_SOURCE_DIR}/../Standard Library/src"
)
