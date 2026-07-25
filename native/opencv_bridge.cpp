#include "opencv_bridge.h"

#include <opencv2/core.hpp>
#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <exception>
#include <vector>

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

extern "C" int32_t axia_cv_track_lk_forward_backward_gray8(
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
    size_t output_capacity) {
    clear_error();

    if (previous_pixels == nullptr || current_pixels == nullptr ||
        previous_points == nullptr || options == nullptr ||
        current_points == nullptr || backward_points == nullptr ||
        forward_errors == nullptr || status == nullptr ||
        width <= 0 || height <= 0 ||
        previous_stride < static_cast<size_t>(width) ||
        current_stride < static_cast<size_t>(width) ||
        point_count == 0 || output_capacity < point_count ||
        options->window_size < 3 || options->window_size % 2 == 0 ||
        options->max_pyramid_level < 0 || options->max_iterations <= 0 ||
        options->epsilon <= 0.0 || options->min_eigen_threshold < 0.0) {
        set_error("invalid Lucas-Kanade arguments");
        return output_capacity < point_count
            ? AXIA_CV_OUTPUT_TOO_SMALL
            : AXIA_CV_INVALID_ARGUMENT;
    }

    try {
        cv::Mat previous_image(
            height,
            width,
            CV_8UC1,
            const_cast<uint8_t *>(previous_pixels),
            previous_stride);
        cv::Mat current_image(
            height,
            width,
            CV_8UC1,
            const_cast<uint8_t *>(current_pixels),
            current_stride);

        std::vector<cv::Point2f> previous(point_count);
        std::vector<cv::Point2f> forward;
        std::vector<cv::Point2f> backward;
        std::vector<uint8_t> forward_status;
        std::vector<uint8_t> backward_status;
        std::vector<float> forward_error;
        std::vector<float> backward_error;

        for (size_t index = 0; index < point_count; ++index) {
            previous[index] = {
                previous_points[index].x,
                previous_points[index].y};
        }

        const cv::Size window(options->window_size, options->window_size);
        const cv::TermCriteria criteria(
            cv::TermCriteria::COUNT | cv::TermCriteria::EPS,
            options->max_iterations,
            options->epsilon);
        cv::calcOpticalFlowPyrLK(
            previous_image,
            current_image,
            previous,
            forward,
            forward_status,
            forward_error,
            window,
            options->max_pyramid_level,
            criteria,
            0,
            options->min_eigen_threshold);
        cv::calcOpticalFlowPyrLK(
            current_image,
            previous_image,
            forward,
            backward,
            backward_status,
            backward_error,
            window,
            options->max_pyramid_level,
            criteria,
            0,
            options->min_eigen_threshold);

        for (size_t index = 0; index < point_count; ++index) {
            current_points[index] = {forward[index].x, forward[index].y};
            backward_points[index] = {backward[index].x, backward[index].y};
            forward_errors[index] = forward_error[index];
            status[index] = static_cast<uint8_t>(
                forward_status[index] != 0 && backward_status[index] != 0);
        }
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

extern "C" int32_t axia_cv_estimate_similarity_ransac(
    const AxiaPoint2f *previous_points,
    const AxiaPoint2f *current_points,
    size_t point_count,
    const AxiaRansacOptions *options,
    AxiaSimilarityTransform *transform,
    uint8_t *inlier_mask,
    size_t inlier_capacity,
    size_t *inlier_count) {
    clear_error();

    if (inlier_count == nullptr) {
        set_error("inlier_count is required");
        return AXIA_CV_INVALID_ARGUMENT;
    }
    *inlier_count = 0;

    if (previous_points == nullptr || current_points == nullptr ||
        options == nullptr || transform == nullptr || inlier_mask == nullptr ||
        point_count < 3 || inlier_capacity < point_count ||
        options->reprojection_threshold <= 0.0 ||
        options->max_iterations == 0 ||
        options->confidence <= 0.0 || options->confidence >= 1.0) {
        set_error("invalid RANSAC arguments");
        return inlier_capacity < point_count
            ? AXIA_CV_OUTPUT_TOO_SMALL
            : AXIA_CV_INVALID_ARGUMENT;
    }

    try {
        std::vector<cv::Point2f> previous(point_count);
        std::vector<cv::Point2f> current(point_count);
        for (size_t index = 0; index < point_count; ++index) {
            previous[index] = {
                previous_points[index].x,
                previous_points[index].y};
            current[index] = {
                current_points[index].x,
                current_points[index].y};
        }

        cv::Mat inliers;
        cv::Mat affine = cv::estimateAffinePartial2D(
            previous,
            current,
            inliers,
            cv::RANSAC,
            options->reprojection_threshold,
            static_cast<size_t>(options->max_iterations),
            options->confidence,
            static_cast<size_t>(options->refine_iterations));
        if (affine.empty() || affine.rows != 2 || affine.cols != 3) {
            set_error("RANSAC could not estimate a similarity transform");
            return AXIA_CV_ESTIMATION_FAILED;
        }

        cv::Mat affine64;
        affine.convertTo(affine64, CV_64F);
        const double a = affine64.at<double>(0, 0);
        const double b = affine64.at<double>(1, 0);
        transform->x = affine64.at<double>(0, 2);
        transform->y = affine64.at<double>(1, 2);
        transform->angle = std::atan2(b, a);
        transform->scale = std::hypot(a, b);

        size_t count = 0;
        for (size_t index = 0; index < point_count; ++index) {
            const uint8_t is_inlier = inliers.at<uint8_t>(
                static_cast<int>(index));
            inlier_mask[index] = static_cast<uint8_t>(is_inlier != 0);
            count += inlier_mask[index];
        }
        *inlier_count = count;
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
