# libangle

Static ANGLE libraries for Windows x64.

## Build and test

Build requirements are Git, PowerShell 7.3 or later, CMake 3.24 or later, Visual Studio 2022 with the C++ x64 toolset, and a Windows 10 or 11 SDK. The commands below run from the repository root.

```powershell
pwsh -File scripts/build-angle.ps1
cmake -S tests -B smoke-build -G 'Visual Studio 17 2022' -A x64
cmake --build smoke-build --config Release
ctest --test-dir smoke-build -C Release --output-on-failure --no-tests=error
```

The `-Revision <full-angle-sha>` option selects a specific ANGLE commit. The script selects an installed SDK, syncs the pinned checkout into `.angle-work`, checks and applies the patches, and writes the ZIP and checksum to `dist`. The `-DANGLE_ZIP=C:/path/to/angle-windows-x64-static.zip` option selects a downloaded release for the smoke test.

The **Build ANGLE** workflow supports manual runs against upstream main. Pushes to `main` also build, and the Monday schedule skips revisions with an existing release. The release and artifact steps run after the MSVC smoke test succeeds. The test links both complete archive contents to expose duplicate or unresolved symbols and runs without creating a window.

The build retains the upstream D3D11 and NULL backends.

## MSVC and CMake integration

The package contains public headers in `include/` and two static libraries in `lib/`. MSVC consumers use the x64 Release configuration and the dynamic CRT (`/MD`). The required definitions are `ANGLE_STATIC=1` and empty values for `ANGLE_EXPORT`, `EGLAPI`, `GL_APICALL`, and `GL_API`. Both archives and the Windows SDK libraries listed in `BUILD_INFO.txt` are required at link time.

```cmake
# ANGLE_ROOT points to the extracted package.
add_library(angle_static INTERFACE)
target_include_directories(angle_static INTERFACE "${ANGLE_ROOT}/include")
target_compile_definitions(angle_static INTERFACE
  ANGLE_STATIC=1 ANGLE_EXPORT= EGLAPI= GL_APICALL= GL_API=)

file(STRINGS "${ANGLE_ROOT}/BUILD_INFO.txt" angle_libs REGEX "^Windows libraries: ")
string(REGEX REPLACE "^Windows libraries: " "" angle_libs "${angle_libs}")
separate_arguments(angle_libs WINDOWS_COMMAND "${angle_libs}")
target_link_libraries(angle_static INTERFACE
  "${ANGLE_ROOT}/lib/libEGL_static.lib"
  "${ANGLE_ROOT}/lib/libGLESv2_static.lib"
  ${angle_libs})

set_property(TARGET app PROPERTY MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
target_link_libraries(app PRIVATE angle_static)
```
