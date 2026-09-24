// probe: load Mpv.framework the way an app does (@rpath, the 19 frameworks
// next to each other) and ask it what it is; optionally play something.
//
//   probe --check                        versions + required decoders/demuxers
//   probe <url> [seconds] [opt=val ...]  play with vo=null ao=null, report
//
// Prints one "RESULT ..." line; exit status 0 on success. Plays: FILE_LOADED
// and time-pos advancing. The log lines of the "tls" and "ffmpeg" modules are
// printed as they come ("LOG ..."), which is what a TLS matrix looks at.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <Mpv/client.h>

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// decoder-list has video and audio decoders only (subtitle decoders are not
// listed there)
static const char *decoders[] = {
    "h264", "hevc", "vp9", "av1", "libdav1d", "mpeg2video", "mpeg4", "rv40", "rv60",
    "aac", "ac3", "eac3", "dca", "truehd", "mlp", "flac", "opus", "vorbis", "cook",
    NULL,
};
static const char *demuxers[] = {
    "matroska", "mov", "mpegts", "hls", "dash", "rm", "flv", "avi", "truehd", NULL,
};

// "matroska,webm" names both
static int in_commalist(const char *list, const char *name)
{
    size_t n = strlen(name);
    for (const char *p = list; p && *p; p = strchr(p, ',') ? strchr(p, ',') + 1 : NULL) {
        if (!strncmp(p, name, n) && (p[n] == ',' || p[n] == '\0'))
            return 1;
    }
    return 0;
}

static int has(mpv_node *list, const char *key, const char *name)
{
    if (list->format != MPV_FORMAT_NODE_ARRAY)
        return 0;
    for (int i = 0; i < list->u.list->num; i++) {
        mpv_node *e = &list->u.list->values[i];
        if (e->format == MPV_FORMAT_STRING && in_commalist(e->u.string, name))
            return 1;
        if (e->format == MPV_FORMAT_NODE_MAP) {
            for (int j = 0; j < e->u.list->num; j++) {
                if (!strcmp(e->u.list->keys[j], key) &&
                    e->u.list->values[j].format == MPV_FORMAT_STRING &&
                    !strcmp(e->u.list->values[j].u.string, name))
                    return 1;
            }
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    int check = argc > 1 && !strcmp(argv[1], "--check");
    const char *url = !check && argc > 1 ? argv[1] : NULL;
    double secs = argc > 2 && url ? atof(argv[2]) : 2;

    mpv_handle *h = mpv_create();
    if (!h) {
        printf("RESULT FAIL mpv_create\n");
        return 1;
    }
    mpv_set_option_string(h, "vo", "null");
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "terminal", "no");
    for (int i = 3; url && i < argc; i++) {
        char *eq = strchr(argv[i], '=');
        if (!eq)
            continue;
        *eq = '\0';
        int r = mpv_set_option_string(h, argv[i], eq + 1);
        if (r < 0)
            printf("opt %s: %s\n", argv[i], mpv_error_string(r));
        *eq = '=';
    }
    if (mpv_initialize(h) < 0) {
        printf("RESULT FAIL mpv_initialize\n");
        return 1;
    }
    unsigned long api = mpv_client_api_version();
    char *mv = mpv_get_property_string(h, "mpv-version");
    char *fv = mpv_get_property_string(h, "ffmpeg-version");
    printf("client-api %lu.%lu\nmpv-version %s\nffmpeg-version %s\n", api >> 16, api & 0xffff,
           mv ? mv : "?", fv ? fv : "?");
    mpv_free(mv);
    mpv_free(fv);

    if (check) {
        int missing = 0;
        mpv_node dec, dmx;
        if (mpv_get_property(h, "decoder-list", MPV_FORMAT_NODE, &dec) < 0 ||
            mpv_get_property(h, "demuxer-lavf-list", MPV_FORMAT_NODE, &dmx) < 0) {
            printf("RESULT FAIL lists\n");
            return 1;
        }
        for (int i = 0; decoders[i]; i++) {
            if (!has(&dec, "driver", decoders[i])) {
                printf("MISSING decoder %s\n", decoders[i]);
                missing++;
            }
        }
        for (int i = 0; demuxers[i]; i++) {
            if (!has(&dmx, "", demuxers[i])) {
                printf("MISSING demuxer %s\n", demuxers[i]);
                missing++;
            }
        }
        mpv_free_node_contents(&dec);
        mpv_free_node_contents(&dmx);
        mpv_terminate_destroy(h);
        printf("RESULT %s missing=%d\n", missing ? "FAIL" : "PASS", missing);
        return missing ? 1 : 0;
    }
    if (!url) {
        mpv_terminate_destroy(h);
        printf("RESULT PASS\n");
        return 0;
    }

    mpv_request_log_messages(h, "v");
    const char *cmd[] = {"loadfile", url, NULL};
    mpv_command(h, cmd);
    int loaded = 0, ended = 0, err = 0;
    double t0 = -1, t1 = -1;
    while (!ended) {
        mpv_event *ev = mpv_wait_event(h, secs + 10);
        if (ev->event_id == MPV_EVENT_NONE)
            break;
        if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = ev->data;
            if (!strcmp(m->prefix, "ffmpeg") || strstr(m->text, "tls:") ||
                (m->log_level <= MPV_LOG_LEVEL_WARN))
                printf("LOG [%s/%s] %s", m->prefix, m->level, m->text);
        } else if (ev->event_id == MPV_EVENT_FILE_LOADED) {
            loaded = 1;
            mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &t0);
            char *v = mpv_get_property_string(h, "current-tracks/video/codec");
            char *a = mpv_get_property_string(h, "current-tracks/audio/codec");
            printf("PLAY loaded video=%s audio=%s\n", v ? v : "-", a ? a : "-");
            mpv_free(v);
            mpv_free(a);
            break;
        } else if (ev->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *e = ev->data;
            err = e->error;
            ended = 1;
        }
    }
    if (loaded) {
        // let it play for `secs` of wall-clock time
        double end = now() + secs;
        while (now() < end) {
            mpv_event *ev = mpv_wait_event(h, end - now());
            if (ev->event_id == MPV_EVENT_END_FILE) {
                err = ((mpv_event_end_file *)ev->data)->error;
                break;
            }
        }
        mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &t1);
        char *ao = mpv_get_property_string(h, "current-ao");
        char *hw = mpv_get_property_string(h, "hwdec-current");
        printf("PLAY time-pos %.2f -> %.2f ao=%s hwdec=%s\n", t0, t1, ao ? ao : "-", hw ? hw : "-");
        mpv_free(ao);
        mpv_free(hw);
    }
    mpv_terminate_destroy(h);
    int ok = loaded && t1 > t0 && err >= 0;
    printf("RESULT %s loaded=%d error=%s\n", ok ? "PLAY" : "NOPLAY", loaded,
           err < 0 ? mpv_error_string(err) : "none");
    return ok ? 0 : 1;
}
