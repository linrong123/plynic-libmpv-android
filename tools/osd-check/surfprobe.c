// JNI side of SurfaceProbe: creates an mpv instance with the given options
// ("@0"/"@1" become the JNI global refs of the video / OSD surface), loads
// <url>, and after FILE_LOADED runs the actions:
//   +wait=<s>            drain events for <s> seconds
//   +set=<name>=<value>  mpv_set_property_string
//   +cmd=<a>,<b>,...     mpv_command
//   +get=<name>          print a property
// Prints mpv's warnings/errors and the lines about VO/hwdec/subtitles.
// rc: 0 ok, 1 end-file error, 2 init failed, 3 not loaded, 5 shutdown
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mpv/client.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *r) { mpv_lavc_set_java_vm(vm); return JNI_VERSION_1_6; }

static int errors, ended, end_error;
static void on_event(mpv_event *ev)
{
    if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
        mpv_event_log_message *m = ev->data;
        const char *t = m->text;
        int interesting = !strncmp(m->prefix, "vo", 2) || !strncmp(m->prefix, "vd", 2) ||
                          strstr(t, "hwdec") || strstr(t, "ediacodec") || strstr(t, "ubtitle") ||
                          !strncmp(m->prefix, "sub", 3) || !strcmp(m->prefix, "cplayer");
        if (m->log_level <= MPV_LOG_LEVEL_ERROR)
            errors++;
        if (m->log_level <= MPV_LOG_LEVEL_WARN || (interesting && m->log_level <= MPV_LOG_LEVEL_V))
            printf("  %.3f [%s/%s] %s", now(), m->prefix, m->level, t);
    } else if (ev->event_id == MPV_EVENT_END_FILE) {
        mpv_event_end_file *e = ev->data;
        printf("END_FILE at %.3f reason=%d error=%s\n", now(), e->reason, mpv_error_string(e->error));
        ended = 1;
        if (e->reason == MPV_END_FILE_REASON_ERROR)
            end_error = 1;
    } else if (ev->event_id == MPV_EVENT_VIDEO_RECONFIG) {
        printf("VIDEO_RECONFIG at %.3f\n", now());
    }
}

static void drain(mpv_handle *c, double secs)
{
    double t = now();
    do {
        mpv_event *ev = mpv_wait_event(c, 0.02);
        if (ev->event_id != MPV_EVENT_NONE)
            on_event(ev);
    } while (now() - t < secs);
}

static void show(mpv_handle *c, const char *name)
{
    char *v = mpv_get_property_string(c, name);
    printf("GET %s = %s\n", name, v ? v : "(unavailable)");
    mpv_free(v);
}

JNIEXPORT jint JNICALL Java_SurfaceProbe_run(JNIEnv *env, jclass cls, jobjectArray surfaces, jobjectArray args)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    int ns = (*env)->GetArrayLength(env, surfaces);
    char refs[2][32];
    jobject gref[2] = {0};
    for (int i = 0; i < ns && i < 2; i++) {
        gref[i] = (*env)->NewGlobalRef(env, (*env)->GetObjectArrayElement(env, surfaces, i));
        snprintf(refs[i], sizeof(refs[i]), "%lld", (long long)(intptr_t)gref[i]);
    }
    int n = (*env)->GetArrayLength(env, args);
    const char *s[64];
    jstring js[64];
    for (int i = 0; i < n && i < 64; i++) {
        js[i] = (*env)->GetObjectArrayElement(env, args, i);
        s[i] = (*env)->GetStringUTFChars(env, js[i], NULL);
    }
    const char *url = s[0];
    printf("mpv client api 0x%lx\n", mpv_client_api_version());
    mpv_handle *c = mpv_create();
    mpv_set_option_string(c, "config", "no");
    mpv_set_option_string(c, "keep-open", "yes");
    mpv_set_option_string(c, "audio-fallback-to-null", "no");
    for (int i = 1; i < n; i++) {
        if (s[i][0] == '+')
            continue;
        char k[256], v[512];
        const char *eq = strchr(s[i], '=');
        snprintf(k, sizeof k, "%.*s", (int)(eq - s[i]), s[i]);
        snprintf(v, sizeof v, "%s", eq + 1);
        if (!strcmp(v, "@0") || !strcmp(v, "@1"))
            snprintf(v, sizeof v, "%s", refs[v[1] - '0']);
        int r = mpv_set_option_string(c, k, v);
        printf("opt %s=%s -> %s\n", k, v, mpv_error_string(r));
    }
    mpv_request_log_messages(c, "v");
    if (mpv_initialize(c) < 0) {
        printf("RESULT init-failed\n");
        return 2;
    }
    show(c, "mpv-version");
    show(c, "ffmpeg-version");
    const char *cmd[] = {"loadfile", url, NULL};
    mpv_command(c, cmd);
    double t0 = now();
    int loaded = 0;
    while (!loaded && !ended && now() - t0 < 20) {
        mpv_event *ev = mpv_wait_event(c, 0.05);
        if (ev->event_id == MPV_EVENT_FILE_LOADED) {
            loaded = 1;
            printf("FILE_LOADED at %.3f after %.2f s\n", now(), now() - t0);
        } else if (ev->event_id != MPV_EVENT_NONE) {
            on_event(ev);
        }
    }
    int rc = loaded ? 0 : 3;
    for (int i = 1; loaded && i < n && !end_error; i++) {
        if (s[i][0] != '+')
            continue;
        const char *a = s[i] + 1;
        printf("ACTION %s at %.3f\n", a, now());
        if (!strncmp(a, "wait=", 5)) {
            drain(c, atof(a + 5));
        } else if (!strncmp(a, "set=", 4)) {
            char k[256];
            const char *eq = strchr(a + 4, '=');
            snprintf(k, sizeof k, "%.*s", (int)(eq - (a + 4)), a + 4);
            int r = mpv_set_property_string(c, k, eq + 1);
            if (r < 0)
                printf("  set %s -> %s\n", k, mpv_error_string(r));
        } else if (!strncmp(a, "cmd=", 4)) {
            char buf[512];
            snprintf(buf, sizeof buf, "%s", a + 4);
            const char *argv[16];
            int argc = 0;
            for (char *tok = strtok(buf, ","); tok && argc < 15; tok = strtok(NULL, ","))
                argv[argc++] = tok;
            argv[argc] = NULL;
            int r = mpv_command(c, argv);
            if (r < 0)
                printf("  cmd -> %s\n", mpv_error_string(r));
        } else if (!strncmp(a, "get=", 4)) {
            show(c, a + 4);
        }
    }
    drain(c, 0.2);
    if (end_error)
        rc = 1;
    printf("RESULT rc=%d errors=%d\n", rc, errors);
    double td = now();
    mpv_terminate_destroy(c);
    printf("terminate_destroy %.3f s\n", now() - td);
    for (int i = 0; i < 2; i++)
        if (gref[i])
            (*env)->DeleteGlobalRef(env, gref[i]);
    for (int i = 0; i < n && i < 64; i++)
        (*env)->ReleaseStringUTFChars(env, js[i], s[i]);
    return rc;
}
