cmake_minimum_required(VERSION 3.5.0)
project(tts_decoder)

add_library(mp3_decoder SHARED mp3_decoder.cpp)
target_include_directories(mp3_decoder PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(mp3_decoder PUBLIC libace_napi.z.so libhilog_ndk.z.so)
