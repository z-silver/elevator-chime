const std = @import("std");
const data = @import("data.zig");
const assert = std.debug.assert;

const i32_to_big = data.i32_to_big;

pub const Dialect = std.StaticStringMap(data.Op);
const Memory = std.ArrayListUnmanaged(i32);
const Environment = std.StringHashMapUnmanaged(i32);
const Fixups = std.AutoHashMapUnmanaged(
    i32,
    union(enum) { label: []const u8, constant: []const u8 },
);

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.io.getStdIn().readToEndAlloc(arena, max_source_size);
    var error_line: u32 = 0;
    const stderr = std.io.getStdErr().writer();
    const program = parse(
        arena,
        lemos_dialect,
        source,
        &error_line,
    ) catch |err| {
        try stderr.print(
            "Error on line {}, code: {}.\n",
            .{ error_line, err },
        );
        return err;
    };
    std.io.getStdOut().writeAll(std.mem.sliceAsBytes(program)) catch |err| {
        try stderr.print("Failed to write to stdout.\n", .{});
        return err;
    };
    std.process.cleanExit();
}

fn current_address(items: []const i32) i32 {
    return @bitCast(@as(u32, @intCast(items.len)));
}

pub const max_source_size = std.math.maxInt(u32) + 1;

pub fn parse(
    arena: std.mem.Allocator,
    dialect: Dialect,
    source: []const u8,
    error_position: *u32,
) ![]i32 {
    var current_line: u32 = 0;
    errdefer error_position.* = current_line;

    if (max_source_size < source.len) {
        return error.source_too_large;
    }
    var memory: Memory = .empty;
    var fixups: Fixups = .empty;
    var labels: Environment = .empty;
    var constants: Environment = .empty;

    var remaining = source;
    while (one_line(remaining)) |line_and_remaining| {
        const line, remaining = line_and_remaining;
        current_line += 1;
        if (std.mem.indexOfScalar(u8, line, '\r')) |_|
            return error.line_contains_carriage_return;
        const word, const rest = any_whitespace_one_word(line) orelse continue;
        const subject = switch (word[0]) {
            ':' => blk: {
                const entry = try labels.getOrPut(arena, word[1..]);
                if (entry.found_existing) return error.label_collision;
                const addr = current_address(memory.items);
                entry.value_ptr.* = i32_to_big(addr);
                break :blk rest;
            },
            '>' => {
                const entry = try constants.getOrPut(arena, word[1..]);
                if (entry.found_existing) return error.constant_collision;
                entry.value_ptr.* = switch (try one_cell_or_string(dialect, rest)) {
                    .cell => |cell| cell,
                    else => return error.invalid_constant,
                };
                continue;
            },
            else => line,
        };
        switch (try one_cell_or_string(dialect, subject)) {
            .cell => |cell| try memory.append(arena, cell),
            .string => |string| {
                assert(string.len < std.math.maxInt(u32));
                const length_in_memory: u32 = @intCast(string.len);
                const almost_words = string.len >> 2;
                const trailing = string.len & 0b11;
                const words = almost_words + @intFromBool(trailing != 0);
                try memory.ensureUnusedCapacity(arena, words + 1);
                memory.appendAssumeCapacity(i32_to_big(@bitCast(length_in_memory)));
                const target = memory.addManyAsSliceAssumeCapacity(words);
                @memcpy(
                    std.mem.sliceAsBytes(target)[0 .. string.len - trailing],
                    string[0 .. string.len - trailing],
                );
                if (trailing != 0) {
                    var final_item = std.mem.zeroes([4]u8);
                    @memcpy(final_item[0..trailing], string[string.len - trailing ..]);
                    target[target.len - 1] = @bitCast(final_item);
                }
            },
            .label => |label| {
                if (labels.get(label)) |value| {
                    try memory.append(arena, value);
                } else {
                    try fixups.putNoClobber(
                        arena,
                        current_address(memory.items),
                        .{ .label = label },
                    );
                    try memory.append(arena, 0);
                }
            },
            .constant => |constant| {
                if (constants.get(constant)) |value| {
                    try memory.append(arena, value);
                } else {
                    try fixups.putNoClobber(
                        arena,
                        current_address(memory.items),
                        .{ .constant = constant },
                    );
                    try memory.append(arena, 0);
                }
            },
        }
    }
    var fixes = fixups.iterator();
    while (fixes.next()) |fix| {
        const address: u32 = @bitCast(fix.key_ptr.*);
        memory.items[address] = switch (fix.value_ptr.*) {
            .constant => |name| constants.get(name) orelse
                return error.undefined_constant,
            .label => |name| labels.get(name) orelse
                return error.undefined_label,
        };
    }
    return memory.toOwnedSlice(arena);
}

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
    const total_opcodes = @typeInfo(data.Op).@"enum".fields.len;
    const Instruction_Set = std.StaticBitSet(total_opcodes);
    var instruction_set = Instruction_Set.initEmpty();
    for (lemos_dialect.values()) |op| {
        instruction_set.set(@intFromEnum(op));
    }
    assert(instruction_set.eql(Instruction_Set.initFull()));
}

const whitespace = blk: {
    var whitespace_set = std.StaticBitSet(std.math.maxInt(u8) + 1).initEmpty();
    for (.{ ' ', '\t' }) |char| {
        whitespace_set.set(char);
    }
    break :blk whitespace_set;
};

fn any_whitespace(subject: []const u8) []const u8 {
    return for (subject, 0..) |character, index| {
        if (!whitespace.isSet(character))
            break subject[index..];
    } else &.{};
}

const With_Capture = struct {
    capture: []const u8,
    remainder: []const u8,
};

fn one_line(subject: []const u8) ?[2][]const u8 {
    return if (subject.len == 0)
        null
    else for (subject, 0..) |character, index| {
        if (character != '\n') continue;
        break .{
            subject[0 .. index -
                @intFromBool(index != 0 and subject[index - 1] == '\r')],
            subject[index + 1 ..],
        };
    } else .{ subject, &.{} };
}

fn one_word(subject: []const u8) ?[2][]const u8 {
    return if (subject.len == 0 or whitespace.isSet(subject[0]))
        null
    else for (subject, 0..) |character, index| {
        if (whitespace.isSet(character)) {
            assert(index != 0);
            break .{ subject[0..index], subject[index..] };
        }
    } else .{ subject, &.{} };
}

fn any_whitespace_one_word(subject: []const u8) ?[2][]const u8 {
    const no_leading_whitespace = any_whitespace(subject);
    if (no_leading_whitespace.len == 0) return null;
    assert(!whitespace.isSet(no_leading_whitespace[0]));
    return one_word(no_leading_whitespace);
}

fn one_cell_or_string(dialect: Dialect, subject: []const u8) !union(enum) {
    cell: i32,
    label: []const u8,
    constant: []const u8,
    string: []const u8,
} {
    const remaining = any_whitespace(subject);
    return if (remaining.len == 0)
        .{ .cell = 0 }
    else switch (remaining[0]) {
        '&' => .{ .label = try one_label_only(remaining[1..]) },
        '*' => .{ .constant = try one_label_only(remaining[1..]) },
        '#' => .{ .cell = i32_to_big(try one_number_only(remaining[1..])) },
        '"' => .{ .string = try one_string_only_no_opening(remaining[1..]) },
        else => .{ .cell = i32_to_big(
            try one_instruction_word_only(dialect, remaining),
        ) },
    };
}

fn one_label_only(subject: []const u8) ![]const u8 {
    if (one_word(subject)) |word_and_remaining| {
        const word, const remaining = word_and_remaining;
        return if (any_whitespace(remaining).len != 0)
            error.invalid_cell
        else
            word;
    } else return error.name_cannot_be_empty;
}

fn one_string_only_no_opening(subject: []const u8) ![]const u8 {
    const closing_quote =
        std.mem.lastIndexOfScalar(u8, subject, '"') orelse
        return error.invalid_string;
    return if (any_whitespace(subject[closing_quote + 1 ..]).len != 0)
        error.invalid_string
    else
        subject[0..closing_quote];
}

fn one_number_only(subject: []const u8) !i32 {
    if (one_word(subject)) |word_and_remaining| {
        const word, const remaining = word_and_remaining;
        return if (any_whitespace(remaining).len != 0)
            error.invalid_cell
        else
            std.fmt.parseInt(i32, word, 10) catch
                @as(i32, @bitCast(try std.fmt.parseUnsigned(u32, word, 10)));
    } else return error.number_cannot_be_empty;
}

fn one_instruction_word_only(dialect: Dialect, subject: []const u8) !i32 {
    var ops = std.mem.zeroes([data.Op.per_word]data.Op);
    var rest: []const u8 = subject;
    for (0..ops.len) |slot| {
        const word, rest = any_whitespace_one_word(rest) orelse break;
        ops[slot] = dialect.get(word) orelse return error.invalid_instruction;
    } else if (any_whitespace(rest).len != 0) return error.invalid_cell;
    return data.Code.from_slice(&ops).?.to_i32();
}
