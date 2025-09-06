const std = @import("std");
const Int = std.meta.Int;
const data = @import("data.zig");

pub const Op = data.Op;
pub const Code = data.Code;
pub const Syscall = data.Syscall;

const VM = @This();
pub const max_ram_size = data.max_memory_size;

ram: []i32,

data_stack: Data_Stack,
return_stack: Return_Stack,
pc: i32,
isr: Code,
a: i32,
done: bool,

pub fn init(ram: []i32) VM {
    return .{
        .data_stack = .empty,
        .return_stack = .empty,
        .pc = 0,
        .isr = .empty,
        .a = 0,
        .done = false,
        .ram = ram,
    };
}

const Data_Stack = Stack(64, i32);
const Return_Stack = Stack(64, Return_Frame);

pub const Return_Frame = struct {
    pc: i32,
    isr: Code,

    pub fn init(pc: i32) @This() {
        return .{ .pc = pc, .isr = .empty };
    }
};

pub fn Stack(comptime n: usize, comptime T: type) type {
    if (n < 8) @compileError("Stack capacity too small");
    return struct {
        const Stack_Size = Int(.unsigned, @bitSizeOf(@TypeOf(n)) - @clz(n));

        size: Stack_Size,
        array: [n]T,

        const empty: @This() = .{
            .size = 0,
            .array = undefined,
        };

        pub const capacity: Stack_Size = n;

        pub const Underflow_Error = error{stack_underflow};
        pub const Overflow_Error = error{stack_overflow};

        pub const Error = Underflow_Error || Overflow_Error;

        pub fn top(self: *const @This()) Underflow_Error!T {
            return if (self.size == 0)
                error.stack_underflow
            else
                self.array[self.size - 1];
        }

        pub fn top2(self: *const @This()) Underflow_Error![2]T {
            return if (self.size < 2)
                error.stack_underflow
            else
                .{
                    self.array[self.size - 2],
                    self.array[self.size - 1],
                };
        }

        pub fn push(self: *@This(), item: T) Overflow_Error!void {
            if (self.size == capacity) {
                return error.stack_overflow;
            }
            self.array[self.size] = item;
            self.size += 1;
        }

        pub fn pop(self: *@This()) Underflow_Error!void {
            if (self.size == 0) return error.stack_underflow;
            self.size -= 1;
        }

        pub fn pop2(self: *@This()) Underflow_Error!void {
            if (self.size < 2) return error.stack_underflow;
            self.size -= 2;
        }
    };
}

pub fn image_native_to_big(image: []i32) void {
    for (image, 0..) |value, idx| {
        image[idx] = data.i32_to_big(value);
    }
}

fn address(vm: *VM, n: i32) !u32 {
    return if (n < 0 or vm.ram.len <= n)
        error.address_out_of_range
    else
        @bitCast(n);
}

pub fn load(
    vm: *VM,
    target: union(enum) { pc: void, a: void, r: void, mem: i32 },
) !i32 {
    const source = switch (target) {
        .pc => vm.pc,
        .a => vm.a,
        .r => (try vm.return_stack.top()).pc,
        .mem => |addr| addr,
    };
    return std.mem.bigToNative(i32, vm.ram[try vm.address(source)]);
}

pub fn store(
    vm: *VM,
    target: union(enum) { a: void, r: void, mem: i32 },
) !void {
    const source = switch (target) {
        .a => vm.a,
        .r => (try vm.return_stack.top()).pc,
        .mem => |addr| addr,
    };
    vm.ram[try vm.address(source)] =
        data.i32_to_big(try vm.data_stack.top());
    vm.data_stack.pop() catch unreachable;
}

pub fn buffer_at(vm: *VM, addr: i32) ![]u8 {
    const bytes_len: u32 = @bitCast(try vm.load(.{ .mem = addr }));
    const uaddr = vm.address(addr) catch unreachable;
    return std.mem.sliceAsBytes(vm.ram[uaddr + 1 ..])[0..bytes_len];
}

pub const Error = Data_Stack.Error || Return_Stack.Error || error{
    address_out_of_range,
    cannot_execute_after_halting,
    unknown_syscall,
    syscall_failed, // maybe this shouldn't be here
};

fn next(vm: *VM) VM.Op {
    const opcode = vm.isr.current();
    vm.isr = vm.isr.step();
    return opcode;
}

pub fn run(vm: *VM) Error!void {
    if (vm.done) return error.cannot_execute_after_halting;
    run: switch (Op.nop) {
        .pc_fetch => {
            vm.isr = Code.from_i32(try vm.load(.pc));
            vm.pc +%= 1;
            continue :run vm.next();
        },

        .jump => {
            vm.pc = try vm.load(.pc);
            vm.isr = .empty;
            continue :run vm.next();
        },

        .jump_zero => {
            if (try vm.data_stack.top() == 0) {
                vm.pc = try vm.load(.pc);
                vm.isr = .empty;
            } else {
                vm.pc +%= 1;
            }
            vm.data_stack.pop() catch unreachable;
            continue :run vm.next();
        },

        .jump_plus => {
            if (0 < try vm.data_stack.top()) {
                vm.pc = try vm.load(.pc);
                vm.isr = .empty;
            } else {
                vm.pc +%= 1;
            }
            vm.data_stack.pop() catch unreachable;
            continue :run vm.next();
        },

        .call => {
            try vm.return_stack.push(.{
                .pc = vm.pc +% 1,
                .isr = vm.isr,
            });
            vm.pc = try vm.load(.pc);
            vm.isr = .empty;
            continue :run vm.next();
        },

        .ret => {
            const target = try vm.return_stack.top();
            vm.return_stack.pop() catch unreachable;
            vm.pc = target.pc;
            vm.isr = target.isr;
            continue :run vm.next();
        },

        .halt => {
            vm.done = true;
        },

        .push_a => {
            vm.a = try vm.data_stack.top();
            vm.data_stack.pop() catch unreachable;
            continue :run vm.next();
        },

        .pop_a => {
            try vm.data_stack.push(vm.a);
            continue :run vm.next();
        },

        .push_r => {
            try vm.return_stack.push(.init(try vm.data_stack.top()));
            vm.data_stack.pop() catch unreachable;
            continue :run vm.next();
        },

        .pop_r => {
            try vm.data_stack.push((try vm.return_stack.top()).pc);
            vm.return_stack.pop() catch unreachable;
            continue :run vm.next();
        },

        .over => {
            const value, _ = try vm.data_stack.top2();
            try vm.data_stack.push(value);
            continue :run vm.next();
        },

        .dup => {
            try vm.data_stack.push(try vm.data_stack.top());
            continue :run vm.next();
        },

        .drop => {
            try vm.data_stack.pop();
            continue :run vm.next();
        },

        .swap => {
            const top = try vm.data_stack.top2();
            vm.data_stack.pop2() catch unreachable;
            vm.data_stack.push(top[1]) catch unreachable;
            vm.data_stack.push(top[0]) catch unreachable;
            continue :run vm.next();
        },

        .load_a => {
            try vm.data_stack.push(try vm.load(.a));
            continue :run vm.next();
        },

        .store_a => {
            try vm.store(.a);
            continue :run vm.next();
        },

        .load_a_plus => {
            try vm.data_stack.push(try vm.load(.a));
            vm.a +%= 1;
            continue :run vm.next();
        },

        .store_a_plus => {
            try vm.store(.a);
            vm.a +%= 1;
            continue :run vm.next();
        },

        .load_r_plus => {
            const target = try vm.return_stack.top();
            try vm.data_stack.push(try vm.load(.r));
            vm.return_stack.pop() catch unreachable;
            vm.return_stack.push(.{
                .pc = target.pc +% 1,
                .isr = target.isr,
            }) catch unreachable;
            continue :run vm.next();
        },

        .store_r_plus => {
            const target = try vm.return_stack.top();
            try vm.store(.r);
            vm.return_stack.pop() catch unreachable;
            vm.return_stack.push(.{
                .pc = target.pc +% 1,
                .isr = target.isr,
            }) catch unreachable;
            continue :run vm.next();
        },

        .literal => {
            try vm.data_stack.push(try vm.load(.pc));
            vm.pc +%= 1;
            continue :run vm.next();
        },

        .@"and" => {
            const top = try vm.data_stack.top2();
            vm.data_stack.pop2() catch unreachable;
            vm.data_stack.push(top[0] & top[1]) catch unreachable;
            continue :run vm.next();
        },

        .not => {
            const top = try vm.data_stack.top();
            vm.data_stack.pop() catch unreachable;
            vm.data_stack.push(~top) catch unreachable;
            continue :run vm.next();
        },

        .@"or" => {
            const top = try vm.data_stack.top2();
            vm.data_stack.pop2() catch unreachable;
            vm.data_stack.push(top[0] | top[1]) catch unreachable;
            continue :run vm.next();
        },

        .xor => {
            const top = try vm.data_stack.top2();
            vm.data_stack.pop2() catch unreachable;
            vm.data_stack.push(top[0] ^ top[1]) catch unreachable;
            continue :run vm.next();
        },

        .plus => {
            const top = try vm.data_stack.top2();
            vm.data_stack.pop2() catch unreachable;
            vm.data_stack.push(top[0] +% top[1]) catch unreachable;
            continue :run vm.next();
        },

        .double => {
            const top = try vm.data_stack.top();
            vm.data_stack.pop() catch unreachable;
            vm.data_stack.push(top << 1) catch unreachable;
            continue :run vm.next();
        },

        .half => {
            const top = try vm.data_stack.top();
            vm.data_stack.pop() catch unreachable;
            vm.data_stack.push(top >> 1) catch unreachable;
            continue :run vm.next();
        },

        .plus_star => {
            const top = try vm.data_stack.top2();
            if (top[1] & 1 == 1) {
                vm.data_stack.pop() catch unreachable;
                vm.data_stack.push(top[0] +% top[1]) catch unreachable;
            }
            continue :run vm.next();
        },

        .nop => {
            continue :run vm.next();
        },

        .syscall => {
            const top: u32 = @bitCast(try vm.data_stack.top());
            const syscall_id = std.meta.intToEnum(VM.Syscall, top) catch
                return error.unknown_syscall;
            vm.data_stack.pop() catch unreachable;
            try switch (syscall_id) {
                inline else => |id| @field(system, @tagName(id))(vm),
            };
            continue :run vm.next();
        },
    }
}

const system = struct {
    pub fn read(vm: *VM) Error!void {
        const buf_addr, const fd: std.posix.fd_t = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        const buf = try vm.buffer_at(buf_addr);
        const bytes_read = std.posix.read(fd, buf) catch
            return error.syscall_failed;
        vm.data_stack.push(@bitCast(@as(u32, @truncate(bytes_read)))) catch
            unreachable;
    }

    pub fn write(vm: *VM) Error!void {
        const buf_addr, const fd: std.posix.fd_t = try vm.data_stack.top2();
        vm.data_stack.pop2() catch unreachable;
        const buf = try vm.buffer_at(buf_addr);
        const bytes_written = std.posix.write(fd, buf) catch
            return error.syscall_failed;
        vm.data_stack.push(@bitCast(@as(u32, @truncate(bytes_written)))) catch
            unreachable;
    }
};

test "triangle numbers" {
    var triangle_numbers_image = comptime [_]i32{
        // from the original chime repository
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
    var vm_state: VM = .init(&triangle_numbers_image);
    const vm = &vm_state;

    const result = vm.run();

    try std.testing.expectEqual(void{}, result);

    try std.testing.expectEqual(@as(i32, 15), try vm.data_stack.top());
}

test "short multiplication" {
    const shift_16_left = comptime [_]i32{Code.from_slice(
        &(.{.double} ** 6),
    ).?.to_i32()} ** 2 ++ .{
        Code.from_slice(
            &.{ .double, .double, .double, .double, .ret },
        ).?.to_i32(),
    };

    var short_multiplication = comptime [_]i32{
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
    var vm_state: VM = .init(&short_multiplication);
    const vm = &vm_state;

    const result = vm.run();

    try std.testing.expectEqual(void{}, result);

    try std.testing.expectEqual(@as(i32, 252756), try vm.data_stack.top());
}
