// shot.c: screenshot-raw through libmpv's render API, on the frameworks of a
// build. tools/shot/run.sh builds and runs it.
//
// Plays a file into an offscreen OpenGL context (CGL, 3.2 core, no advanced
// control: what media_kit_video's TextureHW does on macOS) or through the
// software renderer, and while the render loop keeps going asks for
// `screenshot-raw video` in bgr0 and in rgba64, asynchronously, the way an
// app calls it from another thread. With hwdec=videotoolbox in gl mode the
// frames are VideoToolbox images, which the screenshot has to download
// first (plynic-mpv d75b92b584, upstream c66204b69b: 0.41 handed them to
// libswscale and every such screenshot failed).
//
// Checks, per format: the command succeeds; w/h are the video's display
// size; stride and data size fit; the picture is not blank (the clips are
// FFmpeg's testsrc2).
//
// usage: shot <gl|sw> <file> <hwdec> [require-hwdec]
// Prints "HWDEC <hwdec-current>", one "SHOT ..." line per format and
// "RESULT PASS|FAIL|SKIP ..."; exit 0 pass, 1 fail, 77 skip (no OpenGL
// context here). With require-hwdec, decoding in software is a failure.
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
#define H 360

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

static int64_t get_int(mpv_handle *h, const char *name)
{
    int64_t v = -1;
    mpv_get_property(h, name, MPV_FORMAT_INT64, &v);
    return v;
}

// Checks one screenshot-raw reply. Returns 1 when it is a picture.
static int check_shot(mpv_event *ev, const char *want_fmt, int bpp, int64_t dw, int64_t dh)
{
    mpv_node *res = &((mpv_event_command *)ev->data)->result;
    if (ev->error < 0 || res->format != MPV_FORMAT_NODE_MAP) {
        printf("SHOT %s fail: %s\n", want_fmt, mpv_error_string(ev->error));
        return 0;
    }
    int64_t w = 0, h = 0, stride = 0;
    const char *fmt = "?";
    mpv_byte_array *ba = NULL;
    for (int i = 0; i < res->u.list->num; i++) {
        const char *k = res->u.list->keys[i];
        mpv_node *v = &res->u.list->values[i];
        if (!strcmp(k, "w") && v->format == MPV_FORMAT_INT64) w = v->u.int64;
        if (!strcmp(k, "h") && v->format == MPV_FORMAT_INT64) h = v->u.int64;
        if (!strcmp(k, "stride") && v->format == MPV_FORMAT_INT64) stride = v->u.int64;
        if (!strcmp(k, "format") && v->format == MPV_FORMAT_STRING) fmt = v->u.string;
        if (!strcmp(k, "data") && v->format == MPV_FORMAT_BYTE_ARRAY) ba = v->u.ba;
    }
    int ok = ba && w == dw && h == dh && stride >= w * bpp && ba->size >= (size_t)(stride * h) &&
             !strcmp(fmt, want_fmt);
    // not blank: the brightest and darkest of a grid of samples (one byte
    // per channel; the high byte for rgba64) differ a lot
    int lo = 255, hi = 0;
    for (int64_t y = 0; ok && y < h; y += 8) {
        for (int64_t x = 0; x < w; x += 8) {
            const unsigned char *px = (const unsigned char *)ba->data + y * stride + x * bpp;
            for (int c = 0; c < 3; c++) {
                int v = bpp == 8 ? px[c * 2 + 1] : px[c];
                lo = v < lo ? v : lo;
                hi = v > hi ? v : hi;
            }
        }
    }
    ok = ok && hi - lo > 64;
    printf("SHOT %s %s: %lldx%lld (video %lldx%lld) stride=%lld format=%s bytes=%zu range=%d..%d\n",
           want_fmt, ok ? "ok" : "fail", (long long)w, (long long)h, (long long)dw, (long long)dh,
           (long long)stride, fmt, ba ? ba->size : 0, lo, hi);
    return ok;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: shot <gl|sw> <file> <hwdec> [require-hwdec]\n");
        return 2;
    }
    int gl = !strcmp(argv[1], "gl");
    const char *file = argv[2], *hwdec = argv[3];
    int require_hwdec = argc > 4 && !strcmp(argv[4], "require-hwdec");
    setvbuf(stdout, NULL, _IOLBF, 0);

    CGLContextObj cgl = NULL;
    GLuint fbo = 0;
    if (gl) {
        CGLPixelFormatAttribute attrs[] = {
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0,
        };
        CGLPixelFormatObj pix = NULL;
        GLint npix = 0;
        if (CGLChoosePixelFormat(attrs, &pix, &npix) != kCGLNoError || !pix ||
            CGLCreateContext(pix, NULL, &cgl) != kCGLNoError) {
            printf("RESULT SKIP no OpenGL context here\n");
            return 77;
        }
        CGLSetCurrentContext(cgl);
        GLuint tex;
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    }

    mpv_handle *h = mpv_create();
    mpv_set_option_string(h, "vo", "libmpv");
    mpv_set_option_string(h, "hwdec", hwdec);
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "terminal", "no");
    mpv_set_option_string(h, "keep-open", "yes");
    if (mpv_initialize(h) < 0) {
        printf("RESULT FAIL mpv_initialize\n");
        return 1;
    }
    mpv_request_log_messages(h, "warn");

    mpv_render_param params[4] = {{0}};
    if (gl) {
        params[0] = (mpv_render_param){MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL};
        params[1] = (mpv_render_param){MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                       &(mpv_opengl_init_params){.get_proc_address = get_proc}};
    } else {
        params[0] = (mpv_render_param){MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW};
    }
    mpv_render_context *rc;
    if (mpv_render_context_create(&rc, h, params) < 0) {
        printf("RESULT FAIL mpv_render_context_create\n");
        return 1;
    }

    const char *load[] = {"loadfile", file, NULL};
    mpv_command(h, load);

    static unsigned char swbuf[W * H * 4];
    const char *formats[] = {"bgr0", "rgba64"};
    const int bpps[] = {4, 8};
    int loaded = 0, rendered = 0, asked = 0, replies = 0, good = 0, ended = 0;
    int64_t dw = 0, dh = 0;
    double deadline = now() + 20;
    while (replies < 2 && !ended && now() < deadline) {
        if (mpv_render_context_update(rc) & MPV_RENDER_UPDATE_FRAME) {
            if (gl) {
                int flip = 1;
                mpv_render_param rp[] = {
                    {MPV_RENDER_PARAM_OPENGL_FBO, &(mpv_opengl_fbo){.fbo = fbo, .w = W, .h = H}},
                    {MPV_RENDER_PARAM_FLIP_Y, &flip},
                    {0},
                };
                mpv_render_context_render(rc, rp);
                glFlush();
            } else {
                int size[2] = {W, H};
                size_t stride = W * 4;
                mpv_render_param rp[] = {
                    {MPV_RENDER_PARAM_SW_SIZE, size},
                    {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
                    {MPV_RENDER_PARAM_SW_STRIDE, &stride},
                    {MPV_RENDER_PARAM_SW_POINTER, swbuf},
                    {0},
                };
                mpv_render_context_render(rc, rp);
            }
            rendered++;
        }
        mpv_event *ev = mpv_wait_event(h, 0.005);
        if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = ev->data;
            printf("LOG [%s/%s] %s", m->prefix, m->level, m->text);
        } else if (ev->event_id == MPV_EVENT_FILE_LOADED) {
            loaded = 1;
        } else if (ev->event_id == MPV_EVENT_END_FILE) {
            ended = 1;
        } else if (ev->event_id == MPV_EVENT_COMMAND_REPLY) {
            int i = (int)ev->reply_userdata;
            good += check_shot(ev, formats[i], bpps[i], dw, dh);
            replies++;
        }
        // a few frames in (paused there, so the frame stays the same)
        if (loaded && !asked && rendered >= 5) {
            mpv_set_property_string(h, "pause", "yes");
            dw = get_int(h, "dwidth");
            dh = get_int(h, "dheight");
            char *hw = mpv_get_property_string(h, "hwdec-current");
            char *vf = mpv_get_property_string(h, "video-params/hw-pixelformat");
            printf("HWDEC %s%s%s\n", hw ? hw : "-", vf ? " " : "", vf ? vf : "");
            if (require_hwdec && (!hw || !strcmp(hw, "no"))) {
                printf("RESULT FAIL decoding in software, hwdec=%s was required\n", hwdec);
                return 1;
            }
            mpv_free(hw);
            mpv_free(vf);
            for (int i = 0; i < 2; i++) {
                const char *cmd[] = {"screenshot-raw", "video", formats[i], NULL};
                mpv_command_async(h, i, cmd);
            }
            asked = 1;
        }
    }
    mpv_render_context_free(rc);
    mpv_terminate_destroy(h);
    if (cgl) {
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(cgl);
    }
    int pass = replies == 2 && good == 2;
    printf("RESULT %s (%s, %s: %d frames rendered, %d of %d screenshots)\n", pass ? "PASS" : "FAIL",
           gl ? "gl" : "sw", file, rendered, good, replies);
    return pass ? 0 : 1;
}
