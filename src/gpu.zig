//! GPU texture folds, matching `folding.fold` on the CPU. One fullscreen triangle into the swapchain,
//! its fragment shader running the same fold the CPU version does, recorded
//! into dvui's command buffer before dvui draws the panel on top. dvui's final
//! pass loads, so the tunnel stays under the UI.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
/// The backend's own c module instance: SDL types from another instance of
/// the module are distinct types to Zig even though they are identical.
const c = SDLBackend.c;
const folding = @import("fold.zig");
const mandelbrot = @import("mandelbrot.zig");

/// The backend's own message for the last shader failure, so it can be shown in
/// the window when the tunnel falls back to the CPU.
pub var last_error: [1024]u8 = @splat(0);

fn copyError() void {
    const message = std.mem.span(c.SDL_GetError());
    const length = @min(message.len, last_error.len - 1);
    @memcpy(last_error[0..length], message[0..length]);
    last_error[length] = 0;
}

/// Mirrors `Uniforms` in the shader, field for field.
pub const Uniforms = extern struct {
    size: [2]f32,
    canvas: [2]f32,
    still_min: [3][2]f32,
    still_max: [3][2]f32,
    still_count: f32,
    ring_count: f32,
    heart: f32,
    kick_push: f32,
    mirrors: f32,
    rush_phase: f32,
    turn_phase: f32,
    spin_rate: f32,
    spin: f32,
    ring_shift: f32,
    calm: f32,
    fold_kind: f32,
    continuous: f32,
    zoom_phase: f32,
};

const vertex_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\};
    \\
    \\vertex VertexOut main0(uint vertex_id [[vertex_id]]) {
    \\    float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    \\    float2 corner = corners[vertex_id];
    \\    VertexOut out;
    \\    out.position = float4(corner, 0.0, 1.0);
    \\    out.uv = (corner + 1.0) * 0.5;
    \\    return out;
    \\}
    \\
;

const reference_source = blk: {
    @setEvalBranchQuota(2_000_000);
    var source: []const u8 = "";
    for (mandelbrot.reference) |orbit| {
        for (orbit) |reference_point| {
            source = source ++ std.fmt.comptimePrint(
                "    float2({d}, {d}),\n",
                .{ reference_point[0], reference_point[1] },
            );
        }
    }
    break :blk source;
};
const centre_source = blk: {
    var source: []const u8 = "";
    for (mandelbrot.centres) |centre| {
        source = source ++ std.fmt.comptimePrint(
            "    float2({d}, {d}),\n",
            .{ centre[0], centre[1] },
        );
    }
    break :blk source;
};

const fragment_source = std.fmt.comptimePrint(
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\constant int mandelbrot_iterations = {d};
    \\constant int mandelbrot_region_count = {d};
    \\constant float mandelbrot_escape_squared = {d};
    \\constant float mandelbrot_depth_scale = {d};
    \\constant float mandelbrot_start_extent = {d};
    \\constant float mandelbrot_zoom_log_scale = {d};
    \\constant float mandelbrot_transition_start = {d};
    \\constant int mandelbrot_reference_count = {d};
    \\constant float2 mandelbrot_centres[{d}] = {{
    \\{s}
    \\}};
    \\constant float2 mandelbrot_reference[{d}] = {{
    \\{s}
    \\}};
    \\
, .{
    mandelbrot.iterations,
    mandelbrot.centres.len,
    mandelbrot.escape_squared,
    mandelbrot.depth_scale,
    mandelbrot.start_extent,
    mandelbrot.zoom_log_scale,
    mandelbrot.transition_start,
    mandelbrot.reference[0].len,
    mandelbrot.centres.len,
    centre_source,
    mandelbrot.reference.len * mandelbrot.reference[0].len,
    reference_source,
}) ++
    \\struct Uniforms {
    \\    float2 size;
    \\    float2 canvas;
    \\    float2 still_min[3];
    \\    float2 still_max[3];
    \\    float still_count;
    \\    float ring_count;
    \\    float heart;
    \\    float kick_push;
    \\    float mirrors;
    \\    float rush_phase;
    \\    float turn_phase;
    \\    float spin_rate;
    \\    float spin;
    \\    float ring_shift;
    \\    float calm;
    \\    float fold_kind;
    \\    float continuous;
    \\    float zoom_phase;
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\};
    \\
    \\static float bounced(float v, float extent) {
    \\    if (extent <= 0.0) return v;
    \\    float period = 2.0 * extent;
    \\    float folded = fmod(v, period);
    \\    if (folded < 0.0) folded += period;
    \\    if (folded > extent) folded = extent * 2.0 - folded;
    \\    return folded;
    \\}
    \\
    \\static float still_strength(float2 p, constant Uniforms &u) {
    \\    float strength = 1.0;
    \\    for (int i = 0; i < 3; ++i) {
    \\        if (float(i) >= u.still_count) break;
    \\        float dx = max(max(u.still_min[i].x - p.x, p.x - u.still_max[i].x), 0.0);
    \\        float dy = max(max(u.still_min[i].y - p.y, p.y - u.still_max[i].y), 0.0);
    \\        float t = clamp(sqrt(dx * dx + dy * dy) / u.calm, 0.0, 1.0);
    \\        strength = min(strength, t * t * (3.0 - 2.0 * t));
    \\    }
    \\    return strength;
    \\}
    \\
    \\static float2 complex_multiply(float2 left, float2 right) {
    \\    return float2(left.x * right.x - left.y * right.y,
    \\                  left.x * right.y + left.y * right.x);
    \\}
    \\
    \\static float2 mandelbrot_fallback(float2 q, float half_min) {
    \\    float depth = float(mandelbrot_iterations) / mandelbrot_depth_scale;
    \\    depth += length(q) / half_min * 0.25;
    \\    return float2(depth, atan2(q.y, q.x));
    \\}
    \\
    \\static float2 mandelbrot_branch(float2 q, float half_min, int region, float progress) {
    \\    float2 point = q / half_min;
    \\    float2 dc = point * mandelbrot_start_extent * exp(-progress * mandelbrot_zoom_log_scale);
    \\    float2 c = mandelbrot_centres[region] + dc;
    \\    float cardioid_x = c.x - 0.25;
    \\    float cardioid_q = cardioid_x * cardioid_x + c.y * c.y;
    \\    if (cardioid_q * (cardioid_q + cardioid_x) <= 0.25 * c.y * c.y) return mandelbrot_fallback(q, half_min);
    \\    float bulb_x = c.x + 1.0;
    \\    if (bulb_x * bulb_x + c.y * c.y <= 0.0625) return mandelbrot_fallback(q, half_min);
    \\    int reference_base = region * mandelbrot_reference_count;
    \\    float2 delta = float2(0.0);
    \\    float2 z;
    \\    for (int iteration = 0; iteration < mandelbrot_iterations; ++iteration) {
    \\        float2 reference_point = mandelbrot_reference[reference_base + iteration];
    \\        float2 linear = complex_multiply(2.0 * reference_point, delta);
    \\        float2 quadratic = complex_multiply(delta, delta);
    \\        float2 next_delta = linear + quadratic + dc;
    \\        z = mandelbrot_reference[reference_base + iteration + 1] + next_delta;
    \\        delta = next_delta;
    \\        float magnitude_squared = dot(z, z);
    \\        if (magnitude_squared <= mandelbrot_escape_squared) continue;
    \\        float smooth = float(iteration + 2) - log2(log(magnitude_squared) * 0.5);
    \\        float depth = smooth / mandelbrot_depth_scale;
    \\        return float2(depth, atan2(z.y, z.x));
    \\    }
    \\    return mandelbrot_fallback(q, half_min);
    \\}
    \\
    \\static float mandelbrot_travel_phase(constant Uniforms &u) {
    \\    float travel_phase = fmod(u.zoom_phase, float(mandelbrot_region_count));
    \\    if (travel_phase < 0.0) travel_phase += float(mandelbrot_region_count);
    \\    return travel_phase;
    \\}
    \\
    \\static float2 mandelbrot_coordinates(float2 q, float half_min, constant Uniforms &u, bool incoming) {
    \\    float travel_phase = mandelbrot_travel_phase(u);
    \\    int shot = int(floor(travel_phase));
    \\    int region = shot % mandelbrot_region_count;
    \\    float progress = travel_phase - float(shot);
    \\    float camera_progress = smoothstep(0.0, mandelbrot_transition_start, progress);
    \\    int next_region = (region + 1) % mandelbrot_region_count;
    \\    int selected_region = incoming ? next_region : region;
    \\    float selected_progress = incoming ? 0.0 : camera_progress;
    \\    return mandelbrot_branch(q, half_min, selected_region, selected_progress);
    \\}
    \\
    \\static float2 bend(float2 p, constant Uniforms &u, bool incoming) {
    \\    float strength = still_strength(p, u);
    \\    if (strength <= 0.0) return p;
    \\    float2 centre = u.size * 0.5;
    \\    float2 q = p - centre;
    \\    float half_min = min(u.canvas.x, u.canvas.y) * 0.5;
    \\    float radius = length(q);
    \\    float2 mapped = u.fold_kind > 2.5
    \\        ? mandelbrot_coordinates(q, half_min, u, incoming)
    \\        : float2(u.fold_kind > 1.5 ? radius / half_min : log(radius / half_min + 0.01), atan2(q.y, q.x));
    \\
    \\    float depth = mapped.x * u.ring_count - u.rush_phase - u.heart * u.kick_push;
    \\    float level = floor(depth);
    \\    float within = clamp(depth - level, 0.0, 1.0);
    \\    float eased = within * within * (3.0 - 2.0 * within);
    \\    float parity = fmod(level, 2.0);
    \\    if (parity < 0.0) parity += 2.0;
    \\    float band = u.fold_kind > 1.5 && u.fold_kind < 2.5 && u.continuous < 0.5
    \\        ? eased : (parity < 1.0 ? eased : 1.0 - eased);
    \\
    \\    float turned_angle = mapped.y + u.turn_phase * u.spin_rate + depth * u.ring_shift;
    \\    float angle = turned_angle;
    \\    if (u.mirrors > 1.0) {
    \\        float sector = 6.28318530718 / u.mirrors;
    \\        float within_sector = fmod(turned_angle, sector);
    \\        if (within_sector < 0.0) within_sector += sector;
    \\        angle = min(within_sector, sector - within_sector);
    \\    }
    \\
    \\    float lane_band = band;
    \\    if (u.fold_kind <= 2.5 && u.continuous < 0.5) {
    \\        lane_band = fmod(band, 1.0);
    \\        if (lane_band < 0.0) lane_band += 1.0;
    \\    }
    \\    float reach = half_min * lane_band;
    \\    float2 local = float2(abs(cos(angle)) * reach, abs(sin(angle)) * reach);
    \\
    \\    float turned = (u.fold_kind > 2.5 ? depth : level) * u.spin;
    \\    float2 source = centre + float2(local.x * cos(turned) - local.y * sin(turned),
    \\                                    local.x * sin(turned) + local.y * cos(turned));
    \\    float2 wrapped = float2(bounced(source.x, u.size.x), bounced(source.y, u.size.y));
    \\    return mix(p, wrapped, strength);
    \\}
    \\
    \\fragment float4 main0(VertexOut in [[stage_in]],
    \\                      constant Uniforms &u [[buffer(0)]],
    \\                      texture2d<float> picture [[texture(0)]],
    \\                      sampler picked [[sampler(0)]]) {
    \\    float2 p = float2(in.uv.x * u.size.x, in.uv.y * u.size.y);
    \\    if (u.fold_kind > 2.5) {
    \\        float4 front = picture.sample(picked, bend(p, u, false) / u.size);
    \\        float route_phase = mandelbrot_travel_phase(u);
    \\        float progress = route_phase - floor(route_phase);
    \\        float weight = smoothstep(mandelbrot_transition_start, 1.0, progress);
    \\        if (weight <= 0.0) return front;
    \\        float4 incoming = picture.sample(picked, bend(p, u, true) / u.size);
    \\        return mix(front, incoming, weight);
    \\    }
    \\
    \\    // The fold is evaluated per pixel, so a lane seam or a squeezed band
    \\    // inside one pixel is a hard step. Nine taps across the pixel average it,
    \\    // which is what the CPU grid does by interpolating between vertexes.
    \\    float4 blended = float4(0.0);
    \\    for (int row = 0; row < 3; ++row) {
    \\        for (int column = 0; column < 3; ++column) {
    \\            float2 offset = float2(float(column) - 1.0, float(row) - 1.0) * (1.0 / 3.0);
    \\            blended += picture.sample(picked, bend(p + offset, u, false) / u.size);
    \\        }
    \\    }
    \\    return blended * (1.0 / 9.0);
    \\}
    \\
;

pub const Painter = struct {
    backend: *SDLBackend,
    pipeline: *c.SDL_GPUGraphicsPipeline,

    pub fn init(backend: *SDLBackend) !Painter {
        const device = backend.device;
        const vertex = backend.loadShader(vertex_source, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0, 0, 0) catch |err| {
            copyError();
            return err;
        };
        defer c.SDL_ReleaseGPUShader(device, vertex);
        const fragment = backend.loadShader(fragment_source, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 0, 0, 1) catch |err| {
            copyError();
            return err;
        };
        defer c.SDL_ReleaseGPUShader(device, fragment);

        var target = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        target.format = c.SDL_GetGPUSwapchainTextureFormat(device, backend.window);

        var info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        info.vertex_shader = vertex;
        info.fragment_shader = fragment;
        info.target_info.num_color_targets = 1;
        info.target_info.color_target_descriptions = &target;
        info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;

        const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &info) orelse {
            copyError();
            return error.PipelineCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        return .{ .backend = backend, .pipeline = pipeline };
    }

    pub fn deinit(self: *Painter) void {
        c.SDL_ReleaseGPUGraphicsPipeline(self.backend.device, self.pipeline);
    }

    /// Draws the folded picture over the whole swapchain. Must be recorded
    /// before dvui begins its pass, which loads what is already there.
    pub fn paint(
        self: *Painter,
        cmd: *c.SDL_GPUCommandBuffer,
        swapchain: *c.SDL_GPUTexture,
        picture: dvui.Texture,
        values: Uniforms,
    ) !void {
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &values, @sizeOf(Uniforms));

        var target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        target.texture = swapchain;
        target.load_op = c.SDL_GPU_LOADOP_LOAD;
        target.store_op = c.SDL_GPU_STOREOP_STORE;

        const pass = c.SDL_BeginGPURenderPass(cmd, &target, 1, null) orelse return error.RenderPass;
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);

        const sampled: *const Sampled = @ptrCast(@alignCast(picture.ptr));
        var texture_binding = c.SDL_GPUTextureSamplerBinding{
            .texture = sampled.texture,
            .sampler = self.backend.linear_clamp_clamp,
        };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &texture_binding, 1);

        c.SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
        c.SDL_EndGPURenderPass(pass);
    }

    /// Same draw, with the handles the frame loop carries as opaque pointers.
    pub fn paintOpaque(
        self: *Painter,
        cmd: ?*anyopaque,
        swapchain: ?*anyopaque,
        picture: dvui.Texture,
        values: Uniforms,
    ) !void {
        const command: *c.SDL_GPUCommandBuffer = @ptrCast(@alignCast(cmd orelse return error.NoCommandBuffer));
        const target: *c.SDL_GPUTexture = @ptrCast(@alignCast(swapchain orelse return error.NoSwapchain));
        return self.paint(command, target, picture, values);
    }

    pub fn pack(
        size: dvui.Size.Physical,
        canvas: dvui.Size.Physical,
        stills: []const dvui.Rect.Physical,
        lens: folding.Lens,
    ) Uniforms {
        var still_min: [3][2]f32 = @splat(.{ 0, 0 });
        var still_max: [3][2]f32 = @splat(.{ 0, 0 });
        const count = @min(stills.len, still_min.len);
        for (stills[0..count], 0..) |rect, at| {
            still_min[at] = .{ rect.x, rect.y };
            still_max[at] = .{ rect.x + rect.w, rect.y + rect.h };
        }
        return .{
            .size = .{ size.w, size.h },
            .canvas = .{ canvas.w, canvas.h },
            .still_min = still_min,
            .still_max = still_max,
            .still_count = @floatFromInt(count),
            .ring_count = lens.ring_count,
            .heart = lens.heart,
            .kick_push = lens.kick_push,
            .mirrors = lens.mirrors,
            .rush_phase = lens.rush_phase,
            .turn_phase = lens.turn_phase,
            .spin_rate = lens.spin_rate,
            .spin = lens.spin,
            .ring_shift = lens.ring_shift,
            .calm = lens.calm,
            .fold_kind = switch (lens.fold) {
                .tunnel => 1,
                .rings => 2,
                .mandelbrot => 3,
            },
            .continuous = if (lens.continuous) 1 else 0,
            .zoom_phase = lens.zoom_phase,
        };
    }
};

const Sampled = struct {
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
};
