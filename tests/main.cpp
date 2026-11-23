#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <cstdio>

#ifndef EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE
#error Missing ANGLE WebGL compatibility extension
#endif

int main()
{
    const char *clientExtensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    if (!clientExtensions)
    {
        std::fprintf(stderr, "EGL client extension query failed: 0x%x\n", eglGetError());
        return 1;
    }
    std::printf("EGL client extensions: %s\n", clientExtensions);

    // ANGLE supports this entry point with no current GL context.
    std::printf("GLES glGetError without a context: 0x%x\n", glGetError());
    if (!eglGetProcAddress("glGetString"))
    {
        std::fputs("EGL could not resolve glGetString.\n", stderr);
        return 1;
    }

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY)
    {
        std::fprintf(stderr, "eglGetDisplay failed: 0x%x\n", eglGetError());
        return 1;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (!eglInitialize(display, &major, &minor))
    {
        const EGLint error = eglGetError();
        std::printf("eglInitialize failed on the default display: 0x%x\n", error);
        return error == EGL_NOT_INITIALIZED ? 0 : 1;
    }

    const char *version = eglQueryString(display, EGL_VERSION);
    const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
    if (version && extensions)
    {
        std::printf("EGL %d.%d (%s)\nDisplay extensions: %s\n", major, minor, version, extensions);
    }
    const EGLBoolean terminated = eglTerminate(display);
    return version && extensions && terminated == EGL_TRUE ? 0 : 1;
}
