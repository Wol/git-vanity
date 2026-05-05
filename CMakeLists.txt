cmake_minimum_required(VERSION 3.18)
project(git_vanity CUDA CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

find_package(OpenSSL REQUIRED)
find_package(nlohmann_json REQUIRED)

add_executable(git_vanity vanity_git.cu)

set_target_properties(git_vanity PROPERTIES
    CUDA_ARCHITECTURES "89"
    CUDA_SEPARABLE_COMPILATION OFF
)

target_compile_options(git_vanity PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:
        --use_fast_math
        -O3
        --generate-line-info
    >
)

target_link_libraries(git_vanity
    OpenSSL::SSL
    OpenSSL::Crypto
    nlohmann_json::nlohmann_json
)
