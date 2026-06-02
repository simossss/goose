cmake_minimum_required(VERSION 3.22.1)

project(goose_android_bridge C)

set(GOOSE_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../")

add_library(goose_android_bridge SHARED goose_android_bridge.c)

target_include_directories(goose_android_bridge PRIVATE
    "${GOOSE_REPO_ROOT}/Rust/core/include"
)

target_link_libraries(goose_android_bridge
    dl
)
