// rot.c: rotation through libmpv's render API, on the frameworks of a build.
// tools/rotate/run.sh builds and runs it.
//
// mpv rotates in the VO when the VO can (VO_CAP_ROTATE90: the render API's
// vo=libmpv, vo=gpu), and otherwise asks lavfi for its `rotate` filter,
// which this FFmpeg does not have (media-kit's full flavor: overlay and
// equalizer are the only filters). The clips are four coloured quadrants
// (red, green / blue, white), so a frame's orientation is the colour of each
// quadrant of the picture: "RGBW" upright, "BRWG" turned 90 degrees
// clockwise, "WBGR" 180, "GWRB" 270.
//
// usage: rot <gl|glsw|sw> <file> <hwdec> [require-hwdec] [opt=value | +action ...]
//        rot null <file> <hwdec> [opt=value | +action ...]
//   gl, glsw, sw  as tools/shot: a hardware-accelerated CGL context, CGL's
//                 software renderer, the render API's software renderer.
//                 Plays <file> with vo=libmpv into a 640x640 target.
//   null          vo=null, no render context (media_kit's vo before it has
//                 a video output)
// actions, after FILE_LOADED:
//   +wait=<s>            keep rendering for <s> seconds
//   +set=<name>=<value>  mpv_set_property_string
//   +mark=<layout>       the last rendered frame has to have that layout
// require-hwdec: at every mark, hwdec-current has to be <hwdec> (decoding
// that fell back to software fails the mark instead of passing on the
// software path).
// The log is checked for mpv's messages about a rotation filter: with
// vo=libmpv there must be none; with vo=null the missing filter has to be
// reported ("filter 'rotate' not found or failed to allocate"). A process
// that dies (sw on rc5: an assertion) is a failure of run.sh's case.
// Prints "RESULT PASS|FAIL|SKIP ..."; exit 0 pass, 1 fail, 77 skip (no such
// OpenGL context here).
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <Mpv/client.h>
#include <Mpv/render.h>
#include <Mpv/render_gl.h>

#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

#define W 640
#define H 640

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void *get_proc(void *ctx, const char *name)
{
    static void *lib;
    if (!lib)
        lib = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
    return lib ? dlsym(lib, name) : NULL;
}

static const char *filter_msgs[] = {
    "filter 'rotate' not found or failed to allocate",
    "Inserting rotation filter.",
    "could not create rotation filter",
    "Video rotation with this format not supported",
};
static int filter_seen[4];

static int gl, glsw, null_vo, ended;
static GLuint fbo;
static mpv_render_context *rc;
static unsigned char pixels[W * H * 4];
static int rendered;

static char colour(int r, int g, int b)
{
    if (r > 150 && g > 150 && b > 150) return 'W';
    if (r > 150 && g < 100 && b < 100) return 'R';
    if (g > 150 && r < 100 && b < 100) return 'G';
    if (b > 150 && r < 100 && g < 100) return 'B';
    return '?';
}

// The layout of the last frame in pixels (top row first, RGBx).
static void layout(char out[64])
{
    int x0 = W, y0 = H, x1 = -1, y1 = -1;
    for (int y = 0; y < H; y += 2) {
        for (int x = 0; x < W; x += 2) {
            const unsigned char *p = pixels + (y * W + x) * 4;
            int m = p[0] > p[1] ? p[0] : p[1];
            m = m > p[2] ? m : p[2];
            if (m > 60) {
                if (x < x0) x0 = x; if (x > x1) x1 = x;
                if (y < y0) y0 = y; if (y > y1) y1 = y;
            }
        }
    }
    if (x1 < 0) {
        snprintf(out, 64, "none");
        return;
    }
    int pw = x1 - x0 + 1, ph = y1 - y0 + 1, n = 0;
    for (int qy = 0; qy < 2; qy++) {
        for (int qx = 0; qx < 2; qx++) {
            int x = x0 + pw * (1 + 2 * qx) / 4, y = y0 + ph * (1 + 2 * qy) / 4;
            const unsigned char *p = pixels + (y * W + x) * 4;
            out[n++] = colour(p[0], p[1], p[2]);
        }
    }
    snprintf(out + n, 64 - n, " picture=%dx%d at %d,%d", pw, ph, x0, y0);
}

static void render(void)
{
    if (!rc || !(mpv_render_context_update(rc) & MPV_RENDER_UPDATE_FRAME))
        return;
    if (gl) {
        // not flipped: row 0 of the FBO is the picture's top row, which is
        // what glReadPixels returns first
        int flip = 0;
        mpv_render_param rp[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &(mpv_opengl_fbo){.fbo = fbo, .w = W, .h = H}},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {0},
        };
        mpv_render_context_render(rc, rp);
        // mpv leaves another framebuffer bound
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFinish();
        glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        GLenum err = glGetError();
        if (err)
            printf("GL error 0x%x reading the frame back\n", err);
    } else {
        int size[2] = {W, H};
        size_t stride = W * 4;
        mpv_render_param rp[] = {
            {MPV_RENDER_PARAM_SW_SIZE, size},
            {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
            {MPV_RENDER_PARAM_SW_STRIDE, &stride},
            {MPV_RENDER_PARAM_SW_POINTER, pixels},
            {0},
        };
        mpv_render_context_render(rc, rp);
    }
    rendered++;
}

static void on_event(mpv_event *ev)
{
    if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
        mpv_event_log_message *m = ev->data;
        for (int i = 0; i < 4; i++) {
            if (strstr(m->text, filter_msgs[i]))
                filter_seen[i]++;
        }
        if (m->log_level <= MPV_LOG_LEVEL_WARN || strstr(m->text, "otat"))
            printf("LOG [%s/%s] %s", m->prefix, m->level, m->text);
    } else if (ev->event_id == MPV_EVENT_END_FILE) {
        ended = 1;
    }
}

static void run_for(mpv_handle *h, double secs)
{
    double t = now();
    do {
        render();
        mpv_event *ev = mpv_wait_event(h, 0.005);
        if (ev->event_id != MPV_EVENT_NONE)
            on_event(ev);
    } while (now() - t < secs);
}

int main(int argc, char **argv)
{
    if (argc < 4 || (strcmp(argv[1], "gl") && strcmp(argv[1], "glsw") && strcmp(argv[1], "sw") &&
                     strcmp(argv[1], "null"))) {
        fprintf(stderr, "usage: rot <gl|glsw|sw|null> <file> <hwdec> [opt=value | +action ...]\n");
        return 2;
    }
    glsw = !strcmp(argv[1], "glsw");
    gl = !strcmp(argv[1], "gl") || glsw;
    null_vo = !strcmp(argv[1], "null");
    const char *file = argv[2], *hwdec = argv[3];
    int require_hwdec = 0;
    for (int i = 4; i < argc; i++)
        require_hwdec |= !strcmp(argv[i], "require-hwdec");
    setvbuf(stdout, NULL, _IOLBF, 0);

    CGLContextObj cgl = NULL;
    if (gl) {
        CGLPixelFormatAttribute hw[] = {
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0,
        };
        CGLPixelFormatAttribute sw[] = {
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID, 0,
        };
        CGLPixelFormatObj pix = NULL;
        GLint npix = 0;
        if (CGLChoosePixelFormat(glsw ? sw : hw, &pix, &npix) != kCGLNoError || !pix ||
            CGLCreateContext(pix, NULL, &cgl) != kCGLNoError) {
            printf("RESULT SKIP no %s OpenGL context here\n", glsw ? "software" : "hardware-accelerated");
            return 77;
        }
        CGLSetCurrentContext(cgl);
        printf("GL %s | %s\n", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));
        GLuint tex;
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    }

    mpv_handle *h = mpv_create();
    mpv_set_option_string(h, "vo", null_vo ? "null" : "libmpv");
    mpv_set_option_string(h, "hwdec", hwdec);
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "terminal", "no");
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "loop-file", "inf");
    for (int i = 4; i < argc; i++) {
        if (argv[i][0] == '+')
            continue;
        char k[256];
        const char *eq = strchr(argv[i], '=');
        if (!eq)
            continue;
        snprintf(k, sizeof k, "%.*s", (int)(eq - argv[i]), argv[i]);
        printf("opt %s=%s -> %s\n", k, eq + 1, mpv_error_string(mpv_set_option_string(h, k, eq + 1)));
    }
    if (mpv_initialize(h) < 0) {
        printf("RESULT FAIL mpv_initialize\n");
        return 1;
    }
    mpv_request_log_messages(h, "info");

    if (!null_vo) {
        mpv_render_param params[3] = {{0}};
        if (gl) {
            params[0] = (mpv_render_param){MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL};
            params[1] = (mpv_render_param){MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                           &(mpv_opengl_init_params){.get_proc_address = get_proc}};
        } else {
            params[0] = (mpv_render_param){MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW};
        }
        if (mpv_render_context_create(&rc, h, params) < 0) {
            printf("RESULT FAIL mpv_render_context_create\n");
            return 1;
        }
    }

    const char *load[] = {"loadfile", file, NULL};
    mpv_command(h, load);
    int loaded = 0;
    double t0 = now();
    while (!loaded && !ended && now() - t0 < 20) {
        render();
        mpv_event *ev = mpv_wait_event(h, 0.005);
        if (ev->event_id == MPV_EVENT_FILE_LOADED)
            loaded = 1;
        else if (ev->event_id != MPV_EVENT_NONE)
            on_event(ev);
    }
    int marks = 0, good = 0;
    for (int i = 4; loaded && i < argc; i++) {
        if (argv[i][0] != '+')
            continue;
        const char *a = argv[i] + 1;
        if (!strncmp(a, "wait=", 5)) {
            run_for(h, atof(a + 5));
        } else if (!strncmp(a, "set=", 4)) {
            char k[256];
            const char *eq = strchr(a + 4, '=');
            snprintf(k, sizeof k, "%.*s", (int)(eq - (a + 4)), a + 4);
            int r = mpv_set_property_string(h, k, eq + 1);
            printf("SET %s=%s%s%s\n", k, eq + 1, r < 0 ? " -> " : "", r < 0 ? mpv_error_string(r) : "");
        } else if (!strncmp(a, "mark=", 5)) {
            char got[64];
            layout(got);
            char *hw = mpv_get_property_string(h, "hwdec-current");
            char *rot = mpv_get_property_string(h, "video-params/rotate");
            int ok = !strncmp(got, a + 5, 4) && got[4] == ' ';
            int hw_ok = !require_hwdec || (hw && !strcmp(hw, hwdec));
            printf("MARK %s: %s (hwdec-current %s, video-params/rotate %s) %s%s\n", a + 5, got, hw ? hw : "-",
                   rot ? rot : "-", ok && hw_ok ? "ok" : "FAIL", hw_ok ? "" : " (not the required hwdec)");
            ok = ok && hw_ok;
            mpv_free(hw);
            mpv_free(rot);
            marks++;
            good += ok;
        }
    }
    run_for(h, 0.1);
    if (rc)
        mpv_render_context_free(rc);
    mpv_terminate_destroy(h);
    if (cgl) {
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(cgl);
    }
    for (int i = 0; i < 4; i++) {
        if (filter_seen[i])
            printf("FILTER %dx \"%s\"\n", filter_seen[i], filter_msgs[i]);
    }
    int any = filter_seen[0] + filter_seen[1] + filter_seen[2] + filter_seen[3];
    int pass = loaded && marks == good &&
               (null_vo ? filter_seen[0] > 0 && !filter_seen[1] : any == 0) &&
               (null_vo || rendered > 0);
    const char *base = strrchr(file, '/') ? strrchr(file, '/') + 1 : file;
    printf("RESULT %s (%s, %s, hwdec=%s%s: %d of %d marks, %s)\n", pass ? "PASS" : "FAIL", argv[1], base, hwdec,
           require_hwdec ? " required" : "", good, marks,
           null_vo ? (filter_seen[0] ? "the missing rotate filter reported" : "no rotate filter message")
                   : (any ? "rotation filter messages" : "no rotation filter asked for"));
    return pass ? 0 : 1;
}
