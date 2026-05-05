# git-vanity — brute-forces a git commit hash matching a chosen pattern by
# appending a nonce to the commit message.
#
# Targets:
#   git_vanity       — GPU search kernel (CUDA, requires NVIDIA GPU, SM 8.9)
#   git_vanity_hook  — post-commit git hook; reads .vanityconfig and amends HEAD
#   git_vanity_cpu   — CPU-only fallback using multi-threaded OpenSSL SHA1
#
# Dependencies:
#   OpenSSL          — SHA1 for baseline hash display and result verification
#   nlohmann_json    — JSON I/O (apt: nlohmann-json3-dev)
#   libgit2          — repository access in the hook (apt: libgit2-dev)
#   CUDA Toolkit     — required for git_vanity only (tested with 12.4)
#
# Build:
#   cmake -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#
# Install hook into a repo:
#   cp build/git_vanity_hook <repo>/.git/hooks/post-commit
#   chmod +x <repo>/.git/hooks/post-commit
#   cp .vanityconfig.example <repo>/.vanityconfig   # then edit to taste

cmake_minimum_required(VERSION 3.18)
project(git_vanity CUDA CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

find_package(OpenSSL REQUIRED)
find_package(nlohmann_json REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBGIT2 REQUIRED IMPORTED_TARGET libgit2)

# --- GPU search kernel ---
# Reads JSON from stdin, outputs newline-delimited JSON progress and result.
# Input fields: mode, prefix/pairs_count/repeat_count, tree, parent, author,
#               committer, message, cores_free.
add_executable(git_vanity vanity_git.cu)

set_target_properties(git_vanity PROPERTIES
    CUDA_ARCHITECTURES "89"          # Ada Lovelace (RTX 1000 Ada). Change for other GPUs:
                                     #   75 = Turing, 86 = Ampere, 89 = Ada, 90 = Hopper
    CUDA_SEPARABLE_COMPILATION OFF
)

target_compile_options(git_vanity PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:
        --use_fast_math              # allows fused ops; safe for integer SHA1 work
        -O3
        --generate-line-info         # enables profiling with ncu without full debug info
    >
)

target_link_libraries(git_vanity
    OpenSSL::SSL
    OpenSSL::Crypto
    nlohmann_json::nlohmann_json
)

# --- Post-commit hook ---
# Uses libgit2 to read the latest commit, invokes git_vanity (must be on PATH),
# then amends HEAD in-place preserving original author/committer timestamps.
# Configuration is loaded from .vanityconfig in the repository root.
add_executable(git_vanity_hook git_vanity_hook.cpp)
target_compile_options(git_vanity_hook PRIVATE -O2)
target_link_libraries(git_vanity_hook
    nlohmann_json::nlohmann_json
    PkgConfig::LIBGIT2
)
