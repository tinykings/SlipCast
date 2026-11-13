#include "OverlapRuntime.h"
#include <onnxruntime/onnxruntime_c_api.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

struct SCOverlapRuntime {
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory;
};

static int check(SCOverlapRuntime *r, OrtStatus *status, char *error, size_t capacity) {
    if (!status) return 1;
    if (error && capacity) snprintf(error, capacity, "%s", r->api->GetErrorMessage(status));
    r->api->ReleaseStatus(status);
    return 0;
}

void SCOverlapDestroy(SCOverlapRuntime *r) {
    if (!r) return;
    if (r->memory) r->api->ReleaseMemoryInfo(r->memory);
    if (r->session) r->api->ReleaseSession(r->session);
    if (r->env) r->api->ReleaseEnv(r->env);
    free(r);
}

SCOverlapRuntime *SCOverlapCreate(const char *path, char *error, size_t capacity) {
    SCOverlapRuntime *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!r->api) { free(r); return NULL; }
    OrtSessionOptions *options = NULL;
    if (!check(r, r->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "SlipCastOverlap", &r->env), error, capacity) ||
        !check(r, r->api->CreateSessionOptions(&options), error, capacity)) goto fail;
    if (!check(r, r->api->SetIntraOpNumThreads(options, 2), error, capacity) ||
        !check(r, r->api->SetInterOpNumThreads(options, 1), error, capacity) ||
        !check(r, r->api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), error, capacity) ||
        !check(r, r->api->CreateSession(r->env, path, options, &r->session), error, capacity) ||
        !check(r, r->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &r->memory), error, capacity)) goto fail;
    r->api->ReleaseSessionOptions(options);
    return r;
fail:
    if (options) r->api->ReleaseSessionOptions(options);
    SCOverlapDestroy(r);
    return NULL;
}

int SCOverlapRun(SCOverlapRuntime *r, const float *samples, size_t count,
                 float *overlap, size_t capacity, size_t *frames, char *error, size_t errorCapacity) {
    if (!r || !samples || count != 160000 || !overlap || !frames) return 0;
    OrtValue *input = NULL, *output = NULL;
    OrtTensorTypeAndShapeInfo *shapeInfo = NULL;
    int result = 0;
    const int64_t shape[] = {1, 1, 160000};
    const char *inputs[] = {"x"}, *outputs[] = {"y"};
    if (!check(r, r->api->CreateTensorWithDataAsOrtValue(r->memory, (void *)samples,
            count * sizeof(float), shape, 3, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input), error, errorCapacity)) goto done;
    const OrtValue *inputValues[] = {input};
    if (!check(r, r->api->Run(r->session, NULL, inputs, inputValues, 1, outputs, 1, &output), error, errorCapacity) ||
        !check(r, r->api->GetTensorTypeAndShape(output, &shapeInfo), error, errorCapacity)) goto done;
    size_t dimensions = 0;
    if (!check(r, r->api->GetDimensionsCount(shapeInfo, &dimensions), error, errorCapacity) || dimensions != 3) goto done;
    int64_t dims[3];
    if (!check(r, r->api->GetDimensions(shapeInfo, dims, 3), error, errorCapacity) ||
        dims[0] != 1 || dims[1] <= 0 || dims[1] > (int64_t)capacity || dims[2] != 7) goto done;
    ONNXTensorElementDataType type;
    if (!check(r, r->api->GetTensorElementType(shapeInfo, &type), error, errorCapacity) ||
        type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) goto done;
    float *scores = NULL;
    if (!check(r, r->api->GetTensorMutableData(output, (void **)&scores), error, errorCapacity)) goto done;
    *frames = (size_t)dims[1];
    for (size_t i = 0; i < *frames; ++i) {
        // Pinned pyannote powerset: silence, three single speakers, then three speaker pairs.
        float p = expf(scores[i * 7 + 4]) + expf(scores[i * 7 + 5]) + expf(scores[i * 7 + 6]);
        if (!isfinite(p) || p < 0 || p > 1.001f) goto done;
        overlap[i] = fminf(1, p);
    }
    result = 1;
done:
    if (!result && error && errorCapacity && !error[0]) snprintf(error, errorCapacity, "Invalid overlap model output");
    if (shapeInfo) r->api->ReleaseTensorTypeAndShapeInfo(shapeInfo);
    if (output) r->api->ReleaseValue(output);
    if (input) r->api->ReleaseValue(input);
    return result;
}
