const std = @import("std");
const config_mod = @import("config.zig");
const lean_api = @import("lean_api.zig");
const state_mod = @import("state.zig");
const upstreams_mod = @import("upstreams.zig");
const log = @import("log.zig");

pub const Poller = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
    upstreams: ?*upstreams_mod.UpstreamManager,
    client: std.http.Client,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const config_mod.Config,
        state: *state_mod.AppState,
        upstreams: ?*upstreams_mod.UpstreamManager,
    ) Poller {
        var client = std.http.Client{ .allocator = allocator };

        // Configure timeouts if supported by the HTTP client version
        if (@hasField(std.http.Client, "connect_timeout")) {
            client.connect_timeout = config.request_timeout_ms * std.time.ns_per_ms;
        }
        if (@hasField(std.http.Client, "read_timeout")) {
            client.read_timeout = config.request_timeout_ms * std.time.ns_per_ms;
        }

        return Poller{
            .allocator = allocator,
            .config = config,
            .state = state,
            .upstreams = upstreams,
            .client = client,
        };
    }

    pub fn deinit(self: *Poller) void {
        self.client.deinit();
    }

    /// Main polling loop - runs forever
    pub fn run(self: *Poller) !void {
        log.info("Starting polling loop (interval: {d}ms)", .{self.config.poll_interval_ms});

        while (true) {
            const start_ns = std.time.nanoTimestamp();
            const now_ms = std.time.milliTimestamp();

            if (self.upstreams) |manager| {
                self.pollMulti(manager, now_ms) catch |err| {
                    log.err("Poll error: {s}", .{@errorName(err)});
                };
            } else {
                self.pollSingle(now_ms) catch |err| {
                    log.err("Poll error: {s}", .{@errorName(err)});
                };
            }

            const end_ns = std.time.nanoTimestamp();
            const delta_ms = @divTrunc(end_ns - start_ns, @as(i128, std.time.ns_per_ms));

            if (delta_ms > 0) {
                log.debug("Poll completed in {d}ms", .{delta_ms});
            }

            std.time.sleep(self.config.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Poll single upstream (legacy mode)
    fn pollSingle(self: *Poller, now_ms: i64) !void {
        var state_ssz: ?[]u8 = null;
        const slots = lean_api.fetchSlots(
            self.allocator,
            &self.client,
            self.config.lean_api_base_url,
            self.config.lean_api_path,
            &state_ssz,
            self.config.request_timeout_ms,
        ) catch |err| {
            var msg_buf = std.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();
            try msg_buf.writer().print("poll error: {s}", .{@errorName(err)});
            self.state.updateError(self.allocator, msg_buf.items, now_ms);
            return;
        };

        const latency_ms: u64 = 0; // We don't track latency accurately here
        self.state.updateSuccess(
            self.allocator,
            slots.justified_slot,
            slots.finalized_slot,
            latency_ms,
            now_ms,
            state_ssz,
        );

        if (state_ssz) |blob| {
            self.allocator.free(blob);
        }
    }

    /// Poll multiple upstreams with consensus
    fn pollMulti(self: *Poller, manager: *upstreams_mod.UpstreamManager, now_ms: i64) !void {
        // Poll all upstreams concurrently and get consensus.
        // self.client is passed for API compatibility but each upstream spawns its own
        // client internally to avoid shared-state hangs.
        var state_ssz: ?[]u8 = null;
        const consensus_slots = manager.pollUpstreams(&self.client, now_ms, self.config.request_timeout_ms, &state_ssz);

        if (consensus_slots) |slots| {
            const latency_ms: u64 = 0; // Latency not tracked in multi-upstream mode
            self.state.updateSuccess(
                self.allocator,
                slots.justified_slot,
                slots.finalized_slot,
                latency_ms,
                now_ms,
                state_ssz,
            );
            if (state_ssz) |blob| {
                self.allocator.free(blob);
            }
        } else {
            const error_msg = manager.getErrorSummary(self.allocator) catch "failed to get error summary";
            defer self.allocator.free(error_msg);
            self.state.updateError(self.allocator, error_msg, now_ms);
        }
    }
};

test "poller initialization" {
    var config = config_mod.Config{
        .bind_address = try std.testing.allocator.dupe(u8, "0.0.0.0"),
        .bind_port = 5555,
        .lean_api_base_url = try std.testing.allocator.dupe(u8, "http://localhost:5052"),
        .lean_api_path = try std.testing.allocator.dupe(u8, "/status"),
        .poll_interval_ms = 10_000,
        .request_timeout_ms = 5_000,
        .stale_after_ms = 30_000,
        .static_dir = null,
        .upstreams_config = null,
    };
    defer config.deinit(std.testing.allocator);

    var state = state_mod.AppState.init(null);
    defer state.deinit(std.testing.allocator);

    var poller = Poller.init(std.testing.allocator, &config, &state, null);
    defer poller.deinit();

    // Just verify it initializes without crashing
    try std.testing.expect(poller.client.allocator.ptr == std.testing.allocator.ptr);
}
