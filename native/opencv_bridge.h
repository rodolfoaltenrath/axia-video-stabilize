#ifndef AXIA_OPENCV_BRIDGE_H
#define AXIA_OPENCV_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AxiaPoint2f {
    float x;
    float y;
} AxiaPoint2f;

typedef struct AxiaShiTomasiOptions {
    uint32_t max_corners;
    double quality_level;
    double min_distance;
    int32_t block_size;
} AxiaShiTomasiOptions;

enum {
    AXIA_CV_OK = 0,
    AXIA_CV_INVALID_ARGUMENT = 1,
    AXIA_CV_OUTPUT_TOO_SMALL = 2,
    AXIA_CV_EXCEPTION = 3
};

int32_t axia_cv_shi_tomasi_gray8(
    const uint8_t *pixels,
    int32_t width,
    int32_t height,
    size_t stride,
    const AxiaShiTomasiOptions *options,
    AxiaPoint2f *output,
    size_t output_capacity,
    size_t *output_count);

const char *axia_cv_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
