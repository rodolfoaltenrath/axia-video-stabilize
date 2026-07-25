const std = @import("std");

pub const ValidationError = error{
    InvalidTimeBase,
    InvalidFrameDuration,
    InvalidTransform,
    InvalidConfidence,
    InvalidPointCount,
    InvalidResidual,
    UnexpectedFrameIndex,
    NonMonotonicPts,
    FirstFrameMustBeReference,
    InvalidSceneTransition,
    SceneCutMustBeReference,
    FrameCountMismatch,
};

pub const Rational = struct {
    numerator: i32,
    denominator: i32,

    pub fn validate(self: Rational) ValidationError!void {
        if (self.numerator <= 0 or self.denominator <= 0) {
            return error.InvalidTimeBase;
        }
    }

    pub fn scale(self: Rational, value: i64) ValidationError!f64 {
        try self.validate();
        return @as(f64, @floatFromInt(value)) *
            @as(f64, @floatFromInt(self.numerator)) /
            @as(f64, @floatFromInt(self.denominator));
    }
};

/// Presentation timing attached to one decoded video frame.
///
/// `index` is assigned by the decoder after frame reordering. `pts` always
/// belongs to the presentation timeline, never to packet/decode order.
pub const FrameTiming = struct {
    index: u64,
    pts: i64,
    duration: ?i64 = null,
    time_base: Rational,

    pub fn validate(self: FrameTiming) ValidationError!void {
        try self.time_base.validate();
        if (self.duration) |duration| {
            if (duration <= 0) return error.InvalidFrameDuration;
        }
    }

    pub fn presentationSeconds(self: FrameTiming) ValidationError!f64 {
        return self.time_base.scale(self.pts);
    }
};

/// Global camera-motion backbone measured from frame N-1 to frame N.
///
/// The future mesh engine will store a spatial residual field in addition to
/// this transform instead of replacing it.
pub const SimilarityTransform = struct {
    x: f64 = 0,
    y: f64 = 0,
    angle: f64 = 0,
    scale: f64 = 1,

    pub fn identity() SimilarityTransform {
        return .{};
    }

    pub fn validate(self: SimilarityTransform) ValidationError!void {
        if (!std.math.isFinite(self.x) or
            !std.math.isFinite(self.y) or
            !std.math.isFinite(self.angle) or
            !std.math.isFinite(self.scale) or
            self.scale <= 0)
        {
            return error.InvalidTransform;
        }
    }

    pub fn isIdentity(self: SimilarityTransform) bool {
        return self.x == 0 and
            self.y == 0 and
            self.angle == 0 and
            self.scale == 1;
    }
};

pub const AnalysisFlags = struct {
    scene_cut: bool = false,
    low_confidence: bool = false,
    fallback: bool = false,
};

/// Compact result for one decoded frame. It deliberately owns no pixel data.
pub const AnalysisRecord = struct {
    timing: FrameTiming,
    global_motion_from_previous: SimilarityTransform = .{},
    confidence: f32 = 0,
    detected_points: u32 = 0,
    tracked_points: u32 = 0,
    inlier_points: u32 = 0,
    residual_px: f32 = 0,
    scene_id: u32 = 0,
    flags: AnalysisFlags = .{},

    pub fn reference(timing: FrameTiming, scene_id: u32) AnalysisRecord {
        return .{
            .timing = timing,
            .global_motion_from_previous = SimilarityTransform.identity(),
            .confidence = 1,
            .scene_id = scene_id,
        };
    }

    pub fn validate(self: AnalysisRecord) ValidationError!void {
        try self.timing.validate();
        try self.global_motion_from_previous.validate();
        if (!std.math.isFinite(self.confidence) or
            self.confidence < 0 or
            self.confidence > 1)
        {
            return error.InvalidConfidence;
        }
        if (self.tracked_points > self.detected_points or
            self.inlier_points > self.tracked_points)
        {
            return error.InvalidPointCount;
        }
        if (!std.math.isFinite(self.residual_px) or self.residual_px < 0) {
            return error.InvalidResidual;
        }
    }
};

/// Validates a stream of analysis records with constant memory.
///
/// This is shared by the decoder/analyzer tests and, later, by the binary
/// analysis-cache writer. A successful `finish` proves that no decoded frame
/// disappeared between pipeline stages.
pub const SequenceValidator = struct {
    count: u64 = 0,
    last_pts: ?i64 = null,
    last_scene_id: ?u32 = null,

    pub fn push(self: *SequenceValidator, record: AnalysisRecord) ValidationError!void {
        try record.validate();
        if (record.timing.index != self.count) {
            return error.UnexpectedFrameIndex;
        }

        if (self.count == 0) {
            if (!record.global_motion_from_previous.isIdentity() or
                record.scene_id != 0 or
                record.flags.scene_cut)
            {
                return error.FirstFrameMustBeReference;
            }
        } else {
            if (record.timing.pts <= self.last_pts.?) {
                return error.NonMonotonicPts;
            }

            const previous_scene = self.last_scene_id.?;
            if (record.flags.scene_cut) {
                if (record.scene_id != previous_scene + 1) {
                    return error.InvalidSceneTransition;
                }
                if (!record.global_motion_from_previous.isIdentity()) {
                    return error.SceneCutMustBeReference;
                }
            } else if (record.scene_id != previous_scene) {
                return error.InvalidSceneTransition;
            }
        }

        self.count += 1;
        self.last_pts = record.timing.pts;
        self.last_scene_id = record.scene_id;
    }

    pub fn finish(self: SequenceValidator, expected_frames: u64) ValidationError!void {
        if (self.count != expected_frames) return error.FrameCountMismatch;
    }
};
