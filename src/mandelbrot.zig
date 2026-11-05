const std = @import("std");
const dvui = @import("dvui");

pub const Coordinates = struct { depth: f32, angle: f32 };
pub const Shot = struct { region: usize, progress: f32 };
pub const Transition = struct { front: Shot, incoming: Shot, weight: f32 };

pub const centres: [3][2]f64 = .{
    .{ -0.743643887037151, 0.13182590420533 },
    .{ -1.25066, 0.02012 },
    .{ -1.769378833, 0.003138996 },
};
pub const iterations: usize = 192;
pub const escape_squared: f32 = 256;
pub const depth_scale: f32 = @floatFromInt(iterations);
pub const start_extent: f32 = 0.08;
pub const end_extent: f32 = 0.0005;
pub const zoom_log_scale: f32 = @log(start_extent / end_extent);
pub const cycle_seconds: f64 = 60;
pub const transition_start: f32 = 0.9;

const route_seconds: f64 = cycle_seconds * @as(f64, @floatFromInt(centres.len));

fn makeReference() [centres.len][iterations + 1][2]f32 {
    var result: [centres.len][iterations + 1][2]f32 = undefined;
    for (centres, 0..) |center, region| {
        var real: f64 = 0;
        var imaginary: f64 = 0;
        result[region][0] = .{ 0, 0 };
        for (0..iterations) |iteration| {
            const next_real = real * real - imaginary * imaginary + center[0];
            const next_imaginary = 2 * real * imaginary + center[1];
            real = next_real;
            imaginary = next_imaginary;
            result[region][iteration + 1] = .{ @floatCast(real), @floatCast(imaginary) };
        }
    }
    return result;
}

pub const reference: [centres.len][iterations + 1][2]f32 = makeReference();

pub fn phase(time: f64) f32 {
    return @floatCast(@mod(time, route_seconds) / cycle_seconds);
}

fn smoothstep(edge_start: f32, edge_end: f32, value: f32) f32 {
    const t = std.math.clamp((value - edge_start) / (edge_end - edge_start), 0, 1);
    return t * t * (3 - 2 * t);
}

pub fn transition(zoom_phase: f32) Transition {
    const region_count: f32 = @floatFromInt(centres.len);
    const wrapped_phase = @mod(zoom_phase, region_count);
    const region_progress = @floor(wrapped_phase);
    const region: usize = @intFromFloat(region_progress);
    const progress = wrapped_phase - region_progress;
    return .{
        .front = .{ .region = region, .progress = smoothstep(0, transition_start, progress) },
        .incoming = .{ .region = (region + 1) % centres.len, .progress = 0 },
        .weight = smoothstep(transition_start, 1, progress),
    };
}

fn cameraScale(progress: f32) f32 {
    return start_extent * @exp(-progress * zoom_log_scale);
}

fn parameterDisplacement(point: dvui.Point.Physical, half: f32, progress: f32) [2]f32 {
    const scale = cameraScale(progress);
    return .{ point.x / half * scale, point.y / half * scale };
}

fn inMainCardioidOrPeriodTwo(real: f32, imaginary: f32) bool {
    const shifted_real = real - 0.25;
    const cardioid_radius_squared = shifted_real * shifted_real + imaginary * imaginary;
    const in_main_cardioid = cardioid_radius_squared * (cardioid_radius_squared + shifted_real) <=
        0.25 * imaginary * imaginary;
    const bulb_real = real + 1;
    const in_period_two_bulb = bulb_real * bulb_real + imaginary * imaginary <= 0.0625;
    return in_main_cardioid or in_period_two_bulb;
}

fn boundedCoordinates(point: dvui.Point.Physical, half: f32) Coordinates {
    const point_length = @sqrt(point.x * point.x + point.y * point.y);
    const iteration_limit: f32 = @floatFromInt(iterations);
    return .{
        .depth = iteration_limit / depth_scale + point_length / half * 0.25,
        .angle = std.math.atan2(point.y, point.x),
    };
}

fn branchCoordinates(
    point: dvui.Point.Physical,
    half: f32,
    region: usize,
    progress: f32,
) Coordinates {
    const displacement = parameterDisplacement(point, half, progress);
    const center_real: f32 = @floatCast(centres[region][0]);
    const center_imaginary: f32 = @floatCast(centres[region][1]);
    const parameter_real = center_real + displacement[0];
    const parameter_imaginary = center_imaginary + displacement[1];
    if (inMainCardioidOrPeriodTwo(parameter_real, parameter_imaginary)) {
        return boundedCoordinates(point, half);
    }

    var delta_real: f32 = 0;
    var delta_imaginary: f32 = 0;
    for (0..iterations) |iteration| {
        const reference_real = reference[region][iteration][0];
        const reference_imaginary = reference[region][iteration][1];
        const next_delta_real = 2 * (reference_real * delta_real - reference_imaginary * delta_imaginary) +
            delta_real * delta_real - delta_imaginary * delta_imaginary + displacement[0];
        const next_delta_imaginary = 2 * (reference_real * delta_imaginary + reference_imaginary * delta_real) +
            2 * delta_real * delta_imaginary + displacement[1];
        delta_real = next_delta_real;
        delta_imaginary = next_delta_imaginary;
        const orbit_real = reference[region][iteration + 1][0] + delta_real;
        const orbit_imaginary = reference[region][iteration + 1][1] + delta_imaginary;
        const magnitude_squared = orbit_real * orbit_real + orbit_imaginary * orbit_imaginary;
        if (magnitude_squared <= escape_squared) continue;
        const smooth_count: f32 = @floatFromInt(iteration + 2);
        const smooth = smooth_count - @log2(@log(magnitude_squared) * 0.5);
        return .{
            .depth = smooth / depth_scale,
            .angle = std.math.atan2(orbit_imaginary, orbit_real),
        };
    }
    return boundedCoordinates(point, half);
}

pub fn coordinates(point: dvui.Point.Physical, half: f32, shot: Shot) Coordinates {
    return branchCoordinates(point, half, shot.region, shot.progress);
}

fn geometryDistance(first: Coordinates, second: Coordinates) f32 {
    const first_x = first.depth * @cos(first.angle);
    const first_y = first.depth * @sin(first.angle);
    const second_x = second.depth * @cos(second.angle);
    const second_y = second.depth * @sin(second.angle);
    const delta_x = first_x - second_x;
    const delta_y = first_y - second_y;
    return @sqrt(delta_x * delta_x + delta_y * delta_y);
}

fn regionWeight(route: Transition, region: usize) f32 {
    var weight: f32 = 0;
    if (route.front.region == region) weight += 1 - route.weight;
    if (route.incoming.region == region) weight += route.weight;
    return weight;
}

fn directCoordinates(
    point: dvui.Point.Physical,
    half: f32,
    region: usize,
    progress: f32,
) ?Coordinates {
    const point_x: f64 = @floatCast(point.x);
    const point_y: f64 = @floatCast(point.y);
    const view_half: f64 = @floatCast(half);
    const view_start_extent: f64 = @floatCast(start_extent);
    const view_zoom_log_scale: f64 = @floatCast(zoom_log_scale);
    const view_progress: f64 = @floatCast(progress);
    const scale = view_start_extent * @exp(-view_progress * view_zoom_log_scale);
    const parameter_real = centres[region][0] + point_x / view_half * scale;
    const parameter_imaginary = centres[region][1] + point_y / view_half * scale;
    const escape_limit: f64 = @floatCast(escape_squared);
    var orbit_real: f64 = 0;
    var orbit_imaginary: f64 = 0;
    for (0..iterations) |iteration| {
        const next_real = orbit_real * orbit_real - orbit_imaginary * orbit_imaginary + parameter_real;
        const next_imaginary = 2 * orbit_real * orbit_imaginary + parameter_imaginary;
        orbit_real = next_real;
        orbit_imaginary = next_imaginary;
        const magnitude_squared = orbit_real * orbit_real + orbit_imaginary * orbit_imaginary;
        if (magnitude_squared <= escape_limit) continue;
        const smooth_count: f64 = @floatFromInt(iteration + 2);
        const smooth = smooth_count - @log2(@log(magnitude_squared) * 0.5);
        return .{
            .depth = @floatCast(smooth / depth_scale),
            .angle = @floatCast(std.math.atan2(orbit_imaginary, orbit_real)),
        };
    }
    return null;
}
test "phase wraps the full route before float conversion" {
    try std.testing.expectEqual(@as(f32, 0), phase(0));
    try std.testing.expectEqual(@as(f32, 1), phase(cycle_seconds));
    try std.testing.expectEqual(@as(f32, 2), phase(cycle_seconds * 2));
    try std.testing.expectEqual(@as(f32, 0), phase(route_seconds));

    const repeated_routes: f64 = 100_000_000_000;
    const long_running_phase = phase(route_seconds * repeated_routes + 0.25);
    try std.testing.expectApproxEqAbs(phase(0.25), long_running_phase, 0.000001);
}

test "camera contracts monotonically to the close view" {
    const progresses = [_]f32{ 0, 0.2, 0.4, 0.6, 0.8, 1 };
    var previous_scale = cameraScale(progresses[0]);
    for (progresses[1..]) |progress| {
        const scale = cameraScale(progress);
        try std.testing.expect(scale < previous_scale);
        previous_scale = scale;
    }
    try std.testing.expectApproxEqAbs(end_extent, cameraScale(1), 0.0000001);
}

test "perturbation matches independent viewport orbits across regions and scales" {
    const half: f32 = 540;
    const progresses = [_]f32{ 0, 0.5, 0.84 };
    const samples = [3][3][2]f32{
        .{ .{ -0.1, -1 }, .{ -1.7, -1 }, .{ -1.7, -1 } },
        .{ .{ -1.7, -1 }, .{ 0, -1 }, .{ -1.5, -1 } },
        .{ .{ -1.7, -1 }, .{ -1.5, -1 }, .{ 0.5, -1 } },
    };

    for (centres, 0..) |_, region| {
        for (progresses, 0..) |progress, sample_index| {
            const normalized = samples[region][sample_index];
            const point = dvui.Point.Physical{
                .x = normalized[0] * half,
                .y = normalized[1] * half,
            };
            const direct = directCoordinates(point, half, region, progress);
            try std.testing.expect(direct != null);
            const perturbed = coordinates(point, half, .{ .region = region, .progress = progress });
            const expected = direct.?;
            try std.testing.expect(@abs(perturbed.depth - expected.depth) < 0.05);
            const angle_difference = std.math.atan2(
                @sin(perturbed.angle - expected.angle),
                @cos(perturbed.angle - expected.angle),
            );
            try std.testing.expect(@abs(angle_difference) < 0.15);
        }
    }
}

test "transition holds both cameras and blends rendered region weights" {
    const at_start = transition(transition_start);
    const during = transition((transition_start + 1) / 2);
    const near_end = transition(1 - 0.0001);
    const at_end = transition(1);

    try std.testing.expectEqual(@as(usize, 0), at_start.front.region);
    try std.testing.expectEqual(@as(usize, 1), at_start.incoming.region);
    try std.testing.expectEqual(@as(f32, 1), at_start.front.progress);
    try std.testing.expectEqual(at_start.front.progress, during.front.progress);
    try std.testing.expectEqual(@as(f32, 0), at_start.incoming.progress);
    try std.testing.expectEqual(at_start.incoming.progress, during.incoming.progress);
    try std.testing.expectEqual(@as(f32, 0), at_start.weight);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), during.weight, 0.0001);
    try std.testing.expect(near_end.weight > 0.999);

    const prior_region_weight = regionWeight(near_end, 1);
    const next_region_weight = regionWeight(at_end, 1);
    try std.testing.expectApproxEqAbs(prior_region_weight, next_region_weight, 0.001);
}

test "transition shot boundaries preserve the visible camera" {
    const half: f32 = 540;
    const point = dvui.Point.Physical{ .x = 135, .y = -216 };
    const epsilon: f32 = 0.0001;

    for (0..centres.len) |region_index| {
        const boundary: f32 = @floatFromInt(region_index + 1);
        const before = transition(boundary - epsilon);
        const exact = transition(boundary);
        const next_region = (region_index + 1) % centres.len;
        const before_visible = coordinates(point, half, before.incoming);
        const after_visible = coordinates(point, half, exact.front);

        try std.testing.expectEqual(next_region, exact.front.region);
        try std.testing.expectEqual(@as(f32, 0), exact.front.progress);
        try std.testing.expectEqual(@as(f32, 0), exact.weight);
        try std.testing.expect(geometryDistance(before_visible, after_visible) < 0.000001);
    }
}

test "bounded reference orbits and interior shortcuts return finite fallback" {
    const point = dvui.Point.Physical{ .x = 0, .y = 0 };
    const half: f32 = 540;
    const fallback = boundedCoordinates(point, half);
    for (centres, 0..) |_, region| {
        const result = branchCoordinates(point, half, region, 0);
        try std.testing.expect(std.math.isFinite(result.depth));
        try std.testing.expect(std.math.isFinite(result.angle));
        try std.testing.expectEqual(fallback.depth, result.depth);
        try std.testing.expectEqual(fallback.angle, result.angle);
    }

    try std.testing.expect(inMainCardioidOrPeriodTwo(0, 0));
    try std.testing.expect(inMainCardioidOrPeriodTwo(-1, 0));
    try std.testing.expect(!inMainCardioidOrPeriodTwo(-1.3, 0));
    const bulb_point = dvui.Point.Physical{ .x = half, .y = 0 };
    const bulb_fallback = branchCoordinates(bulb_point, half, 1, 0);
    const expected_bulb_fallback = boundedCoordinates(bulb_point, half);
    try std.testing.expectEqual(expected_bulb_fallback.depth, bulb_fallback.depth);
    try std.testing.expectEqual(expected_bulb_fallback.angle, bulb_fallback.angle);
}
