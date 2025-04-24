const std = @import("std");
const VM = @import("VM.zig");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);
    if (args.len < 2) return error.no_file_given;

    const image_file = try std.fs.cwd().openFile(args[1], .{});
    defer image_file.close();

    const image = try image_file.readToEndAllocOptions(
        arena,
        VM.max_ram_size,
        null,
        @alignOf(i32),
        null,
    );
    var vm: VM = .init(std.mem.bytesAsSlice(i32, image));
    try vm.run();
}
