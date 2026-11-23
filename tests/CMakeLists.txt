cmake_minimum_required(VERSION 3.24)
project(angle_smoke LANGUAGES CXX)

if(NOT MSVC OR NOT CMAKE_GENERATOR_PLATFORM STREQUAL "x64")
  message(FATAL_ERROR "Use Visual Studio 2022 with -A x64.")
endif()

set(ANGLE_ZIP "${CMAKE_CURRENT_SOURCE_DIR}/../dist/angle-windows-x64-static.zip"
    CACHE FILEPATH "ANGLE ZIP to test")
set(package "${CMAKE_CURRENT_BINARY_DIR}/smoke-package")
file(MAKE_DIRECTORY "${package}")
file(ARCHIVE_EXTRACT INPUT "${ANGLE_ZIP}" DESTINATION "${package}")

file(STRINGS "${package}/BUILD_INFO.txt" link_line REGEX "^Windows libraries: ")
if(NOT link_line)
  message(FATAL_ERROR "Windows library list is missing from BUILD_INFO.txt.")
endif()
string(REGEX REPLACE "^Windows libraries: " "" windows_libs "${link_line}")
separate_arguments(windows_libs WINDOWS_COMMAND "${windows_libs}")

enable_testing()
add_executable(angle_smoke main.cpp)
set_property(TARGET angle_smoke PROPERTY MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
target_include_directories(angle_smoke PRIVATE "${package}/include")
target_compile_definitions(angle_smoke PRIVATE ANGLE_STATIC=1 ANGLE_EXPORT= EGLAPI= GL_APICALL= GL_API=)
target_link_libraries(angle_smoke PRIVATE
  "$<LINK_LIBRARY:WHOLE_ARCHIVE,${package}/lib/libEGL_static.lib,${package}/lib/libGLESv2_static.lib>"
  ${windows_libs})
target_link_options(angle_smoke PRIVATE /WX)
add_test(NAME angle_smoke COMMAND angle_smoke)
