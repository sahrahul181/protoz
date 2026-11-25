const std = @import("std");

pub const Diagnostic = struct {
    file: []const u8 = "<input>",
    line: usize = 0,
    col: usize = 0,
    message: []const u8 = "",

    pub fn format(self: Diagnostic, w: *std.Io.Writer) !void {
        if (self.line > 0) {
            try w.print("{s}:{d}:{d}: error: {s}\n", .{ self.file, self.line, self.col, self.message });
        } else {
            try w.print("{s}: error: {s}\n", .{ self.file, self.message });
        }
    }
};
