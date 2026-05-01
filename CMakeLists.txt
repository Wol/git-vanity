cmake_minimum_required(VERSION 4.2)
project(git_vanity)

set(CMAKE_CXX_STANDARD 14)

add_executable(git_vanity
        vanity_git.cpp)


target_link_libraries(git_vanity -lssl -lcrypto -pthread )