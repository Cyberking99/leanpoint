const std = @import("std");
const upstreams_mod = @import("upstreams.zig");

pub const Snapshot = struct {
    justified_slot: u64,
    finalized_slot: u64,
    last_updated_ms: i64,
    last_success_ms: i64,
    last_latency_ms: u64,
    error_count: u64,
    last_error: ?[]u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.last_error) |err_msg| allocator.free(err_msg);
    }
};

pub const UpstreamInfo = struct {
    name: []u8,
    url: []u8,
    path: []u8,
    healthy: bool,
    last_success_ms: ?i64,
    error_count: u64,
    last_error: ?[]u8,
    last_justified_slot: ?u64,
    last_finalized_slot: ?u64,
    is_aggregator: ?bool,
    head_slot: ?u64,

    pub fn deinit(self: *UpstreamInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
        allocator.free(self.path);
        if (self.last_error) |err| allocator.free(err);
    }
};

pub const ConsensusInfo = struct {
    total_upstreams: usize,
    responding_upstreams: usize,
    has_consensus: bool,
};

pub const UpstreamsData = struct {
    upstreams: []UpstreamInfo,
    consensus: ConsensusInfo,

    pub fn deinit(self: *UpstreamsData, allocator: std.mem.Allocator) void {
        for (self.upstreams) |*upstream| {
            upstream.deinit(allocator);
        }
        allocator.free(self.upstreams);
    }
};

pub const AppState = struct {
    mutex: std.Thread.Mutex = .{},
    justified_slot: u64 = 0,
    finalized_slot: u64 = 0,
    last_updated_ms: i64 = 0,
    last_success_ms: i64 = 0,
    last_latency_ms: u64 = 0,
    error_count: u64 = 0,
    last_error: ?[]u8 = null,
    last_finalized_state_ssz: ?[]u8 = null,
    upstream_manager: ?*upstreams_mod.UpstreamManager = null,

    pub fn init(upstream_manager: ?*upstreams_mod.UpstreamManager) AppState {
        return AppState{
            .upstream_manager = upstream_manager,
        };
    }

    pub fn deinit(self: *AppState, allocator: std.mem.Allocator) void {
        if (self.last_error) |msg| allocator.free(msg);
        self.last_error = null;
        if (self.last_finalized_state_ssz) |state_ssz| allocator.free(state_ssz);
        self.last_finalized_state_ssz = null;
    }

    pub fn updateSuccess(
        self: *AppState,
        allocator: std.mem.Allocator,
        justified_slot: u64,
        finalized_slot: u64,
        latency_ms: u64,
        now_ms: i64,
        state_ssz: ?[]const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.justified_slot = justified_slot;
        self.finalized_slot = finalized_slot;
        self.last_updated_ms = now_ms;
        self.last_success_ms = now_ms;
        self.last_latency_ms = latency_ms;
        self.error_count = 0; // reset on success so UI reflects current health
        if (self.last_error) |msg| allocator.free(msg);
        self.last_error = null;

        if (state_ssz) |bytes| {
            if (self.last_finalized_state_ssz) |old_state| {
                allocator.free(old_state);
            }
            self.last_finalized_state_ssz = allocator.dupe(u8, bytes) catch self.last_finalized_state_ssz;
        }
    }

    pub fn updateError(
        self: *AppState,
        allocator: std.mem.Allocator,
        msg: []const u8,
        now_ms: i64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_updated_ms = now_ms;
        self.error_count += 1;
        if (self.last_error) |old| allocator.free(old);
        self.last_error = allocator.dupe(u8, msg) catch null;
    }

    pub fn snapshot(self: *AppState, allocator: std.mem.Allocator) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        var err_copy: ?[]u8 = null;
        if (self.last_error) |msg| {
            err_copy = try allocator.dupe(u8, msg);
        }
        return Snapshot{
            .justified_slot = self.justified_slot,
            .finalized_slot = self.finalized_slot,
            .last_updated_ms = self.last_updated_ms,
            .last_success_ms = self.last_success_ms,
            .last_latency_ms = self.last_latency_ms,
            .error_count = self.error_count,
            .last_error = err_copy,
        };
    }

    /// Returns a freshly allocated copy of the last finalized state SSZ, if any.
    /// Caller is responsible for freeing the returned slice.
    pub fn copyFinalizedStateSSZ(self: *AppState, allocator: std.mem.Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.last_finalized_state_ssz) |state_ssz| {
            const copy = try allocator.dupe(u8, state_ssz);
            return copy;
        }
        return null;
    }

    pub fn getUpstreamsData(self: *AppState, allocator: std.mem.Allocator) !UpstreamsData {
        if (self.upstream_manager) |manager| {
            manager.mutex.lock();
            defer manager.mutex.unlock();

            var upstreams_info = try allocator.alloc(UpstreamInfo, manager.upstreams.items.len);
            errdefer allocator.free(upstreams_info);

            var responding: usize = 0;
            for (manager.upstreams.items, 0..) |*upstream, i| {
                const healthy = upstream.last_success_ms > 0 and upstream.last_slots != null;
                if (healthy) responding += 1;

                var last_error_copy: ?[]u8 = null;
                if (upstream.last_error) |err| {
                    last_error_copy = try allocator.dupe(u8, err);
                }

                upstreams_info[i] = UpstreamInfo{
                    .name = try allocator.dupe(u8, upstream.name),
                    .url = try allocator.dupe(u8, upstream.base_url),
                    .path = try allocator.dupe(u8, upstream.path),
                    .healthy = healthy,
                    .last_success_ms = if (upstream.last_success_ms > 0) upstream.last_success_ms else null,
                    .error_count = upstream.error_count,
                    .last_error = last_error_copy,
                    .last_justified_slot = if (upstream.last_slots) |slots| slots.justified_slot else null,
                    .last_finalized_slot = if (upstream.last_slots) |slots| slots.finalized_slot else null,
                    .is_aggregator = upstream.is_aggregator,
                    .head_slot = upstream.head_slot,
                };
            }

            const total = manager.upstreams.items.len;
            const has_consensus = responding > 0 and (responding * 100 / total) > 50;

            return UpstreamsData{
                .upstreams = upstreams_info,
                .consensus = ConsensusInfo{
                    .total_upstreams = total,
                    .responding_upstreams = responding,
                    .has_consensus = has_consensus,
                },
            };
        } else {
            // No upstream manager (single upstream mode)
            return UpstreamsData{
                .upstreams = try allocator.alloc(UpstreamInfo, 0),
                .consensus = ConsensusInfo{
                    .total_upstreams = 0,
                    .responding_upstreams = 0,
                    .has_consensus = false,
                },
            };
        }
    }
};

test "AppState updateSuccess" {
    var state = AppState{};
    defer state.deinit(std.testing.allocator);

    state.updateSuccess(std.testing.allocator, 100, 99, 50, 1000, null);

    try std.testing.expectEqual(@as(u64, 100), state.justified_slot);
    try std.testing.expectEqual(@as(u64, 99), state.finalized_slot);
    try std.testing.expectEqual(@as(i64, 1000), state.last_updated_ms);
    try std.testing.expectEqual(@as(i64, 1000), state.last_success_ms);
    try std.testing.expectEqual(@as(u64, 50), state.last_latency_ms);
    try std.testing.expectEqual(@as(u64, 0), state.error_count);
    try std.testing.expect(state.last_error == null);
}

test "AppState updateError" {
    var state = AppState{};
    defer state.deinit(std.testing.allocator);

    state.updateError(std.testing.allocator, "test error", 2000);

    try std.testing.expectEqual(@as(i64, 2000), state.last_updated_ms);
    try std.testing.expectEqual(@as(u64, 1), state.error_count);
    try std.testing.expect(state.last_error != null);
    if (state.last_error) |msg| {
        try std.testing.expectEqualStrings("test error", msg);
    }
}

test "AppState snapshot" {
    var state = AppState{};
    defer state.deinit(std.testing.allocator);

    state.updateSuccess(std.testing.allocator, 200, 199, 75, 3000, null);

    var snapshot = try state.snapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 200), snapshot.justified_slot);
    try std.testing.expectEqual(@as(u64, 199), snapshot.finalized_slot);
    try std.testing.expectEqual(@as(i64, 3000), snapshot.last_updated_ms);
    try std.testing.expectEqual(@as(i64, 3000), snapshot.last_success_ms);
    try std.testing.expectEqual(@as(u64, 75), snapshot.last_latency_ms);
}

test "AppState updateError clears previous error" {
    var state = AppState{};
    defer state.deinit(std.testing.allocator);

    state.updateError(std.testing.allocator, "first error", 1000);
    state.updateError(std.testing.allocator, "second error", 2000);

    try std.testing.expectEqual(@as(u64, 2), state.error_count);
    if (state.last_error) |msg| {
        try std.testing.expectEqualStrings("second error", msg);
    }
}

test "AppState updateSuccess clears error" {
    var state = AppState{};
    defer state.deinit(std.testing.allocator);

    state.updateError(std.testing.allocator, "error message", 1000);
    try std.testing.expectEqual(@as(u64, 1), state.error_count);

    state.updateSuccess(std.testing.allocator, 100, 99, 50, 2000, null);
    try std.testing.expect(state.last_error == null);
    try std.testing.expectEqual(@as(u64, 0), state.error_count); // reset on success
}
