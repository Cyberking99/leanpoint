const std = @import("std");
const lean_api = @import("lean_api.zig");
const log = @import("log.zig");

pub const Upstream = struct {
    name: []const u8,
    base_url: []const u8,
    path: []const u8,
    // Track upstream health
    last_slots: ?lean_api.Slots,
    last_success_ms: i64,
    error_count: u64,
    last_error: ?[]const u8,
    /// From GET /lean/v0/admin/aggregator when supported; null if unknown
    is_aggregator: ?bool,
    /// From GET /lean/v0/fork_choice `head.slot` when available; null if unknown
    head_slot: ?u64,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, base_url: []const u8, path: []const u8) !Upstream {
        return Upstream{
            .name = try allocator.dupe(u8, name),
            .base_url = try allocator.dupe(u8, base_url),
            .path = try allocator.dupe(u8, path),
            .last_slots = null,
            .last_success_ms = 0,
            .error_count = 0,
            .last_error = null,
            .is_aggregator = null,
            .head_slot = null,
        };
    }

    pub fn deinit(self: *Upstream, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.base_url);
        allocator.free(self.path);
        if (self.last_error) |err| allocator.free(err);
    }
};

pub const UpstreamManager = struct {
    upstreams: std.ArrayList(Upstream),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) UpstreamManager {
        return UpstreamManager{
            .upstreams = std.ArrayList(Upstream).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UpstreamManager) void {
        for (self.upstreams.items) |*upstream| {
            upstream.deinit(self.allocator);
        }
        self.upstreams.deinit();
    }

    pub fn addUpstream(self: *UpstreamManager, name: []const u8, base_url: []const u8, path: []const u8) !void {
        const upstream = try Upstream.init(self.allocator, name, base_url, path);
        try self.upstreams.append(upstream);
    }

    /// Get detailed error summary of all upstreams
    pub fn getErrorSummary(self: *UpstreamManager, allocator: std.mem.Allocator) ![]const u8 {
        var failed_count: u32 = 0;
        const total = self.upstreams.items.len;

        for (self.upstreams.items) |upstream| {
            if (upstream.last_error != null) {
                failed_count += 1;
            }
        }

        if (failed_count == total) {
            var buf = std.ArrayList(u8).init(allocator);
            errdefer buf.deinit();

            try buf.appendSlice("all upstreams failed: ");
            for (self.upstreams.items, 0..) |upstream, i| {
                if (i > 0) try buf.appendSlice(", ");
                try buf.writer().print("{s} ({s})", .{ upstream.name, upstream.base_url });
            }
            return buf.toOwnedSlice();
        } else if (failed_count > 0) {
            return std.fmt.allocPrint(
                allocator,
                "{d}/{d} upstreams unreachable, no consensus",
                .{ failed_count, total },
            );
        } else {
            return allocator.dupe(u8, "no consensus reached among upstreams");
        }
    }

    /// Information needed to poll an upstream (snapshot without holding lock)
    const PollTarget = struct {
        index: usize,
        name: []const u8,
        base_url: []const u8,
        path: []const u8,
    };

    /// Result of polling a single upstream
    const PollResult = struct {
        index: usize,
        slots: ?lean_api.Slots,
        error_msg: ?[]u8,
        state_ssz: ?[]u8,
        is_aggregator: ?bool,
        head_slot: ?u64,
    };

    /// Shared work queue for bounded-concurrency poll workers.
    const PollWork = struct {
        allocator: std.mem.Allocator,
        targets: []const PollTarget,
        results: []PollResult,
        next: std.atomic.Value(usize),
        timeout_ms: u64,
    };

    fn pollUpstreamWorker(work: *PollWork) void {
        while (true) {
            const wi = work.next.fetchAdd(1, .monotonic);
            if (wi >= work.targets.len) break;
            work.results[wi] = pollOneUpstream(work.allocator, work.targets[wi], work.timeout_ms);
        }
    }

    /// One upstream: own HTTP client (no cross-thread sharing), socket timeouts in lean_api.
    fn pollOneUpstream(allocator: std.mem.Allocator, target: PollTarget, timeout_ms: u64) PollResult {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var state_ssz: ?[]u8 = null;
        const slots = lean_api.fetchSlots(
            allocator,
            &client,
            target.base_url,
            target.path,
            &state_ssz,
            timeout_ms,
        ) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch null;
            if (state_ssz) |s| allocator.free(s);
            log.warn("Upstream {s} ({s}) failed: {s}", .{ target.name, target.base_url, @errorName(err) });
            return .{
                .index = target.index,
                .slots = null,
                .error_msg = msg,
                .state_ssz = null,
                .is_aggregator = null,
                .head_slot = null,
            };
        };

        const sub_to = @max(2_000, timeout_ms / 2);
        const is_aggregator = lean_api.fetchAggregatorOptional(allocator, &client, target.base_url, sub_to);
        const head_slot = lean_api.fetchHeadSlotOptional(allocator, &client, target.base_url, sub_to);

        log.debug("Upstream {s}: justified={d}, finalized={d}", .{
            target.name, slots.justified_slot, slots.finalized_slot,
        });

        return .{
            .index = target.index,
            .slots = slots,
            .error_msg = null,
            .state_ssz = state_ssz,
            .is_aggregator = is_aggregator,
            .head_slot = head_slot,
        };
    }

    /// Poll upstreams with a bounded worker pool, then require 50%+ agreement on slots.
    ///
    /// Each worker pulls the next upstream from a queue (own `std.http.Client` per poll).
    /// This caps OS threads and parallel 16MB SSZ downloads when many nodes are configured,
    /// while `lean_api` socket timeouts still bound each hung TCP connection.
    pub fn pollUpstreams(
        self: *UpstreamManager,
        // Kept for API compatibility; each worker creates its own client.
        _: *std.http.Client,
        now_ms: i64,
        timeout_ms: u64,
        max_concurrency: u32,
        out_state_ssz: *?[]u8,
    ) ?lean_api.Slots {
        // Step 1: snapshot upstreams (brief lock)
        var targets = std.ArrayList(PollTarget).init(self.allocator);
        defer targets.deinit();

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.upstreams.items.len == 0) return null;

            for (self.upstreams.items, 0..) |upstream, i| {
                targets.append(PollTarget{
                    .index = i,
                    .name = upstream.name,
                    .base_url = upstream.base_url,
                    .path = upstream.path,
                }) catch continue;
            }
        }

        if (targets.items.len == 0) return null;

        const n = targets.items.len;
        const max_w = @min(max_concurrency, 256);
        const cap: usize = @max(1, @min(@as(usize, @intCast(max_w)), n));
        if (cap < n) {
            log.debug("Polling {d} upstreams with concurrency {d} (≤{d} OS threads this tick)", .{ n, cap, cap });
        }

        const results = self.allocator.alloc(PollResult, n) catch {
            log.warn("Failed to allocate poll result buffer", .{});
            return null;
        };
        defer {
            for (results) |result| {
                if (result.error_msg) |msg| self.allocator.free(msg);
                if (result.state_ssz) |blob| self.allocator.free(blob);
            }
            self.allocator.free(results);
        }

        var work = PollWork{
            .allocator = self.allocator,
            .targets = targets.items,
            .results = results,
            .next = std.atomic.Value(usize).init(0),
            .timeout_ms = timeout_ms,
        };

        const threads = self.allocator.alloc(std.Thread, cap) catch {
            log.warn("Failed to allocate thread handles for upstream poll", .{});
            return null;
        };
        defer self.allocator.free(threads);

        var spawned: usize = 0;

        for (0..cap) |_| {
            threads[spawned] = std.Thread.spawn(.{}, pollUpstreamWorker, .{&work}) catch |err| {
                log.warn("Failed to spawn poll worker ({d}/{d}): {s}", .{ spawned, cap, @errorName(err) });
                for (0..spawned) |j| threads[j].join();
                return null;
            };
            spawned += 1;
        }

        for (0..spawned) |j| threads[j].join();

        // Step 2: Update upstream states (brief lock)
        var slot_counts = std.AutoHashMap(u128, u32).init(self.allocator);
        defer slot_counts.deinit();

        var successful_polls: u32 = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (results, 0..) |*result, i| {
                if (result.index >= self.upstreams.items.len) continue;
                var upstream = &self.upstreams.items[result.index];

                if (result.slots) |slots| {
                    if (upstream.last_error) |old_err| {
                        self.allocator.free(old_err);
                        upstream.last_error = null;
                    }
                    upstream.error_count = 0;
                    upstream.last_slots = slots;
                    upstream.last_success_ms = now_ms;
                    upstream.is_aggregator = result.is_aggregator;
                    upstream.head_slot = result.head_slot;

                    const slot_key: u128 = (@as(u128, slots.justified_slot) << 64) | @as(u128, slots.finalized_slot);
                    const count = slot_counts.get(slot_key) orelse 0;
                    slot_counts.put(slot_key, count + 1) catch continue;

                    successful_polls += 1;
                } else {
                    upstream.error_count += 1;
                    if (upstream.last_error) |old_err| self.allocator.free(old_err);
                    upstream.last_error = result.error_msg;
                    upstream.is_aggregator = null;
                    upstream.head_slot = null;
                    results[i].error_msg = null; // ownership transferred
                }
            }
        }

        // Step 6: consensus (no lock needed)
        if (successful_polls == 0) {
            log.warn("No upstreams responded successfully", .{});
            return null;
        }

        const required_votes = (successful_polls + 1) / 2;

        var iter = slot_counts.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* >= required_votes) {
                const slot_key = entry.key_ptr.*;
                const justified_slot: u64 = @truncate(slot_key >> 64);
                const finalized_slot: u64 = @truncate(slot_key & 0xFFFFFFFFFFFFFFFF);

                for (results, 0..) |*res, i| {
                    if (res.slots) |s| {
                        if (s.justified_slot == justified_slot and s.finalized_slot == finalized_slot) {
                            if (res.state_ssz) |blob| {
                                out_state_ssz.* = blob;
                                results[i].state_ssz = null;
                                break;
                            }
                        }
                    }
                }

                log.info("Consensus reached: justified={d}, finalized={d} ({d}/{d} upstreams)", .{
                    justified_slot,
                    finalized_slot,
                    entry.value_ptr.*,
                    successful_polls,
                });
                return lean_api.Slots{
                    .justified_slot = justified_slot,
                    .finalized_slot = finalized_slot,
                };
            }
        }

        log.warn("No consensus reached among {d} responding upstreams", .{successful_polls});
        return null;
    }
};

test "upstream manager basic operations" {
    var manager = UpstreamManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.addUpstream("test1", "http://localhost:5052", "/status");
    try manager.addUpstream("test2", "http://localhost:5053", "/status");

    try std.testing.expectEqual(@as(usize, 2), manager.upstreams.items.len);
}
