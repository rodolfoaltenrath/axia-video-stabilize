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

typedef struct AxiaOpticalFlowOptions {
    int32_t window_size;
    int32_t max_pyramid_level;
    int32_t max_iterations;
    double epsilon;
    double min_eigen_threshold;
} AxiaOpticalFlowOptions;

typedef struct AxiaRansacOptions {
    double reprojection_threshold;
    uint32_t max_iterations;
    double confidence;
    uint32_t refine_iterations;
} AxiaRansacOptions;

typedef struct AxiaSimilarityTransform {
    double x;
    double y;
    double angle;
    double scale;
} AxiaSimilarityTransform;

enum {
    AXIA_CV_OK = 0,
    AXIA_CV_INVALID_ARGUMENT = 1,
    AXIA_CV_OUTPUT_TOO_SMALL = 2,
    AXIA_CV_EXCEPTION = 3,
    AXIA_CV_ESTIMATION_FAILED = 4
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

int32_t axia_cv_track_lk_forward_backward_gray8(
    const uint8_t *previous_pixels,
    size_t previous_stride,
    const uint8_t *current_pixels,
    size_t current_stride,
    int32_t width,
    int32_t height,
    const AxiaPoint2f *previous_points,
    size_t point_count,
    const AxiaOpticalFlowOptions *options,
    AxiaPoint2f *current_points,
    AxiaPoint2f *backward_points,
    float *forward_errors,
    uint8_t *status,
    size_t output_capacity);

int32_t axia_cv_estimate_similarity_ransac(
    const AxiaPoint2f *previous_points,
    const AxiaPoint2f *current_points,
    size_t point_count,
    const AxiaRansacOptions *options,
    AxiaSimilarityTransform *transform,
    uint8_t *inlier_mask,
    size_t inlier_capacity,
    size_t *inlier_count);

const char *axia_cv_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
