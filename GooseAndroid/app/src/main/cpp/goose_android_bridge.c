#include <jni.h>
#include <dlfcn.h>
#include <stddef.h>

#include "goose_core_bridge.h"

typedef char *(*goose_handle_json_fn)(const char *request_json);
typedef char *(*goose_version_json_fn)(void);
typedef void (*goose_free_string_fn)(char *value);

static void *goose_core_handle = NULL;
static goose_handle_json_fn resolved_handle_json = NULL;
static goose_version_json_fn resolved_version_json = NULL;
static goose_free_string_fn resolved_free_string = NULL;

static int ensure_goose_core_loaded(void) {
    if (goose_core_handle != NULL
        && resolved_handle_json != NULL
        && resolved_version_json != NULL
        && resolved_free_string != NULL) {
        return 1;
    }

    goose_core_handle = dlopen("libgoose_core.so", RTLD_NOW | RTLD_LOCAL);
    if (goose_core_handle == NULL) {
        return 0;
    }

    resolved_handle_json = (goose_handle_json_fn)dlsym(goose_core_handle, "goose_bridge_handle_json");
    resolved_version_json = (goose_version_json_fn)dlsym(goose_core_handle, "goose_core_version_json");
    resolved_free_string = (goose_free_string_fn)dlsym(goose_core_handle, "goose_bridge_free_string");

    return resolved_handle_json != NULL
        && resolved_version_json != NULL
        && resolved_free_string != NULL;
}

JNIEXPORT jstring JNICALL
Java_com_goose_android_GooseRustBridge_nativeHandleJson(
    JNIEnv *env,
    jclass clazz,
    jstring request_json
) {
    (void)clazz;
    if (!ensure_goose_core_loaded()) {
        return (*env)->NewStringUTF(env, "{\"schema\":\"goose.bridge.response.v1\",\"request_id\":\"unknown\",\"ok\":false,\"error\":{\"code\":\"goose_core_load_failed\",\"message\":\"libgoose_core.so could not be loaded\"}}");
    }
    if (request_json == NULL) {
        return (*env)->NewStringUTF(env, "");
    }

    const char *request = (*env)->GetStringUTFChars(env, request_json, NULL);
    if (request == NULL) {
        return (*env)->NewStringUTF(env, "");
    }

    char *response = resolved_handle_json(request);
    (*env)->ReleaseStringUTFChars(env, request_json, request);

    if (response == NULL) {
        return (*env)->NewStringUTF(env, "");
    }

    jstring result = (*env)->NewStringUTF(env, response);
    resolved_free_string(response);
    return result;
}

JNIEXPORT jstring JNICALL
Java_com_goose_android_GooseRustBridge_nativeVersionJson(
    JNIEnv *env,
    jclass clazz
) {
    (void)clazz;
    if (!ensure_goose_core_loaded()) {
        return (*env)->NewStringUTF(env, "{}");
    }

    char *response = resolved_version_json();
    if (response == NULL) {
        return (*env)->NewStringUTF(env, "");
    }

    jstring result = (*env)->NewStringUTF(env, response);
    resolved_free_string(response);
    return result;
}
