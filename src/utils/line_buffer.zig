const std = @import("std");

/// Bounded accumulator for newline-delimited output from background tools.
/// Oversized lines are discarded without growing memory or blocking readers.
pub fn LineBuffer(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        length: usize = 0,
        discarding_oversized_line: bool = false,

        const Self = @This();

        pub fn writable(self: *Self) []u8 {
            return self.bytes[self.length..];
        }

        pub fn commit(self: *Self, count: usize) void {
            std.debug.assert(count <= capacity - self.length);
            self.length += count;
            if (self.length == capacity and
                std.mem.indexOfScalar(u8, self.bytes[0..self.length], '\n') == null)
            {
                self.length = 0;
                self.discarding_oversized_line = true;
            }
        }

        pub fn peekLine(self: *Self) ?[]const u8 {
            const newline = std.mem.indexOfScalar(u8, self.bytes[0..self.length], '\n') orelse
                return null;
            if (self.discarding_oversized_line) return &.{};
            return std.mem.trimEnd(u8, self.bytes[0..newline], "\r");
        }

        pub fn discardLine(self: *Self) void {
            const newline = std.mem.indexOfScalar(u8, self.bytes[0..self.length], '\n') orelse
                return;
            const consumed = newline + 1;
            std.mem.copyForwards(u8, self.bytes[0 .. self.length - consumed], self.bytes[consumed..self.length]);
            self.length -= consumed;
            self.discarding_oversized_line = false;
        }
    };
}

test "line buffer joins chunks and strips CRLF" {
    var buffer: LineBuffer(32) = .{};
    @memcpy(buffer.writable()[0..5], "frame");
    buffer.commit(5);
    try std.testing.expect(buffer.peekLine() == null);
    @memcpy(buffer.writable()[0..4], "=1\r\n");
    buffer.commit(4);
    try std.testing.expectEqualStrings("frame=1", buffer.peekLine().?);
    buffer.discardLine();
    try std.testing.expectEqual(@as(usize, 0), buffer.length);
}

test "line buffer recovers after an oversized line" {
    var buffer: LineBuffer(8) = .{};
    @memset(buffer.writable(), 'x');
    buffer.commit(8);
    try std.testing.expect(buffer.discarding_oversized_line);
    @memcpy(buffer.writable()[0..5], "x\nok\n");
    buffer.commit(5);
    try std.testing.expectEqualStrings("", buffer.peekLine().?);
    buffer.discardLine();
    try std.testing.expectEqualStrings("ok", buffer.peekLine().?);
}
