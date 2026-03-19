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
        error_msg: ?[]const u8,
        state_ssz: ?[]u8,
    };

    // ---------------------------------------------------------------------------
    // Concurrent per-upstream polling context.
    //
    // Zig 0.14's std.http.Client does not expose connect_timeout / read_timeout,
    // so a single hung TCP connection would stall the entire sequential poll loop
    // forever.  The fix: spawn one thread per upstream and wait for all of them
    // behind a hard deadline (request_timeout_ms).  If an upstream doesn't answer
    // in time its thread is detached; it will free its own memory when it
    // eventually returns (reference-counted via an atomic counter).
    // ---------------------------------------------------------------------------

    /// Heap-allocated context shared between the spawner and the worker thread.
    /// Reference-counted (starts at 2: one for the spawner, one for the thread).
    /// Freed automatically when the last holder calls release().
    const PollCtx = struct {
        allocator: std.mem.Allocator,
        index: usize,
        // owned copies of the target strings so the thread stays safe even after
        // a timeout when the spawner has already moved on.
        base_url: []u8,
        path: []u8,
        name: []u8,
        // written by the thread, read by the spawner after deadline
        done: std.atomic.Value(bool),
        slots: ?lean_api.Slots,
        error_msg: ?[]u8,
        state_ssz: ?[]u8,
        ref_count: std.atomic.Value(u32),

        fn create(
            allocator: std.mem.Allocator,
            index: usize,
            name: []const u8,
            base_url: []const u8,
            path: []const u8,
        ) !*PollCtx {
            const ctx = try allocator.create(PollCtx);
            ctx.* = .{
                .allocator = allocator,
                .index = index,
                .name = try allocator.dupe(u8, name),
                .base_url = try allocator.dupe(u8, base_url),
                .path = try allocator.dupe(u8, path),
                .done = std.atomic.Value(bool).init(false),
                .slots = null,
                .error_msg = null,
                .state_ssz = null,
                .ref_count = std.atomic.Value(u32).init(2),
            };
            return ctx;
        }

        /// Drop one reference; destroy when both holders have released.
        fn release(self: *PollCtx) void {
            if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
                self.allocator.free(self.name);
                self.allocator.free(self.base_url);
                self.allocator.free(self.path);
                if (self.error_msg) |m| self.allocator.free(m);
                if (self.state_ssz) |s| self.allocator.free(s);
                self.allocator.destroy(self);
            }
        }
    };

    /// Worker thread: creates its own HTTP client, fetches slots, writes result,
    /// then releases its reference to the context.
    fn pollUpstreamThread(ctx: *PollCtx) void {
        defer ctx.release();

        var client = std.http.Client{ .allocator = ctx.allocator };
        defer client.deinit();

        var state_ssz: ?[]u8 = null;
        const slots = lean_api.fetchSlots(
            ctx.allocator,
            &client,
            ctx.base_url,
            ctx.path,
            &state_ssz,
        ) catch |err| {
            ctx.error_msg = std.fmt.allocPrint(ctx.allocator, "{s}", .{@errorName(err)}) catch null;
            ctx.done.store(true, .release);
            return;
        };

        ctx.slots = slots;
        ctx.state_ssz = state_ssz;
        ctx.done.store(true, .release);
    }

    /// Poll all upstreams concurrently and return consensus slots if 50%+ agree.
    ///
    /// Each upstream is polled in its own OS thread.  After spawning all threads
    /// the function waits up to timeout_ms for them all to finish.  Any thread
    /// still running at the deadline is abandoned (detached); its PollCtx is
    /// reference-counted so it cleans up itself when it eventually completes.
    pub fn pollUpstreams(
        self: *UpstreamManager,
        // client parameter kept for API compatibility but is no longer used here;
        // each thread creates its own client to avoid shared-state data races.
        _: *std.http.Client,
        now_ms: i64,
        timeout_ms: u64,
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

        // Step 2: spawn one thread per upstream
        var ctxs = std.ArrayList(*PollCtx).init(self.allocator);
        defer {
            for (ctxs.items) |ctx| ctx.release(); // spawner releases its ref
            ctxs.deinit();
        }

        for (targets.items) |target| {
            const ctx = PollCtx.create(
                self.allocator,
                target.index,
                target.name,
                target.base_url,
                target.path,
            ) catch |err| {
                log.warn("Failed to allocate poll context for {s}: {s}", .{ target.name, @errorName(err) });
                continue;
            };

            const thread = std.Thread.spawn(.{}, pollUpstreamThread, .{ctx}) catch |err| {
                log.warn("Failed to spawn poll thread for {s}: {s}", .{ target.name, @errorName(err) });
                ctx.release(); // thread never ran — release thread's ref too
                ctx.release(); // release spawner's ref
                continue;
            };
            thread.detach();

            ctxs.append(ctx) catch {
                // append failed; ctx's thread is already running and holds its own ref,
                // so just release the spawner's ref.
                ctx.release();
                continue;
            };
        }

        if (ctxs.items.len == 0) return null;

        // Step 3: wait for all threads behind a hard deadline
        const deadline_ms = now_ms + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline_ms) {
            var all_done = true;
            for (ctxs.items) |ctx| {
                if (!ctx.done.load(.acquire)) {
                    all_done = false;
                    break;
                }
            }
            if (all_done) break;
            std.time.sleep(5 * std.time.ns_per_ms);
        }

        // Log any upstreams that timed out
        for (ctxs.items) |ctx| {
            if (!ctx.done.load(.acquire)) {
                log.warn("Upstream {s} ({s}) timed out after {d}ms — detaching thread", .{
                    ctx.name, ctx.base_url, timeout_ms,
                });
            }
        }

        // Step 4: collect results from completed threads and update upstream state
        var results = std.ArrayList(PollResult).init(self.allocator);
        defer {
            for (results.items) |result| {
                if (result.error_msg) |msg| self.allocator.free(msg);
                if (result.state_ssz) |blob| self.allocator.free(blob);
            }
            results.deinit();
        }

        for (ctxs.items) |ctx| {
            if (!ctx.done.load(.acquire)) {
                // Timed out — record as an error so the upstream shows as failing
                const error_msg = self.allocator.dupe(u8, "timeout") catch null;
                results.append(PollResult{
                    .index = ctx.index,
                    .slots = null,
                    .error_msg = error_msg,
                    .state_ssz = null,
                }) catch continue;
                continue;
            }

            if (ctx.slots) |slots| {
                log.debug("Upstream {s}: justified={d}, finalized={d}", .{
                    ctx.name, slots.justified_slot, slots.finalized_slot,
                });
                // Transfer ownership of SSZ blob out of the ctx before ctx.release()
                // is called by the defer above.  We null it in ctx to avoid double-free.
                const ssz = ctx.state_ssz;
                ctx.state_ssz = null;
                results.append(PollResult{
                    .index = ctx.index,
                    .slots = slots,
                    .error_msg = null,
                    .state_ssz = ssz,
                }) catch continue;
            } else {
                const err_copy = if (ctx.error_msg) |m| self.allocator.dupe(u8, m) catch null else null;
                log.warn("Upstream {s} ({s}) failed: {s}", .{
                    ctx.name,
                    ctx.base_url,
                    ctx.error_msg orelse "unknown",
                });
                results.append(PollResult{
                    .index = ctx.index,
                    .slots = null,
                    .error_msg = err_copy,
                    .state_ssz = null,
                }) catch continue;
            }
        }

        // Step 5: Update upstream states (brief lock)
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
                    if (upstream.last_error) |old_err| {
                        self.allocator.free(old_err);
                        upstream.last_error = null;
                    }
                    upstream.error_count = 0;
                    upstream.last_slots = slots;
                    upstream.last_success_ms = now_ms;

                    const slot_key: u128 = (@as(u128, slots.justified_slot) << 64) | @as(u128, slots.finalized_slot);
                    const count = slot_counts.get(slot_key) orelse 0;
                    slot_counts.put(slot_key, count + 1) catch continue;

                    successful_polls += 1;
                } else {
                    upstream.error_count += 1;
                    if (upstream.last_error) |old_err| self.allocator.free(old_err);
                    upstream.last_error = result.error_msg;
                    results.items[i].error_msg = null; // ownership transferred
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

                for (results.items, 0..) |*res, i| {
                    if (res.slots) |s| {
                        if (s.justified_slot == justified_slot and s.finalized_slot == finalized_slot) {
                            if (res.state_ssz) |blob| {
                                out_state_ssz.* = blob;
                                results.items[i].state_ssz = null;
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
