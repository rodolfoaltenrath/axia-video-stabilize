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
    DialogFailed,
    InvalidPathEncoding,
} || std.mem.Allocator.Error;

pub fn selectVideo(
    allocator: std.mem.Allocator,
    window_handle: *anyopaque,
) FileDialogError!?[]u8 {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;

    var path_buffer: [32768]windows.WCHAR = [_]windows.WCHAR{0} ** 32768;
    const filter = std.unicode.utf8ToUtf16LeStringLiteral(
        "Vídeos compatíveis\x00*.mp4;*.mov;*.mkv;*.avi;*.webm;*.m4v;*.mts;*.m2ts\x00",
    );
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Importar vídeo");

    var dialog: windows.OPENFILENAMEW = std.mem.zeroes(windows.OPENFILENAMEW);
    dialog.lStructSize = @sizeOf(windows.OPENFILENAMEW);
    dialog.hwndOwner = @ptrCast(@alignCast(window_handle));
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
