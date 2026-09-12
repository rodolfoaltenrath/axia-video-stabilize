const std = @import("std");

pub const capacity: usize = 4;

pub const Timing = struct {
    pts_seconds: f64 = 0,
    duration_seconds: f64 = 0,
    generation: u64 = 0,
};

/// Chooses the newest frame due at the playback clock. The caller removes the
/// returned number of entries and presents the last one, counting earlier
/// entries as dropped frames.
pub fn dueCount(
    timings: *const [capacity]Timing,
    read_index: usize,
    count: usize,
    playback_clock_seconds: f64,
    has_displayed_frame: bool,
    playing: bool,
) usize {
    if (count == 0) return 0;
    if (!has_displayed_frame) return 1;
    if (!playing) return 0;

    var due: usize = 0;
    while (due < count) : (due += 1) {
        const index = (read_index + due) % capacity;
        const timing = timings[index];
        const tolerance = timing.duration_seconds * 0.25;
        if (timing.pts_seconds > playback_clock_seconds + tolerance) break;
    }
    return due;
}

pub fn stalePrefixCount(
    timings: *const [capacity]Timing,
    read_index: usize,
    count: usize,
    generation: u64,
) usize {
    var stale: usize = 0;
    while (stale < count) : (stale += 1) {
        const index = (read_index + stale) % capacity;
        if (timings[index].generation == generation) break;
    }
    return stale;
}

test "queue presents first poster even while paused" {
    var timings = [_]Timing{.{}} ** capacity;
    timings[0] = .{ .pts_seconds = 4, .duration_seconds = 1.0 / 24.0 };
    try std.testing.expectEqual(
        @as(usize, 1),
        dueCount(&timings, 0, 1, 4, false, false),
    );
}

test "queue selects newest due frame after a delayed UI tick" {
    const frame_duration = 1.0 / 24.0;
    var timings = [_]Timing{.{}} ** capacity;
    for (&timings, 0..) |*timing, index| {
        timing.* = .{
            .pts_seconds = @as(f64, @floatFromInt(index)) * frame_duration,
            .duration_seconds = frame_duration,
        };
    }
    try std.testing.expectEqual(
        @as(usize, 3),
        dueCount(&timings, 0, capacity, 0.09, true, true),
    );
}

test "queue keeps future frames buffered" {
    var timings = [_]Timing{.{}} ** capacity;
    timings[2] = .{ .pts_seconds = 2.0, .duration_seconds = 1.0 / 30.0 };
    timings[3] = .{ .pts_seconds = 2.04, .duration_seconds = 1.0 / 30.0 };
    try std.testing.expectEqual(
        @as(usize, 1),
        dueCount(&timings, 2, 2, 2.01, true, true),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        dueCount(&timings, 2, 2, 2.01, true, false),
    );
}

test "queue rejects stale generations across ring wraparound" {
    var timings = [_]Timing{.{}} ** capacity;
    timings[3].generation = 4;
    timings[0].generation = 4;
    timings[1].generation = 5;
    try std.testing.expectEqual(
        @as(usize, 2),
        stalePrefixCount(&timings, 3, 3, 5),
    );
}
