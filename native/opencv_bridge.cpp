#include "opencv_bridge.h"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cstdio>
#include <exception>

namespace {

thread_local char last_error[512] = {};

void clear_error() {
    last_error[0] = '\0';
}

void set_error(const char *message) {
    std::snprintf(last_error, sizeof(last_error), "%s", message);
}

}  // namespace

extern "C" int32_t axia_cv_shi_tomasi_gray8(
    const uint8_t *pixels,
    int32_t width,
    int32_t height,
    size_t stride,
    const AxiaShiTomasiOptions *options,
    AxiaPoint2f *output,
    size_t output_capacity,
    size_t *output_count) {
    clear_error();

    if (output_count == nullptr) {
        set_error("output_count is required");
        return AXIA_CV_INVALID_ARGUMENT;
    }
    *output_count = 0;

    if (pixels == nullptr || options == nullptr || output == nullptr ||
        width <= 0 || height <= 0 || stride < static_cast<size_t>(width) ||
        options->max_corners == 0 || options->quality_level <= 0.0 ||
        options->quality_level > 1.0 || options->min_distance < 0.0 ||
        options->block_size < 3 || options->block_size % 2 == 0) {
        set_error("invalid Shi-Tomasi arguments");
        return AXIA_CV_INVALID_ARGUMENT;
    }
    if (output_capacity < options->max_corners) {
        set_error("output capacity is smaller than max_corners");
        return AXIA_CV_OUTPUT_TOO_SMALL;
    }

    try {
        cv::Mat image(
            height,
            width,
            CV_8UC1,
            const_cast<uint8_t *>(pixels),
            stride);
        cv::Mat corners;
        cv::goodFeaturesToTrack(
            image,
            corners,
            static_cast<int>(options->max_corners),
            options->quality_level,
            options->min_distance,
            cv::noArray(),
            options->block_size,
            false,
            0.04);

        const size_t count = std::min(corners.total(), output_capacity);
        for (size_t index = 0; index < count; ++index) {
            const cv::Point2f point = corners.at<cv::Point2f>(
                static_cast<int>(index));
            output[index] = {point.x, point.y};
        }
        *output_count = count;
        return AXIA_CV_OK;
    } catch (const cv::Exception &exception) {
        set_error(exception.what());
    } catch (const std::exception &exception) {
        set_error(exception.what());
    } catch (...) {
        set_error("unknown OpenCV exception");
    }

    return AXIA_CV_EXCEPTION;
}

extern "C" const char *axia_cv_last_error(void) {
    return last_error;
}
