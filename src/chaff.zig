const std = @import("std");
const data = @import("data.zig");
const assert = std.debug.assert;

const Chaff = @This();

allocator: std.mem.Allocator,
dialect: Dialect = lemos_dialect,

pub const Dialect = std.StaticStringMap(data.Op);
pub const Environment = std.StringHashMap(i32);
const Memory = std.ArrayList(i32);

pub const lemos_dialect = Dialect.initComptime(.{
    .{ "fetch", .pc_fetch },
    .{ "jump", .jump },
    .{ "jump-0", .jump_zero },
    .{ "jump+", .jump_plus },
    .{ "call", .call },
    .{ "ret", .ret },
    .{ "halt", .halt },
    .{ "push-a", .push_a },
    .{ "pop-a", .pop_a },
    .{ "push-r", .push_r },
    .{ "pop-r", .pop_r },
    .{ "over", .over },
    .{ "dup", .dup },
    .{ "drop", .drop },
    .{ "load-a", .load_a },
    .{ "store-a", .store_a },
    .{ "load-a-plus", .load_a_plus },
    .{ "store-a-plus", .store_a_plus },
    .{ "load-r-plus", .load_r_plus },
    .{ "store-r-plus", .store_r_plus },
    .{ "literal", .literal },
    .{ "and", .@"and" },
    .{ "not", .not },
    .{ "or", .@"or" },
    .{ "xor", .xor },
    .{ "plus", .plus },
    .{ "double", .double },
    .{ "/2", .half },
    .{ "+*", .plus_star },
    .{ "nop", .nop },
    .{ "syscall", .syscall },
    .{ "swap", .swap },
});

comptime {
    const total_opcodes = @typeInfo(data.Op).Enum.fields.len;
    const Instruction_Set = std.StaticBitSet(total_opcodes);
    var instruction_set = Instruction_Set.initEmpty();
    for (lemos_dialect.values()) |op| {
        instruction_set.set(@intFromEnum(op));
    }
    assert(instruction_set.eql(Instruction_Set.initFull()));
}

const whitespace = std.StaticStringMap(void).initComptime(
    .{ .{" "}, .{"\t"}, .{"\n"}, .{"\r"} },
);

fn free_keys_and_deinit(
    allocator: std.mem.Allocator,
    map: *Environment,
) void {
    var keys = map.keyIterator();
    while (keys.next()) |key| {
        allocator.free(key.*);
    }
    map.deinit();
}

fn any_whitespace(subject: []const u8) []const u8 {
    return for (subject, 0..) |character, index| {
        if (!whitespace.has(character))
            break subject[index..];
    } else subject;
}

const With_Capture = struct {
    capture: []const u8,
    remainder: []const u8,
};

fn one_word(subject: []const u8) ?With_Capture {
    const no_leading_whitespace = any_whitespace(subject);
    return if (no_leading_whitespace.len == 0)
        null
    else for (no_leading_whitespace, 0..) |character, index| {
        if (whitespace.has(character)) {
            assert(index != 0);
            break .{
                .capture = no_leading_whitespace[0 .. index - 1],
                .remainder = no_leading_whitespace[index..],
            };
        }
    } else .{
        .capture = no_leading_whitespace,
        .remainder = "",
    };
}

fn string_line_size(line: []const u8) !u32 {
    return if (one_word(line)) |word| blk: {
        const capture, const remainder = word;
        break :blk switch (capture[0]) {
            ':' => @call(.always_tail, string_line_size, .{remainder}),
            '"' => unreachable, // FIXME
            else => error.not_actually_a_string,
        };
    } else error.empty_line;
}

fn line_size(line: []const u8) !u32 {
    var words = std.mem.tokenizeAny(line, " \t\r");
    if (words.peek() == null) return 0;
    return while (words.next()) |word| {
        break switch (word[0]) {
            '>' => 0,
            ':' => continue,
            '"' => try string_line_size(line),
            else => 1,
        };
    } else 1;
}

fn parse_line(_: []const u8) !i32 {
    unreachable; // FIXME
}

fn collect_names(
    labels: *Environment,
    constants: *Environment,
    source: []const u8,
    error_position: *u32,
) !void {
    var memory_address: i32 = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    var current_line: u32 = 0;
    errdefer error_position.* = current_line;
    while (lines.next()) |line| {
        current_line +|= 1;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        if (words.peek()) |word| {
            switch (word[0]) {
                ':' => {
                    const entry = try labels.getOrPut(word[1..]);
                    if (entry.found_existing) return error.label_collision;
                    entry.value_ptr.* = memory_address;
                },
                '>' => {
                    const entry = try constants.getOrPut(word[1..]);
                    if (entry.found_existing) return error.constant_collision;
                    entry.value_ptr.* = try parse_line(line);
                },
                else => {},
            }
            memory_address +%= try line_size(line);
        }
    }
}

fn assemble(
    labels: *Environment,
    constants: *Environment,
    source: []const u8,
    memory: *Memory,
    error_position: *u32,
) !void {
    _ = error_position; // autofix
    _ = memory; // autofix
    _ = source; // autofix
    _ = constants; // autofix
    _ = labels; // autofix
    unreachable;
}

pub fn parse(
    self: Chaff,
    source: []const u8,
    error_position: *u32,
) ![]i32 {
    assert(source.len < std.math.maxInt(u32) + 2);
    const allocator = self.allocator;

    var memory = Memory.init(allocator);
    errdefer memory.deinit();

    var labels = Environment.init(allocator);
    defer free_keys_and_deinit(allocator, &labels);

    var constants = Environment.init(allocator);
    defer free_keys_and_deinit(allocator, &constants);

    try collect_names(&labels, &constants, source, error_position);
    try assemble(&labels, &constants, source, &memory, error_position);

    return memory.toOwnedSlice();
}
