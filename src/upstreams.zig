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

    pub fn init(allocator: std.mem.Allocator, name: []const u8, base_url: []const u8, path: []const u8) !Upstream {
        return Upstream{
            .name = try allocator.dupe(u8, name),
            .base_url = try allocator.dupe(u8, base_url),
            .path = try allocator.dupe(u8, path),
            .last_slots = null,
            .last_success_ms = 0,
            .error_count = 0,
            .last_error = null,
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
            // All upstreams failed
            var buf = std.ArrayList(u8).init(allocator);
            errdefer buf.deinit();

            try buf.appendSlice("all upstreams failed: ");
            for (self.upstreams.items, 0..) |upstream, i| {
                if (i > 0) try buf.appendSlice(", ");
                try buf.writer().print("{s} ({s})", .{ upstream.name, upstream.base_url });
            }
            return buf.toOwnedSlice();
        } else if (failed_count > 0) {
            // Some upstreams failed
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
        error_msg: ?[]const u8,
        state_ssz: ?[]u8,
    };

    /// Poll all upstreams and return consensus slots if 50%+ agree
    /// Thread-safe: minimizes critical section by only locking during state updates
    pub fn pollUpstreams(
        self: *UpstreamManager,
        client: *std.http.Client,
        now_ms: i64,
        out_state_ssz: *?[]u8,
    ) ?lean_api.Slots {
        // Step 1: Create snapshot of upstreams to poll (without holding lock)
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

        // Step 2: Poll all upstreams WITHOUT holding the lock (I/O can be slow!)
        var results = std.ArrayList(PollResult).init(self.allocator);
        defer {
            // Clean up any error messages or SSZ blobs that weren't transferred
            for (results.items) |result| {
                if (result.error_msg) |msg| self.allocator.free(msg);
                if (result.state_ssz) |blob| self.allocator.free(blob);
            }
            results.deinit();
        }

        for (targets.items) |target| {
            var state_ssz: ?[]u8 = null;
            const slots = lean_api.fetchSlots(
                self.allocator,
                client,
                target.base_url,
                target.path,
                &state_ssz,
            ) catch |err| {
                if (state_ssz) |blob| self.allocator.free(blob);
                const error_msg = std.fmt.allocPrint(
                    self.allocator,
                    "{s}",
                    .{@errorName(err)},
                ) catch self.allocator.dupe(u8, "allocation_failed") catch null;

                log.warn("Upstream {s} ({s}) failed: {s}", .{ target.name, target.base_url, @errorName(err) });

                results.append(PollResult{
                    .index = target.index,
                    .slots = null,
                    .error_msg = error_msg,
                    .state_ssz = null,
                }) catch continue;
                continue;
            };

            log.debug("Upstream {s}: justified={d}, finalized={d}", .{ target.name, slots.justified_slot, slots.finalized_slot });

            results.append(PollResult{
                .index = target.index,
                .slots = slots,
                .error_msg = null,
                .state_ssz = state_ssz,
            }) catch continue;
        }

        // Step 3: Update upstream states with results (brief lock)
        var slot_counts = std.AutoHashMap(u128, u32).init(self.allocator);
        defer slot_counts.deinit();

        var successful_polls: u32 = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (results.items, 0..) |*result, i| {
                if (result.index >= self.upstreams.items.len) continue;
                var upstream = &self.upstreams.items[result.index];

                    if (result.slots) |slots| {
                    // Success: clear error and update state
                    if (upstream.last_error) |old_err| {
                        self.allocator.free(old_err);
                        upstream.last_error = null;
                    }
                    upstream.error_count = 0; // reset on success so UI reflects current health
                    upstream.last_slots = slots;
                    upstream.last_success_ms = now_ms;

                    // Track for consensus
                    const slot_key: u128 = (@as(u128, slots.justified_slot) << 64) | @as(u128, slots.finalized_slot);
                    const count = slot_counts.get(slot_key) orelse 0;
                    slot_counts.put(slot_key, count + 1) catch continue;

                    successful_polls += 1;
                } else {
                    // Error: update error state
                    upstream.error_count += 1;

                    if (upstream.last_error) |old_err| {
                        self.allocator.free(old_err);
                    }
                    upstream.last_error = result.error_msg;

                    // Mark as transferred to prevent double-free in defer
                    results.items[i].error_msg = null;
                }
            }
        }

        // Step 4: Calculate consensus (no lock needed)
        if (successful_polls == 0) {
            log.warn("No upstreams responded successfully", .{});
            return null;
        }

        const required_votes = (successful_polls + 1) / 2; // Ceiling division

        var iter = slot_counts.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* >= required_votes) {
                const slot_key = entry.key_ptr.*;
                const justified_slot: u64 = @truncate(slot_key >> 64);
                const finalized_slot: u64 = @truncate(slot_key & 0xFFFFFFFFFFFFFFFF);

                // Find a matching upstream result and transfer SSZ ownership to caller.
                for (results.items, 0..) |*res, i| {
                    if (res.slots) |s| {
                        if (s.justified_slot == justified_slot and s.finalized_slot == finalized_slot) {
                            if (res.state_ssz) |blob| {
                                out_state_ssz.* = blob;
                                // Prevent defer block from freeing it.
                                results.items[i].state_ssz = null;
                                break;
                            }
                        }
                    }
                }

                const result = lean_api.Slots{
                    .justified_slot = justified_slot,
                    .finalized_slot = finalized_slot,
                };
                log.info("Consensus reached: justified={d}, finalized={d} ({d}/{d} upstreams)", .{
                    result.justified_slot,
                    result.finalized_slot,
                    entry.value_ptr.*,
                    successful_polls,
                });
                return result;
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
