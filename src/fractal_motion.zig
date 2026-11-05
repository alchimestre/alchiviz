const std = @import("std");

pub const Values = struct { lanes: f32, kick: f32 };

const lane_rate: f32 = 0.5;
const kick_rate: f32 = 1;
const kick_response: f32 = 0.35;

pub const State = struct {
    values: ?Values = null,

    pub fn update(self: *State, seconds: f32, target: ?Values) void {
        const goal = target orelse {
            self.values = null;
            return;
        };
        const previous = self.values orelse Values{ .lanes = goal.lanes, .kick = 0 };
        const eased_kick = goal.kick + (previous.kick - goal.kick) * @exp(-seconds / kick_response);
        self.values = .{
            .lanes = approach(previous.lanes, goal.lanes, lane_rate * seconds),
            .kick = approach(previous.kick, eased_kick, kick_rate * seconds),
        };
    }
};

fn approach(previous: f32, target: f32, limit: f32) f32 {
    return previous + std.math.clamp(target - previous, -limit, limit);
}

test "abrupt lane gestures travel at a bounded rate and reach the target" {
    var state: State = .{};
    state.update(0, .{ .lanes = 0.6, .kick = 0 });
    const step: f32 = 1.0 / 60.0;
    for (0..600) |_| {
        const previous = state.values.?.lanes;
        state.update(step, .{ .lanes = 4.3, .kick = 0 });
        const current = state.values.?.lanes;
        try std.testing.expect(current >= previous);
        try std.testing.expect(current - previous <= lane_rate * step + 0.000001);
        try std.testing.expect(current <= 4.3);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 4.3), state.values.?.lanes, 0.00001);
}

test "repeated full kicks and amount cuts cannot bypass the motion bound" {
    var state: State = .{};
    const step: f32 = 1.0 / 120.0;
    var peak: f32 = 0;
    for (0..480) |frame| {
        const previous = if (state.values) |values| values.kick else 0;
        const pulse: f32 = if (frame % 60 < 12) 1 else 0;
        state.update(step, .{ .lanes = 1, .kick = pulse });
        const current = state.values.?.kick;
        try std.testing.expect(@abs(current - previous) <= kick_rate * step + 0.000001);
        try std.testing.expect(current >= 0 and current <= 1);
        peak = @max(peak, current);
    }
    try std.testing.expect(peak > 0.05);
    for (0..480) |_| state.update(step, .{ .lanes = 1, .kick = 0 });
    try std.testing.expect(state.values.?.kick < 0.001);
}

test "leaving fractal mode discards stale controls before reentry" {
    var state: State = .{};
    state.update(1, .{ .lanes = 4, .kick = 1 });
    state.update(0, null);
    try std.testing.expect(state.values == null);
    state.update(0, .{ .lanes = 0.75, .kick = 0 });
    try std.testing.expectEqual(@as(f32, 0.75), state.values.?.lanes);
    try std.testing.expectEqual(@as(f32, 0), state.values.?.kick);
}

test "control response stays consistent across frame rates" {
    var slower: State = .{};
    var faster: State = .{};
    const start = Values{ .lanes = 1, .kick = 0 };
    const goal = Values{ .lanes = 3, .kick = 1 };
    slower.update(0, start);
    faster.update(0, start);
    for (0..60) |_| slower.update(1.0 / 60.0, goal);
    for (0..120) |_| faster.update(1.0 / 120.0, goal);
    try std.testing.expectApproxEqAbs(slower.values.?.lanes, faster.values.?.lanes, 0.00001);
    try std.testing.expectApproxEqAbs(slower.values.?.kick, faster.values.?.kick, 0.01);
}
