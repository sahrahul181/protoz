const std = @import("std");
const plugin = @import("plugin.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var in_buf: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const req_bytes = try stdin_reader.interface.allocRemaining(arena, .limited(64 << 20));

    const resp_bytes = try plugin.processRequest(arena, req_bytes);

    var out_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    try stdout_writer.interface.writeAll(resp_bytes);
    try stdout_writer.interface.flush();
}
