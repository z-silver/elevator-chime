const std = @import("std");
const Int = std.meta.Int;
const data = @import("data.zig");

pub const Op = data.Op;
pub const Code = data.Code;
pub const Syscall = data.Syscall;

const VM = @This();

ram: []i32,

data_stack: Stack(64, i32) = .{},
return_stack: Stack(64, Return_Frame) = .{},
pc: i32 = 0,
isr: Code = .{},
a: i32 = 0,
done: bool = false,

pub const Return_Frame = struct {
    pc: i32,
    isr: Code = .{},
};

pub fn Stack(comptime n: usize, comptime T: type) type {
    if (n < 8) @compileError("Stack capacity too small");
    return struct {
        const Stack_Size = Int(.unsigned, @bitSizeOf(@TypeOf(n)) - @clz(n));
        size: Stack_Size = 0,
        array: [n]T = undefined,

        pub const capacity: Stack_Size = n;

        pub fn top(self: *const @This()) error{stack_underflow}!T {
            return if (self.size == 0)
                error.stack_underflow
            else
                self.array[self.size - 1];
        }

        pub fn top2(self: *const @This()) error{stack_underflow}![2]T {
            return if (self.size < 2)
                error.stack_underflow
            else
                .{
                    self.array[self.size - 2],
                    self.array[self.size - 1],
                };
        }

        pub fn push(self: *@This(), item: T) error{stack_overflow}!void {
            if (self.size == capacity) {
                return error.stack_overflow;
            }
            self.array[self.size] = item;
            self.size += 1;
        }

        pub fn pop(self: *@This()) error{stack_underflow}!void {
            if (self.size == 0) return error.stack_underflow;
            self.size -= 1;
        }

        pub fn pop2(self: *@This()) error{stack_underflow}!void {
            if (self.size < 2) return error.stack_underflow;
            self.size -= 2;
        }
    };
}

pub fn image_native_to_big(image: []i32) void {
    for (image, 0..) |value, idx| {
        image[idx] = std.mem.nativeToBig(i32, value);
    }
}

fn load(vm: *@This(), comptime target: enum { pc, a, r }) !i32 {
    const source = switch (target) {
        .pc => vm.pc,
        .a => vm.a,
        .r => (try vm.return_stack.top()).pc,
    };
    return if (source < 0 or vm.ram.len <= source)
        error.address_out_of_range
    else
        std.mem.bigToNative(i32, vm.ram[@as(u32, @bitCast(source))]);
}

fn store(vm: *@This(), comptime target: enum { a, r }) !void {
    const source = switch (target) {
        .a => vm.a,
        .r => (try vm.return_stack.top()).pc,
    };
    if (source < 0 or vm.ram.len <= source) return error.address_out_of_range;
    const address: u32 = @bitCast(source);
    vm.ram[address] = std.mem.nativeToBig(i32, try vm.data_stack.top());
    try vm.data_stack.pop();
}

pub const Error = error{
    stack_underflow,
    stack_overflow,
    address_out_of_range,
    cannot_execute_after_halting,
    unknown_syscall,
};

const system = struct {
    pub fn read(_: *VM) Error!void {
        unreachable;
    }

    pub fn write(_: *VM) Error!void {
        unreachable;
    }
};

const instruction = struct {
    fn pc_fetch(vm: *VM) Error!void {
        vm.isr = Code.from_i32(try vm.load(.pc));
        vm.pc +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    fn jump(vm: *VM) Error!void {
        vm.pc = try vm.load(.pc);
        vm.isr = Code{};
        return @call(.always_tail, next, .{vm});
    }

    fn jump_zero(vm: *VM) Error!void {
        if (try vm.data_stack.top() == 0) {
            vm.pc = try vm.load(.pc);
            vm.isr = Code{};
        } else {
            vm.pc +%= 1;
        }
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn jump_plus(vm: *VM) Error!void {
        if (0 < try vm.data_stack.top()) {
            vm.pc = try vm.load(.pc);
            vm.isr = .{};
        } else {
            vm.pc +%= 1;
        }
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn call(vm: *VM) Error!void {
        try vm.return_stack.push(.{
            .pc = vm.pc +% 1,
            .isr = vm.isr,
        });
        vm.pc = try vm.load(.pc);
        vm.isr = .{};
        return @call(.always_tail, next, .{vm});
    }

    fn ret(vm: *VM) Error!void {
        const target = try vm.return_stack.top();
        vm.return_stack.pop() catch unreachable;
        vm.pc = target.pc;
        vm.isr = target.isr;
        return @call(.always_tail, next, .{vm});
    }

    fn halt(vm: *VM) Error!void {
        vm.done = true;
    }

    fn push_a(vm: *VM) Error!void {
        vm.a = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn pop_a(vm: *VM) Error!void {
        try vm.data_stack.push(vm.a);
        return @call(.always_tail, next, .{vm});
    }

    fn push_r(vm: *VM) Error!void {
        try vm.return_stack.push(.{ .pc = try vm.data_stack.top() });
        vm.data_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn pop_r(vm: *VM) Error!void {
        try vm.data_stack.push((try vm.return_stack.top()).pc);
        vm.return_stack.pop() catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn over(vm: *VM) Error!void {
        const value, _ = try vm.data_stack.top2();
        try vm.data_stack.push(value);
        return @call(.always_tail, next, .{vm});
    }

    fn dup(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.data_stack.top());
        return @call(.always_tail, next, .{vm});
    }

    fn drop(vm: *VM) Error!void {
        try vm.data_stack.pop();
        return @call(.always_tail, next, .{vm});
    }

    fn swap(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[1]) catch unreachable;
        vm.data_stack.push(top[0]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn load_a(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.load(.a));
        return @call(.always_tail, next, .{vm});
    }

    fn store_a(vm: *VM) Error!void {
        try vm.store(.a);
        return @call(.always_tail, next, .{vm});
    }

    fn load_a_plus(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.load(.a));
        vm.a +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    fn store_a_plus(vm: *VM) Error!void {
        try vm.store(.a);
        vm.a +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    fn load_r_plus(vm: *VM) Error!void {
        const target = try vm.return_stack.top();
        try vm.data_stack.push(try vm.load(.r));
        vm.return_stack.pop() catch unreachable;
        vm.return_stack.push(.{
            .pc = target.pc +% 1,
            .isr = target.isr,
        }) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn store_r_plus(vm: *VM) Error!void {
        const target = try vm.return_stack.top();
        try vm.store(.r);
        vm.return_stack.pop() catch unreachable;
        vm.return_stack.push(.{
            .pc = target.pc +% 1,
            .isr = target.isr,
        }) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn literal(vm: *VM) Error!void {
        try vm.data_stack.push(try vm.load(.pc));
        vm.pc +%= 1;
        return @call(.always_tail, next, .{vm});
    }

    fn @"and"(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] & top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn not(vm: *VM) Error!void {
        const top = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        vm.data_stack.push(~top) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn @"or"(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] | top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn xor(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] ^ top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn plus(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        vm.data_stack.push(top[0] +% top[1]) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn double(vm: *VM) Error!void {
        const top = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        vm.data_stack.push(top << 1) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn half(vm: *VM) Error!void {
        const top = try vm.data_stack.top();
        vm.data_stack.pop() catch unreachable;
        vm.data_stack.push(top >> 1) catch unreachable;
        return @call(.always_tail, next, .{vm});
    }

    fn plus_star(vm: *VM) Error!void {
        const top = try vm.data_stack.top2();

        if (top[1] & 1 == 1) {
            vm.data_stack.pop() catch unreachable;
            vm.data_stack.push(top[0] +% top[1]) catch unreachable;
        }
        return @call(.always_tail, next, .{vm});
    }

    fn nop(vm: *VM) Error!void {
        return @call(.always_tail, next, .{vm});
    }

    fn syscall(vm: *VM) Error!void {
        const top: u32 = @bitCast(try vm.data_stack.top());
        const syscall_id = std.meta.intToEnum(Syscall, top) catch
            return error.unknown_syscall;
        vm.data_stack.pop() catch unreachable;
        try switch (syscall_id) {
            inline else => |id| @field(system, @tagName(id))(vm),
        };
        return @call(.always_tail, next, .{vm});
    }

    pub inline fn next(vm: *VM) Error!void {
        const current_instruction = vm.isr.current();
        vm.isr = vm.isr.step();

        return switch (current_instruction) {
            inline else => |inst| @call(
                .always_tail,
                @field(instruction, @tagName(inst)),
                .{vm},
            ),
        };
    }
};

pub fn run(vm: *@This()) Error!void {
    return if (vm.done)
        error.cannot_execute_after_halting
    else
        @call(.always_tail, instruction.next, .{vm});
}

test "triangle numbers" {
    var triangle_numbers_image = [_]i32{ // from the original chime repository
        Code.from_slice(
            // 0
            &.{ .literal, .call, .halt },
        ).?.to_i32(),
        5,
        3,
        Code.from_slice(
            // 3
            &.{ .literal, .jump },
        ).?.to_i32(),
        0,
        6,
        Code.from_slice(
            // 6
            &.{ .over, .jump_zero, .over, .plus, .push_r, .literal },
        ).?.to_i32(),
        11,
        -1,
        Code.from_slice(
            &.{ .plus, .pop_r, .jump },
        ).?.to_i32(),
        6,
        Code.from_slice(
            // 11
            &.{ .push_r, .drop, .pop_r, .ret },
        ).?.to_i32(),
    };

    image_native_to_big(&triangle_numbers_image);
    var vm_storage = VM{ .ram = &triangle_numbers_image };
    const vm = &vm_storage;

    const result = vm.run();

    try std.testing.expectEqual(void{}, result);

    try std.testing.expectEqual(@as(i32, 15), try vm.data_stack.top());
}

test "short multiplication" {
    const shift_16_left = [_]i32{Code.from_slice(
        &(.{.double} ** 6),
    ).?.to_i32()} ** 2 ++ .{
        Code.from_slice(
            &.{ .double, .double, .double, .double, .ret },
        ).?.to_i32(),
    };

    var short_multiplication = [_]i32{
        Code.from_slice(
            &.{ .literal, .literal, .call, .halt },
        ).?.to_i32(),
        413,
        612,
        4,
        Code.from_slice(
            // 4
            &.{ .literal, .@"and", .push_r, .call, .pop_r, .plus_star },
        ).?.to_i32(),
        0xffff,
        13,
    } ++ .{Code.from_slice(
        &(.{ .half, .plus_star } ** 3),
    ).?.to_i32()} ** 5 ++ .{Code.from_slice(
        &.{ .half, .push_r, .drop, .pop_r, .ret },
    ).?.to_i32()} ++
        // 13
        shift_16_left;

    image_native_to_big(&short_multiplication);
    var vm_storage = VM{ .ram = &short_multiplication };
    const vm = &vm_storage;

    const result = vm.run();

    try std.testing.expectEqual(void{}, result);

    try std.testing.expectEqual(@as(i32, 252756), try vm.data_stack.top());
}
