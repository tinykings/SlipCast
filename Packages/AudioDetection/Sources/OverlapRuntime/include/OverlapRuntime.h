#ifndef SLIPCAST_OVERLAP_RUNTIME_H
#define SLIPCAST_OVERLAP_RUNTIME_H
#include <stddef.h>
typedef struct SCOverlapRuntime SCOverlapRuntime;
SCOverlapRuntime *SCOverlapCreate(const char *path, char *error, size_t errorCapacity);
void SCOverlapDestroy(SCOverlapRuntime *runtime);
int SCOverlapRun(SCOverlapRuntime *runtime, const float *samples, size_t count,
                 float *overlap, size_t capacity, size_t *frames, char *error, size_t errorCapacity);
#endif
