// JNI side of RotateProbe: creates an mpv instance with the given options
// ("@0" becomes the JNI global ref of the Surface), loads <url>, and after
// FILE_LOADED runs the actions:
//   +wait=<s>            drain events for <s> seconds
//   +set=<name>=<value>  mpv_set_property_string ("@0" as above)
//   +get=<name>          print a property
//   +mark=<layout>       "MARK <layout> at <t>": judge.py expects the last
//                        frame before it to have that layout
// Prints mpv's warnings, errors and fatal messages, and every message about
// rotation (the autorotate filter's "Inserting rotation filter." is info).
// rc: 0 ok, 1 end-file error, 2 init failed, 3 not loaded
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mpv/client.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *r) { mpv_lavc_set_java_vm(vm); return JNI_VERSION_1_6; }

static int ended, end_error;
static void on_event(mpv_event *ev)
{
    if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
        mpv_event_log_message *m = ev->data;
        if (m->log_level <= MPV_LOG_LEVEL_WARN || strstr(m->text, "otat") || strstr(m->prefix, "rotate"))
            printf("  %.3f [%s/%s] %s", now(), m->prefix, m->level, m->text);
    } else if (ev->event_id == MPV_EVENT_END_FILE) {
        mpv_event_end_file *e = ev->data;
        printf("END_FILE at %.3f reason=%d error=%s\n", now(), e->reason, mpv_error_string(e->error));
        ended = 1;
        if (e->reason == MPV_END_FILE_REASON_ERROR)
            end_error = 1;
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

JNIEXPORT jint JNICALL Java_RotateProbe_run(JNIEnv *env, jclass cls, jobject surface, jobjectArray args)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    jobject gref = (*env)->NewGlobalRef(env, surface);
    char ref[32];
    snprintf(ref, sizeof ref, "%lld", (long long)(intptr_t)gref);
    int n = (*env)->GetArrayLength(env, args);
    const char *s[64];
    jstring js[64];
    for (int i = 0; i < n && i < 64; i++) {
        js[i] = (*env)->GetObjectArrayElement(env, args, i);
        s[i] = (*env)->GetStringUTFChars(env, js[i], NULL);
    }
    const char *url = s[0];
    mpv_handle *c = mpv_create();
    mpv_set_option_string(c, "config", "no");
    mpv_set_option_string(c, "keep-open", "yes");
    for (int i = 1; i < n; i++) {
        if (s[i][0] == '+')
            continue;
        char k[256], v[512];
        const char *eq = strchr(s[i], '=');
        snprintf(k, sizeof k, "%.*s", (int)(eq - s[i]), s[i]);
        snprintf(v, sizeof v, "%s", strcmp(eq + 1, "@0") ? eq + 1 : ref);
        int r = mpv_set_option_string(c, k, v);
        printf("opt %s=%s -> %s\n", k, v, mpv_error_string(r));
    }
    mpv_request_log_messages(c, "info");
    if (mpv_initialize(c) < 0) {
        printf("RESULT init-failed\n");
        return 2;
    }
    show(c, "mpv-version");
    const char *cmd[] = {"loadfile", url, NULL};
    mpv_command(c, cmd);
    double t0 = now();
    int loaded = 0;
    while (!loaded && !ended && now() - t0 < 20) {
        mpv_event *ev = mpv_wait_event(c, 0.05);
        if (ev->event_id == MPV_EVENT_FILE_LOADED) {
            loaded = 1;
            printf("FILE_LOADED at %.3f\n", now());
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
            int r = mpv_set_property_string(c, k, strcmp(eq + 1, "@0") ? eq + 1 : ref);
            if (r < 0)
                printf("  set %s -> %s\n", k, mpv_error_string(r));
        } else if (!strncmp(a, "get=", 4)) {
            show(c, a + 4);
        } else if (!strncmp(a, "mark=", 5)) {
            printf("MARK %s at %.3f\n", a + 5, now());
        }
    }
    drain(c, 0.2);
    if (end_error)
        rc = 1;
    printf("RESULT rc=%d\n", rc);
    mpv_terminate_destroy(c);
    (*env)->DeleteGlobalRef(env, gref);
    for (int i = 0; i < n && i < 64; i++)
        (*env)->ReleaseStringUTFChars(env, js[i], s[i]);
    return rc;
}
