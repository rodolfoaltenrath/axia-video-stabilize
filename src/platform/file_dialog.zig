const std = @import("std");
const builtin = @import("builtin");

const windows = if (builtin.os.tag == .windows)
    @cImport({
        @cInclude("windows.h");
        @cInclude("commdlg.h");
    })
else
    struct {};

pub const FileDialogError = error{
    UnsupportedPlatform,
    BackendUnavailable,
    DialogFailed,
    InvalidPathEncoding,
} || std.mem.Allocator.Error;

pub const Selection = union(enum) {
    selected: []u8,
    cancelled,
    failed: FileDialogError,
};

pub const AsyncSelector = struct {
    const Status = enum {
        idle,
        running,
        selected,
        cancelled,
        failed,
    };

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    status: Status = .idle,
    selected_path: ?[]u8 = null,
    failure: ?FileDialogError = null,

    pub fn init(allocator: std.mem.Allocator) AsyncSelector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AsyncSelector) void {
        if (self.thread) |thread| thread.join();
        if (self.selected_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn start(self: *AsyncSelector) std.Thread.SpawnError!bool {
        return self.startWith(selectVideo);
    }

    pub fn poll(self: *AsyncSelector) ?Selection {
        self.mutex.lock();
        const outcome: Selection = switch (self.status) {
            .idle, .running => {
                self.mutex.unlock();
                return null;
            },
            .selected => .{ .selected = self.selected_path.? },
            .cancelled => .cancelled,
            .failed => .{ .failed = self.failure.? },
        };
        const finished_thread = self.thread.?;
        self.thread = null;
        self.selected_path = null;
        self.failure = null;
        self.status = .idle;
        self.mutex.unlock();

        // The worker publishes its outcome immediately before returning.
        finished_thread.join();
        return outcome;
    }

    fn startWith(
        self: *AsyncSelector,
        selector: *const fn (std.mem.Allocator) FileDialogError!?[]u8,
    ) std.Thread.SpawnError!bool {
        self.mutex.lock();
        if (self.status != .idle) {
            self.mutex.unlock();
            return false;
        }
        self.status = .running;
        self.mutex.unlock();

        self.thread = std.Thread.spawn(
            .{},
            selectionWorker,
            .{ self, selector },
        ) catch |err| {
            self.mutex.lock();
            self.status = .idle;
            self.mutex.unlock();
            return err;
        };
        return true;
    }

    fn selectionWorker(
        self: *AsyncSelector,
        selector: *const fn (std.mem.Allocator) FileDialogError!?[]u8,
    ) void {
        const result = selector(self.allocator) catch |err| {
            self.mutex.lock();
            self.failure = err;
            self.status = .failed;
            self.mutex.unlock();
            return;
        };

        self.mutex.lock();
        if (result) |path| {
            self.selected_path = path;
            self.status = .selected;
        } else {
            self.status = .cancelled;
        }
        self.mutex.unlock();
    }
};

pub fn selectVideo(allocator: std.mem.Allocator) FileDialogError!?[]u8 {
    return switch (builtin.os.tag) {
        .windows => selectVideoWindows(allocator),
        .linux => selectVideoLinux(allocator),
        else => error.UnsupportedPlatform,
    };
}

fn selectVideoWindows(allocator: std.mem.Allocator) FileDialogError!?[]u8 {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;

    var path_buffer: [32768]windows.WCHAR = [_]windows.WCHAR{0} ** 32768;
    const filter = std.unicode.utf8ToUtf16LeStringLiteral(
        "Vídeos compatíveis\x00*.mp4;*.mov;*.mkv;*.avi;*.webm;*.m4v;*.mts;*.m2ts\x00",
    );
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Importar vídeo");

    // Keep hwndOwner null. Windows handles are opaque values and Zig's C
    // binding can reject a valid Raylib HWND when it enforces pointee alignment.
    var dialog: windows.OPENFILENAMEW = std.mem.zeroes(windows.OPENFILENAMEW);
    dialog.lStructSize = @sizeOf(windows.OPENFILENAMEW);
    dialog.lpstrFilter = filter;
    dialog.lpstrFile = &path_buffer;
    dialog.nMaxFile = path_buffer.len;
    dialog.lpstrTitle = title;
    dialog.Flags = windows.OFN_EXPLORER |
        windows.OFN_FILEMUSTEXIST |
        windows.OFN_PATHMUSTEXIST |
        windows.OFN_NOCHANGEDIR;

    if (windows.GetOpenFileNameW(&dialog) == 0) {
        if (windows.CommDlgExtendedError() == 0) return null;
        return error.DialogFailed;
    }

    const path_len = std.mem.indexOfScalar(u16, &path_buffer, 0) orelse
        return error.InvalidPathEncoding;
    return std.unicode.utf16LeToUtf8Alloc(allocator, path_buffer[0..path_len]) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPathEncoding,
    };
}

const video_filter = "Vídeos compatíveis | " ++
    "*.mp4 *.MP4 *.mov *.MOV *.mkv *.MKV *.avi *.AVI " ++
    "*.webm *.WEBM *.m4v *.M4V *.mts *.MTS *.m2ts *.M2TS";
const kdialog_video_filter =
    "*.mp4 *.MP4 *.mov *.MOV *.mkv *.MKV *.avi *.AVI " ++
    "*.webm *.WEBM *.m4v *.M4V *.mts *.MTS *.m2ts *.M2TS" ++
    " | Vídeos compatíveis";

fn selectVideoLinux(allocator: std.mem.Allocator) FileDialogError!?[]u8 {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;

    const backends = [_][]const []const u8{
        &.{
            "zenity",
            "--file-selection",
            "--title=Importar vídeo",
            "--file-filter=" ++ video_filter,
            "--file-filter=Todos os arquivos | *",
        },
        &.{
            "kdialog",
            "--title",
            "Importar vídeo",
            "--getopenfilename",
            "",
            kdialog_video_filter,
        },
    };
    for (backends) |arguments| {
        const result = runDialog(allocator, arguments) catch |err| switch (err) {
            error.BackendUnavailable => continue,
            else => return err,
        };
        return result;
    }
    return error.BackendUnavailable;
}

fn runDialog(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) FileDialogError!?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .max_output_bytes = 64 * 1024,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.BackendUnavailable,
        else => return error.DialogFailed,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| switch (code) {
            0 => @as(?[]u8, try parseSelectedPath(allocator, result.stdout)),
            1 => null,
            else => error.DialogFailed,
        },
        else => error.DialogFailed,
    };
}

fn parseSelectedPath(
    allocator: std.mem.Allocator,
    output: []const u8,
) FileDialogError![]u8 {
    const path = std.mem.trimRight(u8, output, "\r\n");
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidPathEncoding;
    }
    return allocator.dupe(u8, path);
}

test "Linux dialog output trims only its line terminator" {
    const selected = try parseSelectedPath(
        std.testing.allocator,
        "/home/user/Vídeos/meu vídeo.mp4\r\n",
    );
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings(
        "/home/user/Vídeos/meu vídeo.mp4",
        selected,
    );
}

test "Linux dialog rejects an empty successful selection" {
    try std.testing.expectError(
        error.InvalidPathEncoding,
        parseSelectedPath(std.testing.allocator, "\n"),
    );
}

test "Linux dialog runner handles selection and cancellation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const selected = (try runDialog(
        std.testing.allocator,
        &.{ "sh", "-c", "printf '/tmp/meu video.mp4\\n'" },
    )) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("/tmp/meu video.mp4", selected);

    const cancelled = try runDialog(
        std.testing.allocator,
        &.{ "sh", "-c", "exit 1" },
    );
    try std.testing.expect(cancelled == null);
}

fn testAsyncSelection(allocator: std.mem.Allocator) FileDialogError!?[]u8 {
    const path = try allocator.dupe(u8, "/tmp/selecionado.mp4");
    return @as(?[]u8, path);
}

test "asynchronous selector publishes ownership on the caller thread" {
    var selector = AsyncSelector.init(std.testing.allocator);
    defer selector.deinit();
    try std.testing.expect(try selector.startWith(testAsyncSelection));
    try std.testing.expect(!(try selector.startWith(testAsyncSelection)));

    var attempts: usize = 0;
    var completed: ?Selection = null;
    while (completed == null and attempts < 10_000) : (attempts += 1) {
        completed = selector.poll();
        if (completed != null) break;
        std.Thread.yield() catch {};
    }
    const outcome = completed orelse return error.TestUnexpectedResult;
    switch (outcome) {
        .selected => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expectEqualStrings("/tmp/selecionado.mp4", path);
        },
        else => return error.TestUnexpectedResult,
    }
}
