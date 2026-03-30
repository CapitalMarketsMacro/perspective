cmake_minimum_required(VERSION 3.18.2)
project(perspective-protos)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(PSP_PROTO_PATH "Path to the perspective proto directory" "")

if(NOT DEFINED psp_build_message)
    function(psp_build_message message)
        set(BUILD_MESSAGE "${BUILD_MESSAGE}\n${message}")
    endfunction()
endif()

# Include the FindProtobuf.cmake module
list(APPEND CMAKE_MODULE_PATH "../../cmake/modules")

if(NOT DEFINED PSP_CMAKE_MODULE_PATH)
    set(PSP_CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../cmake")
    message(STATUS "PSP_CMAKE_MODULE_PATH not defined, using ${PSP_CMAKE_MODULE_PATH}")
endif()

# Detect vcpkg toolchain
if(DEFINED CMAKE_TOOLCHAIN_FILE AND CMAKE_TOOLCHAIN_FILE MATCHES "vcpkg")
    set(PSP_USE_VCPKG TRUE)
else()
    set(PSP_USE_VCPKG FALSE)
endif()

if(PSP_USE_VCPKG)
    # === vcpkg path: protobuf is already installed ===
    find_package(Protobuf CONFIG REQUIRED)
    find_package(Protoc REQUIRED)

    set(PROTO_FILES "${PSP_PROTO_PATH}/perspective.proto")
    protobuf_generate_cpp(PROTO_SRCS PROTO_HDRS ${PROTO_FILES})
    add_library(protos STATIC ${PROTO_SRCS} ${PROTO_HDRS})
    target_link_libraries(protos protobuf::libprotobuf)
    target_include_directories(protos PUBLIC ${CMAKE_BINARY_DIR}/protos-build)
else()
    # === ExternalProject path ===
    find_package(Protoc REQUIRED)
    find_package(InstallDependency REQUIRED)

    psp_build_dep("protobuf" "${PSP_CMAKE_MODULE_PATH}/protobuf.txt.in")

    set(PROTO_FILES "${PSP_PROTO_PATH}/perspective.proto")
    protobuf_generate_cpp(PROTO_SRCS PROTO_HDRS ${PROTO_FILES})
    add_library(protos STATIC ${PROTO_SRCS} ${PROTO_HDRS})
    target_include_directories(protos PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/protobuf-src/src)
    target_include_directories(protos PUBLIC ${CMAKE_BINARY_DIR}/protos-build)
    target_link_libraries(protos protobuf::libprotobuf)
endif()
