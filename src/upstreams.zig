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

    // ---------------------------------------------------------------------------
    // Bounded-concurrency poll dispatcher with deadline-based abandonment.
    //
    // Why this shape:
    //   * std.http.Client.open does a synchronous connect(); SO_RCVTIMEO/SO_SNDTIMEO
    //     in lean_api only bound the read/write phase, not connect itself. So a
    //     blackholed peer can hang a worker thread indefinitely.
    //   * Therefore the dispatcher must NOT join workers (one stuck connect would
    //     wedge the entire poll loop). It detaches them and waits on a deadline.
    //   * Refcounted PollCtx lets a slow worker safely outlive the dispatcher
    //     (it frees its own state when the spawner has already moved on).
    //   * A condvar-guarded in-flight counter caps OS thread / SSZ-download
    //     parallelism even when N upstreams >> the configured concurrency.
    // ---------------------------------------------------------------------------

    /// Slot accounting: caps concurrent in-flight workers and signals the
    /// dispatcher when one finishes (so the next can be spawned, and the final
    /// drain wait can wake up early when all workers have completed).
    const SlotState = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        in_flight: usize = 0,
        cap: usize,
    };

    /// Heap context shared between dispatcher and worker (refcount starts at 2).
    /// Worker writes outputs then `done.store(true, .release)`; dispatcher only
    /// reads outputs after it has observed done==true (via `.acquire` load).
    const PollCtx = struct {
        allocator: std.mem.Allocator,
        slot: *SlotState,
        target_index: usize,
        // Owned copies of target strings — safe past the dispatcher's lifetime.
        name: []u8,
        base_url: []u8,
        path: []u8,
        timeout_ms: u64,
        done: std.atomic.Value(bool),
        slots: ?lean_api.Slots = null,
        error_msg: ?[]u8 = null,
        state_ssz: ?[]u8 = null,
        is_aggregator: ?bool = null,
        head_slot: ?u64 = null,
        refs: std.atomic.Value(u32),

        fn create(
            allocator: std.mem.Allocator,
            slot: *SlotState,
            target: PollTarget,
            timeout_ms: u64,
        ) !*PollCtx {
            const ctx = try allocator.create(PollCtx);
            errdefer allocator.destroy(ctx);
            const name_copy = try allocator.dupe(u8, target.name);
            errdefer allocator.free(name_copy);
            const url_copy = try allocator.dupe(u8, target.base_url);
            errdefer allocator.free(url_copy);
            const path_copy = try allocator.dupe(u8, target.path);
            ctx.* = .{
                .allocator = allocator,
                .slot = slot,
                .target_index = target.index,
                .name = name_copy,
                .base_url = url_copy,
                .path = path_copy,
                .timeout_ms = timeout_ms,
                .done = std.atomic.Value(bool).init(false),
                .refs = std.atomic.Value(u32).init(2),
            };
            return ctx;
        }

        fn release(self: *PollCtx) void {
            if (self.refs.fetchSub(1, .acq_rel) == 1) {
                self.allocator.free(self.name);
                self.allocator.free(self.base_url);
                self.allocator.free(self.path);
                if (self.error_msg) |m| self.allocator.free(m);
                if (self.state_ssz) |s| self.allocator.free(s);
                self.allocator.destroy(self);
            }
        }
    };

    /// Decrement the in-flight count and wake any dispatcher waiting on a slot
    /// or on the final drain. Always called once per worker (defer in worker).
    fn slotRelease(slot: *SlotState) void {
        slot.mutex.lock();
        defer slot.mutex.unlock();
        if (slot.in_flight > 0) slot.in_flight -= 1;
        slot.cond.broadcast();
    }

    /// Worker thread: own HTTP client, write outputs, signal completion. If the
    /// peer hangs on connect/read this thread may live well past the dispatcher's
    /// deadline — its PollCtx ref keeps everything alive until cleanup.
    fn workerThread(ctx: *PollCtx) void {
        defer ctx.release();
        defer slotRelease(ctx.slot);

        var client = std.http.Client{ .allocator = ctx.allocator };
        defer client.deinit();

        var state_ssz: ?[]u8 = null;
        if (lean_api.fetchSlots(
            ctx.allocator,
            &client,
            ctx.base_url,
            ctx.path,
            &state_ssz,
            ctx.timeout_ms,
        )) |slots| {
            // Optional metadata calls share a small slice of the per-poll budget
            // (was timeout_ms/2 each; that doubled worker slot occupancy on healthy
            // peers and starved the dispatcher with many upstreams + bounded cap).
            const sub_to = @max(@as(u64, 1_000), ctx.timeout_ms / 4);
            ctx.is_aggregator = lean_api.fetchAggregatorOptional(ctx.allocator, &client, ctx.base_url, sub_to);
            ctx.head_slot = lean_api.fetchHeadSlotOptional(ctx.allocator, &client, ctx.base_url, sub_to);
            ctx.slots = slots;
            ctx.state_ssz = state_ssz;
            log.debug("Upstream {s}: justified={d}, finalized={d}", .{
                ctx.name, slots.justified_slot, slots.finalized_slot,
            });
        } else |err| {
            if (state_ssz) |s| ctx.allocator.free(s);
            ctx.error_msg = std.fmt.allocPrint(ctx.allocator, "{s}", .{@errorName(err)}) catch null;
            log.warn("Upstream {s} ({s}) failed: {s}", .{ ctx.name, ctx.base_url, @errorName(err) });
        }

        // Publish results to the dispatcher (must come last; release ordering
        // pairs with the dispatcher's acquire load before reading any field).
        ctx.done.store(true, .release);
    }

    /// Wait until cond is signaled or the deadline elapses. Returns true if
    /// the deadline has not yet passed (caller can re-check its predicate).
    fn waitUntilDeadline(slot: *SlotState, deadline_ms: i64) bool {
        const now = std.time.milliTimestamp();
        if (now >= deadline_ms) return false;
        const remaining_ms: u64 = @intCast(deadline_ms - now);
        // Cap each individual wait so we re-check the predicate periodically
        // even if a signal is missed for some reason.
        const wait_ms: u64 = @min(remaining_ms, @as(u64, 100));
        const wait_ns: u64 = wait_ms * std.time.ns_per_ms;
        slot.cond.timedWait(&slot.mutex, wait_ns) catch {};
        return std.time.milliTimestamp() < deadline_ms;
    }

    /// Poll upstreams with bounded concurrency + a hard per-tick deadline.
    /// Returns consensus slots if 50%+ of responding upstreams agree.
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

        // Per-tick deadline. A single worker can occupy its slot for up to
        // ~timeout_ms (fetchSlots) + 2 × (timeout_ms / 4) (aux calls) ≈
        // 1.5 × timeout_ms; in the worst case (slow path on each call) closer
        // to 2 × timeout_ms. We size the deadline assuming worst case so
        // dispatch never starves with a bounded cap and slow peers, plus one
        // extra timeout_ms for the final drain.
        const batches: u64 = (@as(u64, n) + @as(u64, cap) - 1) / @as(u64, cap);
        const per_worker_max_ms: u64 = timeout_ms * 2;
        const round_ms: u64 = batches * per_worker_max_ms + timeout_ms;
        const deadline_ms: i64 = now_ms + @as(i64, @intCast(round_ms));

        if (cap < n) {
            log.debug(
                "Polling {d} upstreams with concurrency {d} (≤{d} OS threads, deadline ≤{d}ms)",
                .{ n, cap, cap, round_ms },
            );
        }

        var slot = SlotState{ .cap = cap };

        var ctxs = std.ArrayList(*PollCtx).init(self.allocator);
        defer {
            for (ctxs.items) |ctx| ctx.release();
            ctxs.deinit();
        }

        // Step 2: dispatch — wait for a free slot (or the deadline) before each spawn
        for (targets.items) |target| {
            slot.mutex.lock();
            var slot_acquired = false;
            while (slot.in_flight >= slot.cap) {
                if (!waitUntilDeadline(&slot, deadline_ms)) break;
            }
            if (slot.in_flight < slot.cap) {
                slot.in_flight += 1;
                slot_acquired = true;
            }
            slot.mutex.unlock();

            if (!slot_acquired) {
                log.warn(
                    "Dispatch deadline reached before {s} could start; remaining upstreams skipped this tick",
                    .{target.name},
                );
                break;
            }

            const ctx = PollCtx.create(self.allocator, &slot, target, timeout_ms) catch |err| {
                log.warn("Failed to allocate poll context for {s}: {s}", .{ target.name, @errorName(err) });
                slotRelease(&slot);
                continue;
            };

            const t = std.Thread.spawn(.{}, workerThread, .{ctx}) catch |err| {
                log.warn("Failed to spawn poll thread for {s}: {s}", .{ target.name, @errorName(err) });
                slotRelease(&slot);
                ctx.release(); // worker ref (worker never started)
                ctx.release(); // dispatcher ref
                continue;
            };
            t.detach();

            ctxs.append(ctx) catch {
                // Worker is already running and holds its own ref — just drop ours.
                ctx.release();
                continue;
            };
        }

        // Step 3: drain — wait for all in-flight workers to finish, or the deadline
        slot.mutex.lock();
        while (slot.in_flight > 0) {
            if (!waitUntilDeadline(&slot, deadline_ms)) break;
        }
        slot.mutex.unlock();

        // Step 4: collect results and update per-upstream state under our lock.
        var slot_counts = std.AutoHashMap(u128, u32).init(self.allocator);
        defer slot_counts.deinit();

        var successful_polls: u32 = 0;
        var timed_out: u32 = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (ctxs.items) |ctx| {
                if (ctx.target_index >= self.upstreams.items.len) continue;
                var upstream = &self.upstreams.items[ctx.target_index];

                // Acquire ordering: pairs with the worker's release store on `done`.
                const finished = ctx.done.load(.acquire);

                if (!finished) {
                    timed_out += 1;
                    upstream.error_count += 1;
                    if (upstream.last_error) |old_err| self.allocator.free(old_err);
                    upstream.last_error = self.allocator.dupe(u8, "timeout (worker abandoned)") catch null;
                    upstream.is_aggregator = null;
                    upstream.head_slot = null;
                    continue;
                }

                if (ctx.slots) |slots| {
                    if (upstream.last_error) |old_err| {
                        self.allocator.free(old_err);
                        upstream.last_error = null;
                    }
                    upstream.error_count = 0;
                    upstream.last_slots = slots;
                    upstream.last_success_ms = now_ms;
                    upstream.is_aggregator = ctx.is_aggregator;
                    upstream.head_slot = ctx.head_slot;

                    const slot_key: u128 = (@as(u128, slots.justified_slot) << 64) | @as(u128, slots.finalized_slot);
                    const count = slot_counts.get(slot_key) orelse 0;
                    slot_counts.put(slot_key, count + 1) catch continue;

                    successful_polls += 1;
                } else {
                    upstream.error_count += 1;
                    if (upstream.last_error) |old_err| self.allocator.free(old_err);
                    if (ctx.error_msg) |msg| {
                        upstream.last_error = self.allocator.dupe(u8, msg) catch null;
                    } else {
                        upstream.last_error = self.allocator.dupe(u8, "unknown error") catch null;
                    }
                    upstream.is_aggregator = null;
                    upstream.head_slot = null;
                }
            }
        }

        if (timed_out > 0) {
            log.warn("{d}/{d} upstream polls did not finish within deadline (continuing)", .{ timed_out, ctxs.items.len });
        }

        // Step 5: consensus (no lock needed)
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

                // Hand out one matching SSZ blob. Move ownership out of the
                // ctx so PollCtx.release() doesn't free it; remaining ctxs'
                // ssz blobs are freed normally on release.
                for (ctxs.items) |ctx| {
                    if (!ctx.done.load(.acquire)) continue;
                    if (ctx.slots) |s| {
                        if (s.justified_slot == justified_slot and s.finalized_slot == finalized_slot) {
                            if (ctx.state_ssz) |blob| {
                                out_state_ssz.* = blob;
                                ctx.state_ssz = null;
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
