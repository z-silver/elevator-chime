const std = @import("std");
const Int = std.meta.Int;
const data = @import("data.zig");
pub const Op = data.Op;
pub const Code = data.Code;

const VM = @This();

ram: []i32,

data_stack: Stack(64, i32) = .{},
return_stack: Stack(64, Return_Frame) = .{},
pc: i32 = 0,
isr: Code = .{},
a: i32 = 0,
is_running: bool = true,

pub const Return_Frame = struct {
    pc: i32 = 0,
    isr: Code = .{},
};

pub fn Stack(comptime n: usize, comptime T: type) type {
    if (n < 8) @compileError("Stack capacity too small");
    return struct {
        const Stack_Size = Int(.unsigned, @bitSizeOf(@TypeOf(n)) - @clz(n));
        size: Stack_Size = 0,
        array: [n]T = undefined,

        pub const capacity: Stack_Size = n;

        pub fn top(self: *const @This()) !T {
            return if (self.size == 0)
                error.InvalidStackOperation
            else
                self.array[self.size - 1];
        }

        pub fn top2(self: *const @This()) ![2]T {
            return if (self.size < 2)
                error.InvalidStackOperation
            else
                .{
                    self.array[self.size - 2],
                    self.array[self.size - 1],
                };
        }

        pub fn push(self: *@This(), item: T) !void {
            if (self.size == capacity) {
                return error.InvalidStackOperation;
            }
            self.array[self.size] = item;
            self.size += 1;
        }

        pub fn pop(self: *@This()) !void {
            if (self.size == 0) return error.InvalidStackOperation;
            self.size -= 1;
        }

        pub fn pop2(self: *@This()) !void {
            if (self.size < 2) return error.InvalidStackOperation;
            self.size -= 2;
        }
    };
}

pub fn load(vm: *@This(), target: enum { pc, a, r }) !i32 {
    const source = switch (target) {
        .pc => vm.pc,
        .a => vm.a,
        .r => (try vm.return_stack.top()).pc,
    };
    return if (source < 0 or vm.ram.len <= source)
        error.MemoryOutOfRange
    else
        vm.ram[@as(u32, @bitCast(source))];
}

pub fn store(vm: *@This(), target: enum { a, r }) !void {
    const source = switch (target) {
        .a => vm.a,
        .r => (try vm.return_stack.top()).pc,
    };
    if (source < 0 or vm.ram.len <= source) return error.MemoryOutOfRange;
    const address: u32 = @bitCast(source);
    vm.ram[address] = try vm.data_stack.top();
    try vm.data_stack.pop();
}

pub fn step(vm: *@This()) !void {
    if (!vm.is_running) return error.CannotStepAfterHalting;
    const current_instruction = vm.isr.current();
    vm.isr = vm.isr.step();

    switch (current_instruction) {
        .pc_fetch => {
            vm.isr = Code.from_i32(try vm.load(.pc));
            vm.pc +%= 1;
        },
        .jump => {
            vm.pc = try vm.load(.pc);
            vm.isr = Code{};
        },
        .jump_zero => {
            if (try vm.data_stack.top() == 0) {
                vm.pc = try vm.load(.pc);
                vm.isr = Code{};
            }
            try vm.data_stack.pop();
            vm.pc +%= 1;
        },
        .jump_plus => {
            if (0 < try vm.data_stack.top()) {
                vm.pc = try vm.load(.pc);
                vm.isr = .{};
            }
            try vm.data_stack.pop();
            vm.pc +%= 1;
        },
        .call => {
            try vm.return_stack.push(.{
                .pc = vm.pc +% 1,
                .isr = vm.isr,
            });
            vm.pc = try vm.load(.pc);
            vm.isr = .{};
        },
        .ret => {
            const target = try vm.return_stack.top();
            try vm.return_stack.pop();
            vm.pc = target.pc;
            vm.isr = target.isr;
        },
        .halt => {
            vm.is_running = false;
        },
        .push_a => {
            vm.a = try vm.data_stack.top();
            try vm.data_stack.pop();
        },
        .pop_a => {
            try vm.data_stack.push(vm.a);
        },
        .push_r => {
            try vm.return_stack.push(.{ .pc = try vm.data_stack.top() });
            try vm.data_stack.pop();
        },
        .pop_r => {
            try vm.data_stack.push((try vm.return_stack.top()).pc);
            try vm.return_stack.pop();
        },
        .over => try vm.data_stack.push((try vm.data_stack.top2())[0]),
        .dup => try vm.data_stack.push(try vm.data_stack.top()),
        .drop => try vm.data_stack.pop(),
        .load_a => try vm.data_stack.push(try vm.load(.a)),
        .store_a => try vm.store(.a),
        .load_a_plus => {
            try vm.data_stack.push(try vm.load(.a));
            vm.a +%= 1;
        },
        .store_a_plus => {
            try vm.store(.a);
            vm.a +%= 1;
        },
        .load_r_plus => {
            const target = try vm.return_stack.top();
            try vm.data_stack.push(try vm.load(.r));
            try vm.return_stack.pop();
            try vm.return_stack.push(.{ .pc = target.pc +% 1, .isr = target.isr });
        },
        .store_r_plus => {
            const target = try vm.return_stack.top();
            try vm.store(.r);
            try vm.return_stack.pop();
            try vm.return_stack.push(.{ .pc = target.pc +% 1, .isr = target.isr });
        },
        .literal => {
            try vm.data_stack.push(try vm.load(.pc));
            vm.pc +%= 1;
        },
        .@"and" => {
            const top = try vm.data_stack.top2();
            try vm.data_stack.pop2();
            try vm.data_stack.push(top[0] & top[1]);
        },
        .not => {
            const top = try vm.data_stack.top();
            try vm.data_stack.pop();
            try vm.data_stack.push(~top);
        },
        .@"or" => {
            const top = try vm.data_stack.top2();
            try vm.data_stack.pop2();
            try vm.data_stack.push(top[0] | top[1]);
        },
        .xor => {
            const top = try vm.data_stack.top2();
            try vm.data_stack.pop2();
            try vm.data_stack.push(top[0] ^ top[1]);
        },
        .plus => {
            const top = try vm.data_stack.top2();
            try vm.data_stack.pop2();
            try vm.data_stack.push(top[0] +% top[1]);
        },
        .double => {
            const top = try vm.data_stack.top();
            try vm.data_stack.pop();
            try vm.data_stack.push(top << 1);
        },
        .half => {
            const top = try vm.data_stack.top();
            try vm.data_stack.pop();
            try vm.data_stack.push(top >> 1);
        },
        .plus_star => {
            const top = try vm.data_stack.top2();

            if (top[1] | 1 == 1) {
                try vm.data_stack.pop();
                try vm.data_stack.push(top[0] +% top[1]);
            }
        },
        .nop => {},
        .syscall => {
            // FIXME
            return error.SyscallsNotYetImplemented;
        },
    }
}

pub fn execute(vm: *@This()) !void {
    while (vm.is_running) try vm.step();
}

test "triangle numbers" {
    comptime var triangle_numbers_image = [_]i32{ // from the original chime repository
        Code.from_slice(&.{ // 0
            .literal,
            .call,
            .halt,
        }).?.to_i32(),
        5,
        3,
        Code.from_slice(&.{ // 3
            .literal,
            .jump,
        }).?.to_i32(),
        0,
        6,
        Code.from_slice(&.{ // 6
            .over,
            .jump_zero,
            .over,
            .plus,
            .push_r,
            .literal,
        }).?.to_i32(),
        11,
        -1,
        Code.from_slice(&.{ // 9
            .plus,
            .pop_r,
            .jump,
        }).?.to_i32(),
        6,
        Code.from_slice(&.{ // 11
            .push_r,
            .drop,
            .pop_r,
            .ret,
        }).?.to_i32(),
    };

    comptime var vm_storage = VM{ .ram = &triangle_numbers_image };
    const vm = comptime &vm_storage;

    const result = comptime vm.execute();

    try std.testing.expectEqual(void{}, result);

    try std.testing.expectEqual(15, try comptime vm.data_stack.top());
}
