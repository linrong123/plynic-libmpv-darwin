// fallprobe.c: what mpv does with a video stream no decoder can open.
// Loads <file> with the given options, reads mpv's log (level v) and asks the
// core for time-pos once a second without blocking (mpv_get_property_async).
// A request not answered within 3 s means the core is wedged; the probe then
// leaves with _exit() (mpv_terminate_destroy would wait for the core forever).
//
//   host:    fallprobe <seconds> <file> [opt=value ...]   (tools/fallback/run.sh)
//   Android: RotateProbe <libmpv.so> <libfallprobe.so> <WxH>[:private] <file> <seconds>|opt=value ...
//            (RotateProbe.java of tools/rotate-check; "@0" = its Surface)
// Prints the counts of the lines that matter and "RESULT responsive|wedged".
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __ANDROID__
#include <jni.h>
#include <mpv/client.h>
#else
#include <Mpv/client.h>
#endif

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static const char *keys[] = {
    "Could not open codec.",
    "Attempting next decoding method after failure of",
    "Failed to initialize a decoder for codec",
    "No decoding method left for this stream.",
    "Video: no video",
    "Using software decoding.",
};
#define NKEYS (int)(sizeof(keys) / sizeof(keys[0]))

static int probe(int argc, const char **argv, const char *surface_ref)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    double secs = atof(argv[0]);
    const char *file = argv[1];
    mpv_handle *c = mpv_create();
    mpv_set_option_string(c, "config", "no");
    mpv_set_option_string(c, "terminal", "no");
    mpv_set_option_string(c, "ao", "null");
    for (int i = 2; i < argc; i++) {
        char k[256], v[512];
        const char *eq = strchr(argv[i], '=');
        if (!eq)
            continue;
        snprintf(k, sizeof k, "%.*s", (int)(eq - argv[i]), argv[i]);
        snprintf(v, sizeof v, "%s", (surface_ref && !strcmp(eq + 1, "@0")) ? surface_ref : eq + 1);
        printf("opt %s=%s -> %s\n", k, v, mpv_error_string(mpv_set_option_string(c, k, v)));
    }
    mpv_request_log_messages(c, "v");
    if (mpv_initialize(c) < 0) {
        printf("RESULT init-failed\n");
        return 2;
    }
    char *ver = mpv_get_property_string(c, "mpv-version");
    printf("mpv-version %s\n", ver ? ver : "?");
    mpv_free(ver);
    const char *cmd[] = {"loadfile", file, NULL};
    mpv_command(c, cmd);

    double t0 = now(), first[NKEYS] = {0};
    long count[NKEYS] = {0}, lines = 0;
    double asked_at = 0, last_ask = 0, max_wait = 0;
    uint64_t pending = 0, next_id = 1;
    int wedged = 0, answered = 0;
    char end[128] = "";
    while (now() - t0 < secs) {
        double t = now();
        if (!pending && t - last_ask >= 1.0) {
            pending = next_id++;
            asked_at = last_ask = t;
            mpv_get_property_async(c, pending, "time-pos", MPV_FORMAT_DOUBLE);
        }
        if (pending && t - asked_at > 3.0) {
            wedged = 1;
            break;
        }
        mpv_event *ev = mpv_wait_event(c, 0.05);
        if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = ev->data;
            lines++;
            for (int k = 0; k < NKEYS; k++) {
                if (strstr(m->text, keys[k])) {
                    if (!count[k]++)
                        first[k] = now() - t0;
                    if (count[k] <= 2)
                        printf("  %6.3f [%s/%s] %s", now() - t0, m->prefix, m->level, m->text);
                }
            }
        } else if (ev->event_id == MPV_EVENT_GET_PROPERTY_REPLY && ev->reply_userdata == pending) {
            double w = now() - asked_at;
            if (w > max_wait)
                max_wait = w;
            mpv_event_property *p = ev->data;
            char val[32] = "unavailable";
            if (ev->error >= 0 && p->format == MPV_FORMAT_DOUBLE)
                snprintf(val, sizeof val, "%.2f", *(double *)p->data);
            printf("  %6.3f time-pos %s (answered in %.3f s)\n", now() - t0, val, w);
            answered++;
            pending = 0;
        } else if (ev->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *e = ev->data;
            snprintf(end, 64, "reason=%d error=%s", e->reason, mpv_error_string(e->error));
            printf("  %6.3f END_FILE %s\n", now() - t0, end);
        }
    }
    printf("LINES %ld log lines in %.1f s\n", lines, now() - t0);
    for (int k = 0; k < NKEYS; k++)
        printf("COUNT %7ld  %s%s\n", count[k], keys[k], count[k] ? "" : "  (never)");
    if (wedged) {
        printf("RESULT wedged: time-pos request %llu unanswered for %.1f s (%d answered before)\n",
               (unsigned long long)pending, now() - asked_at, answered);
        fflush(stdout);
        _exit(3);
    }
    printf("RESULT responsive: %d time-pos requests answered, slowest %.3f s; %s\n",
           answered, max_wait, end[0] ? "file ended" : "still playing");
    mpv_terminate_destroy(c);
    return 0;
}

#ifdef __ANDROID__
JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *r) { mpv_lavc_set_java_vm(vm); return JNI_VERSION_1_6; }

JNIEXPORT jint JNICALL Java_RotateProbe_run(JNIEnv *env, jclass cls, jobject surface, jobjectArray args)
{
    jobject gref = (*env)->NewGlobalRef(env, surface);
    char ref[32];
    snprintf(ref, sizeof ref, "%lld", (long long)(intptr_t)gref);
    int n = (*env)->GetArrayLength(env, args);
    const char *s[64];
    for (int i = 0; i < n && i < 64; i++)
        s[i] = (*env)->GetStringUTFChars(env, (*env)->GetObjectArrayElement(env, args, i), NULL);
    // RotateProbe passes <file> first; the seconds come as "secs=<n>"
    double secs = 12;
    const char *argv[64];
    int argc = 0;
    argv[argc++] = "";
    argv[argc++] = s[0];
    for (int i = 1; i < n && i < 62; i++) {
        if (!strncmp(s[i], "secs=", 5))
            secs = atof(s[i] + 5);
        else
            argv[argc++] = s[i];
    }
    char sb[32];
    snprintf(sb, sizeof sb, "%f", secs);
    argv[0] = sb;
    return probe(argc, argv, ref);
}
#else
int main(int argc, const char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: fallprobe <seconds> <file> [opt=value ...]\n");
        return 2;
    }
    return probe(argc - 1, argv + 1, NULL);
}
#endif
