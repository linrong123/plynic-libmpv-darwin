// kotest.c: the --sub-keepout checks (plynic-mpv "sub: make sub-keepout a
// subtitle option of every VO", plynic spec 0017 T-4) through libmpv's render
// API, on the frameworks of a build. tools/keepout/run.sh builds and runs it.
//
// Renders a black video with subtitles - the software renderer (libmpv_sw.c,
// draw_bmp) or OpenGL (vo_gpu's OSD path, via an offscreen CGL context) - and
// reports the bounding box of the subtitle pixels while --sub-keepout is
// changed, paused. What it checks:
//   - the option exists: a double, 0..50;
//   - with keepout=K the lowest subtitle pixel ends at or above the band
//     (h - K% of h), nothing leaves the frame, and the subtitle is moved, not
//     changed; one that already clears the band stays put;
//   - keepout back to 0 restores the original picture exactly;
//   - every change arrives as a redraw request while paused (update callback);
//   - the same lift after re-rendering the same picture (a seek to it).
// With "switch" instead of the checks: select sid 2, 1, 2 while paused and
// require a subtitle on screen after each (plynic-mpv "player: redraw when a
// track selected while paused gets its subtitles").
//
// usage: kotest <sw|gl> <file> <sid> <time> [switch] [opt=val ...]
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <Mpv/client.h>
#include <Mpv/render.h>
#include <Mpv/render_gl.h>

#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

#define W 1280
#define H 720

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int updates;

static void on_update(void *ctx)
{
    pthread_mutex_lock(&lock);
    updates++;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// Wait until the update callback fired (returns 1) or timeout (0).
static int wait_update(double timeout)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    double t = ts.tv_sec + ts.tv_nsec / 1e9 + timeout;
    ts.tv_sec = (time_t)t;
    ts.tv_nsec = (long)((t - ts.tv_sec) * 1e9);
    pthread_mutex_lock(&lock);
    int r = 1;
    while (!updates) {
        if (pthread_cond_timedwait(&cond, &lock, &ts)) {
            r = 0;
            break;
        }
    }
    updates = 0;
    pthread_mutex_unlock(&lock);
    return r;
}

static const char *mode;
static mpv_render_context *rctx;
static uint8_t *pixels;       // W*H*4
static GLuint fbo;

static void *gl_proc(void *ctx, const char *name)
{
    static void *lib;
    if (!lib)
        lib = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
    return dlsym(lib, name);
}

static int setup_gl(mpv_handle *h)
{
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAllowOfflineRenderers, 0,
    };
    CGLPixelFormatObj pix;
    GLint npix;
    if (CGLChoosePixelFormat(attrs, &pix, &npix) || !pix)
        return -1;
    CGLContextObj ctx;
    if (CGLCreateContext(pix, NULL, &ctx))
        return -1;
    CGLSetCurrentContext(ctx);
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        return -1;
    printf("GL %s / %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    mpv_opengl_init_params gp = {.get_proc_address = gl_proc};
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gp},
        {0},
    };
    return mpv_render_context_create(&rctx, h, params);
}

static int setup_sw(mpv_handle *h)
{
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
        {0},
    };
    return mpv_render_context_create(&rctx, h, params);
}

static void render(void)
{
    if (!strcmp(mode, "gl")) {
        mpv_opengl_fbo f = {.fbo = (int)fbo, .w = W, .h = H};
        int flip = 0;
        mpv_render_param p[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &f},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {0},
        };
        mpv_render_context_render(rctx, p);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    } else {
        int size[2] = {W, H};
        size_t stride = W * 4;
        mpv_render_param p[] = {
            {MPV_RENDER_PARAM_SW_SIZE, size},
            {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
            {MPV_RENDER_PARAM_SW_STRIDE, &stride},
            {MPV_RENDER_PARAM_SW_POINTER, pixels},
            {0},
        };
        mpv_render_context_render(rctx, p);
    }
}

struct bbox { int x0, y0, x1, y1, n; };

static struct bbox measure(void)
{
    struct bbox b = {W, H, -1, -1, 0};
    for (int y = 0; y < H; y++) {
        uint8_t *row = pixels + (size_t)y * W * 4;
        for (int x = 0; x < W; x++) {
            uint8_t *px = row + x * 4;
            if (px[0] > 48 || px[1] > 48 || px[2] > 48) {
                b.n++;
                if (x < b.x0) b.x0 = x;
                if (x > b.x1) b.x1 = x;
                if (y < b.y0) b.y0 = y;
                if (y > b.y1) b.y1 = y;
            }
        }
    }
    return b;
}

// Render whatever mpv asks for during `secs`, return the last picture's bbox.
static struct bbox settle(double secs, int *got_update, double *first_update)
{
    double t0 = now(), end = t0 + secs;
    int got = 0;
    double first = -1;
    while (now() < end) {
        if (wait_update(end - now())) {
            uint64_t f = mpv_render_context_update(rctx);
            if (f & MPV_RENDER_UPDATE_FRAME) {
                render();
                if (!got)
                    first = now() - t0;
                got++;
            }
        }
    }
    if (got_update)
        *got_update = got;
    if (first_update)
        *first_update = first;
    render(); // one more, in case the last request raced
    return measure();
}

static int fails;

static void report(const char *what, struct bbox b, int upd, double first)
{
    if (b.n)
        printf("%-28s bbox=%d,%d-%d,%d opaque=%d", what, b.x0, b.y0, b.x1 + 1, b.y1 + 1, b.n);
    else
        printf("%-28s empty", what);
    if (upd >= 0)
        printf(" redraws=%d first=%.0fms", upd, first * 1000);
    printf("\n");
}

static void check(int ok, const char *msg)
{
    printf("  %s %s\n", ok ? "PASS" : "FAIL", msg);
    if (!ok)
        fails++;
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s <sw|gl> <file> <sid> <time> [switch] [opt=val...]\n", argv[0]);
        return 2;
    }
    mode = argv[1];
    int switch_mode = argc > 5 && !strcmp(argv[5], "switch");
    pixels = aligned_alloc(64, (size_t)W * H * 4);

    mpv_handle *h = mpv_create();
    mpv_set_option_string(h, "vo", "libmpv");
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "pause", "yes");
    mpv_set_option_string(h, "start", argv[4]);
    mpv_set_option_string(h, "sid", argv[3]);
    mpv_set_option_string(h, "hwdec", "no");
    mpv_set_option_string(h, "terminal", "no");
    mpv_set_option_string(h, "msg-level", "all=warn");
    for (int i = 5; i < argc; i++) {
        char *eq = strchr(argv[i], '=');
        if (!eq)
            continue;
        *eq = '\0';
        int r = mpv_set_option_string(h, argv[i], eq + 1);
        printf("opt %s=%s -> %s\n", argv[i], eq + 1, mpv_error_string(r));
        *eq = '=';
    }
    if (mpv_initialize(h) < 0)
        return 1;
    char *ver = mpv_get_property_string(h, "mpv-version");
    printf("mpv-version: %s  mode=%s\n", ver, mode);
    mpv_free(ver);

    // The option itself: present, a double 0..50, flagged for OSD updates by
    // way of the group it lives in (the property layer only says it exists).
    char *oi = mpv_get_property_string(h, "option-info/sub-keepout/type");
    printf("option-info/sub-keepout/type = %s\n", oi ? oi : "(none)");
    check(oi && !strcmp(oi, "Double"), "sub-keepout is an option of type Double");
    mpv_free(oi);
    oi = mpv_get_property_string(h, "option-info/sub-keepout/max");
    check(oi && atof(oi) == 50, "sub-keepout max is 50");
    mpv_free(oi);

    if ((!strcmp(mode, "gl") ? setup_gl(h) : setup_sw(h)) < 0) {
        printf("render context: failed\n");
        return 1;
    }
    mpv_render_context_set_update_callback(rctx, on_update, NULL);

    const char *cmd[] = {"loadfile", argv[2], NULL};
    mpv_command(h, cmd);
    for (;;) {
        mpv_event *ev = mpv_wait_event(h, 10);
        if (ev->event_id == MPV_EVENT_PLAYBACK_RESTART)
            break;
        if (ev->event_id == MPV_EVENT_END_FILE || ev->event_id == MPV_EVENT_NONE) {
            printf("no playback restart\n");
            return 1;
        }
    }

    struct bbox base = settle(1.5, NULL, NULL);
    report("keepout=0 (start)", base, -1, 0);
    check(base.n > 0, "a subtitle is on screen");

    if (switch_mode) {
        for (int round = 0; round < 3; round++) {
            const char *to = round % 2 == 0 ? "2" : "1";
            mpv_set_property_string(h, "sid", to);
            int u; double f;
            struct bbox b = settle(1.5, &u, &f);
            char what[64];
            snprintf(what, sizeof(what), "paused switch to sid=%s", to);
            report(what, b, u, f);
            check(b.n > 0, "a subtitle is shown after the paused switch");
        }
        mpv_render_context_free(rctx);
        mpv_terminate_destroy(h);
        printf("RESULT %s fails=%d\n", fails ? "FAIL" : "PASS", fails);
        return fails ? 1 : 0;
    }

    int upd;
    double first;
    const double ks[] = {30, 45, 10, 0};
    struct bbox prev = base;
    for (int i = 0; i < 4; i++) {
        char v[16];
        snprintf(v, sizeof(v), "%g", ks[i]);
        mpv_set_property_string(h, "sub-keepout", v);
        struct bbox b = settle(1.0, &upd, &first);
        char what[64];
        snprintf(what, sizeof(what), "keepout=%s", v);
        report(what, b, upd, first);
        check(upd > 0, "the change was redrawn while paused");
        int limit = H - (int)(H * ks[i] / 100.0 + 0.5);
        if (ks[i] == 0) {
            check(b.y0 == base.y0 && b.y1 == base.y1 && b.x0 == base.x0 &&
                  b.x1 == base.x1 && b.n == base.n,
                  "keepout=0 restores the original picture");
        } else if (base.y1 < limit) {
            check(b.y0 == base.y0 && b.y1 == base.y1,
                  "a subtitle already above the band is not moved");
        } else {
            check(b.y1 < limit, "the lowest subtitle pixel clears the band");
            check(b.y0 >= 0, "nothing lifted out of the frame");
            check(b.x0 == base.x0 && b.x1 == base.x1 && b.n == base.n,
                  "the subtitle is moved, not changed");
        }
        prev = b;
    }
    (void)prev;

    // Hysteresis: while the band stays up, a seek to the same picture keeps
    // the same lift (steady baseline).
    mpv_set_property_string(h, "sub-keepout", "30");
    struct bbox k30 = settle(1.0, NULL, NULL);
    const char *seek[] = {"seek", argv[4], "absolute+exact", NULL};
    mpv_command(h, seek);
    struct bbox k30b = settle(1.5, NULL, NULL);
    report("keepout=30 after seek", k30b, -1, 0);
    check(k30b.y0 == k30.y0 && k30b.y1 == k30.y1, "same lift after re-render");

    // The alias exists only where vo_mediacodec_osd is built (Android).
    int r = mpv_set_property_string(h, "vo-mediacodec-osd-sub-keepout", "0");
    printf("vo-mediacodec-osd-sub-keepout -> %s\n", mpv_error_string(r));

    mpv_render_context_free(rctx);
    mpv_terminate_destroy(h);
    printf("RESULT %s fails=%d\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
