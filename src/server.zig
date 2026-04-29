const std = @import("std");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const lean_api = @import("lean_api.zig");
const state_mod = @import("state.zig");
const metrics_mod = @import("metrics.zig");

pub fn serve(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
) !void {
    const address = try std.net.Address.parseIp4(config.bind_address, config.bind_port);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();
    log.info("Listening on {s}:{d}", .{ config.bind_address, config.bind_port });

    // One request per connection to avoid Zig std.http.Server discardBody()
    // unreachable when reusing the same connection (state machine bug).
    while (true) {
        var conn = try net_server.accept();
        defer conn.stream.close();
        var read_buffer: [16 * 1024]u8 = undefined;
        var http_server = std.http.Server.init(conn, &read_buffer);

        var req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => continue,
            error.HttpRequestTruncated,
            error.HttpHeadersOversize,
            error.HttpHeadersInvalid,
            error.HttpHeadersUnreadable,
            => continue,
        };
        handleRequest(allocator, config, state, &req) catch continue;
    }
}

fn methodName(method: std.http.Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .HEAD => "HEAD",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .CONNECT => "CONNECT",
        .OPTIONS => "OPTIONS",
        .TRACE => "TRACE",
        .PATCH => "PATCH",
        else => "OTHER",
    };
}

fn handleRequest(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
    req: *std.http.Server.Request,
) !void {
    const method = req.head.method;
    const target = req.head.target;

    log.debug("{s} {s}", .{ methodName(method), target });

    if (method != .GET and method != .HEAD) {
        try respondText(req, .method_not_allowed, "Method not allowed\n", "text/plain");
        return;
    }

    const path = splitPath(target);

    if (std.mem.eql(u8, path, "/status")) {
        try handleStatus(allocator, config, state, req);
        return;
    }
    if (std.mem.eql(u8, path, "/metrics")) {
        try handleMetrics(allocator, state, req);
        return;
    }
    if (std.mem.eql(u8, path, "/healthz")) {
        try handleHealthz(allocator, config, state, req);
        return;
    }
    if (std.mem.eql(u8, path, "/api/upstreams")) {
        try handleApiUpstreams(allocator, config, state, req);
        return;
    }
    if (matchUpstreamForkChoicePath(path)) |upstream_name| {
        try handleApiUpstreamForkChoice(allocator, config, state, req, upstream_name);
        return;
    }
    if (std.mem.eql(u8, path, "/lean/v0/states/finalized")) {
        try handleFinalizedState(allocator, config, state, req);
        return;
    }

    if (config.static_dir) |static_dir| {
        if (try handleStatic(allocator, static_dir, path, req)) return;
    }

    try respondText(req, .not_found, "Not found\n", "text/plain");
}

fn handleStatus(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
    req: *std.http.Server.Request,
) !void {
    var snapshot = try state.snapshot(allocator);
    defer snapshot.deinit(allocator);

    const now_ms = std.time.milliTimestamp();
    const stale = snapshot.last_success_ms == 0 or
        (now_ms - snapshot.last_success_ms) > @as(i64, @intCast(config.stale_after_ms));

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var last_error_json: ?[]const u8 = null;
    defer if (last_error_json) |value| allocator.free(value);
    if (snapshot.last_error) |msg| {
        last_error_json = try jsonString(allocator, msg);
    }

    const writer = buffer.writer();
    try writer.print(
        \\{{"justified_slot":{d},"finalized_slot":{d},"last_updated_ms":{d},"last_success_ms":{d},"stale":{s},"error_count":{d},"last_error":{s}}}
    , .{
        snapshot.justified_slot,
        snapshot.finalized_slot,
        snapshot.last_updated_ms,
        snapshot.last_success_ms,
        if (stale) "true" else "false",
        snapshot.error_count,
        last_error_json orelse "null",
    });

    try respondText(req, .ok, buffer.items, "application/json");
}

fn handleFinalizedState(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
    req: *std.http.Server.Request,
) !void {
    var snapshot = try state.snapshot(allocator);
    defer snapshot.deinit(allocator);

    const now_ms = std.time.milliTimestamp();
    const stale = snapshot.last_success_ms == 0 or
        (now_ms - snapshot.last_success_ms) > @as(i64, @intCast(config.stale_after_ms));

    if (stale) {
        log.warn("Finalized state request failed: stale data (last success: {d}ms ago)", .{
            if (snapshot.last_success_ms == 0) now_ms else now_ms - snapshot.last_success_ms,
        });
        try respondText(req, .service_unavailable, "stale\n", "text/plain");
        return;
    }

    // Get a copy of the last finalized state SSZ blob.
    const state_ssz_opt = try state.copyFinalizedStateSSZ(allocator);
    if (state_ssz_opt == null) {
        log.warn("Finalized state request failed: no finalized state SSZ cached", .{});
        try respondText(req, .service_unavailable, "no_finalized_state\n", "text/plain");
        return;
    }

    const state_ssz = state_ssz_opt.?;
    defer allocator.free(state_ssz);

    var content_length_buf: [32]u8 = undefined;
    const content_length_str = try std.fmt.bufPrint(&content_length_buf, "{d}", .{state_ssz.len});

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/octet-stream" },
        .{ .name = "content-length", .value = content_length_str },
    };
    try req.respond(state_ssz, .{
        .status = .ok,
        .keep_alive = false,
        .transfer_encoding = .none,
        .extra_headers = &headers,
    });
}

fn handleMetrics(
    allocator: std.mem.Allocator,
    state: *state_mod.AppState,
    req: *std.http.Server.Request,
) !void {
    var snapshot = try state.snapshot(allocator);
    defer snapshot.deinit(allocator);

    const body = try metrics_mod.format(allocator, snapshot);
    defer allocator.free(body);
    try respondText(req, .ok, body, "text/plain; version=0.0.4");
}

fn handleHealthz(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
    req: *std.http.Server.Request,
) !void {
    // Check if we're in multi-upstream mode
    var upstreams_data = try state.getUpstreamsData(allocator);
    defer upstreams_data.deinit(allocator);

    // If in multi-upstream mode, check consensus first
    if (upstreams_data.consensus.total_upstreams > 0) {
        // Require at least one upstream responding
        if (upstreams_data.consensus.responding_upstreams == 0) {
            log.warn("Health check failed: no upstreams responding", .{});
            try respondText(req, .service_unavailable, "no_upstreams\n", "text/plain");
            return;
        }

        // Require consensus (50%+ agreement)
        if (!upstreams_data.consensus.has_consensus) {
            log.warn("Health check failed: no consensus ({d}/{d} upstreams responding)", .{
                upstreams_data.consensus.responding_upstreams,
                upstreams_data.consensus.total_upstreams,
            });
            try respondText(req, .service_unavailable, "no_consensus\n", "text/plain");
            return;
        }
    }

    // Check if data is stale (for both single and multi-upstream modes)
    var snapshot = try state.snapshot(allocator);
    defer snapshot.deinit(allocator);

    const now_ms = std.time.milliTimestamp();
    const stale = snapshot.last_success_ms == 0 or
        (now_ms - snapshot.last_success_ms) > @as(i64, @intCast(config.stale_after_ms));

    if (stale) {
        log.warn("Health check failed: stale data (last success: {d}ms ago)", .{now_ms - snapshot.last_success_ms});
        try respondText(req, .service_unavailable, "stale\n", "text/plain");
    } else {
        try respondText(req, .ok, "ok\n", "text/plain");
    }
}

fn matchUpstreamForkChoicePath(path: []const u8) ?[]const u8 {
    const prefix = "/api/upstreams/";
    const suffix = "/fork_choice";
    if (path.len >= prefix.len + suffix.len + 1 and
        std.mem.startsWith(u8, path, prefix) and
        std.mem.endsWith(u8, path, suffix))
    {
        return path[prefix.len..][0 .. path.len - prefix.len - suffix.len];
    }
    return null;
}

fn handleApiUpstreamForkChoice(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
    req: *std.http.Server.Request,
    upstream_name: []const u8,
) !void {
    var upstreams_data = state.getUpstreamsData(allocator) catch |err| {
        log.warn("getUpstreamsData failed: {}", .{err});
        try respondText(req, .internal_server_error, "upstreams unavailable\n", "text/plain");
        return;
    };
    defer upstreams_data.deinit(allocator);

    const upstream = for (upstreams_data.upstreams) |u| {
        if (std.mem.eql(u8, u.name, upstream_name)) break u;
    } else {
        try respondText(req, .not_found, "upstream not found\n", "text/plain");
        return;
    };

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    if (@hasField(std.http.Client, "connect_timeout")) {
        client.connect_timeout = config.request_timeout_ms * std.time.ns_per_ms;
    }
    if (@hasField(std.http.Client, "read_timeout")) {
        client.read_timeout = config.request_timeout_ms * std.time.ns_per_ms;
    }

    const body = lean_api.fetchForkChoice(allocator, &client, upstream.url, config.request_timeout_ms) catch |err| {
        log.warn("fetchForkChoice from {s} failed: {}", .{ upstream.url, err });
        try respondText(req, .bad_gateway, "failed to fetch fork choice from upstream\n", "text/plain");
        return;
    };
    defer allocator.free(body);

    try respondText(req, .ok, body, "application/json");
}

fn handleApiUpstreams(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    state: *state_mod.AppState,
    req: *std.http.Server.Request,
) !void {
    _ = config;

    // Get upstreams data from state
    const upstreams_data = try state.getUpstreamsData(allocator);
    defer {
        var data = upstreams_data;
        data.deinit(allocator);
    }

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();

    // Start JSON response
    try writer.writeAll("{\"upstreams\":[");

    // Write each upstream
    for (upstreams_data.upstreams, 0..) |upstream, i| {
        if (i > 0) try writer.writeAll(",");

        const name_json = try jsonString(allocator, upstream.name);
        defer allocator.free(name_json);
        const url_json = try jsonString(allocator, upstream.url);
        defer allocator.free(url_json);
        const path_json = try jsonString(allocator, upstream.path);
        defer allocator.free(path_json);

        var last_error_json: ?[]const u8 = null;
        defer if (last_error_json) |value| allocator.free(value);
        if (upstream.last_error) |msg| {
            last_error_json = try jsonString(allocator, msg);
        }

        const is_aggregator_json: []const u8 = if (upstream.is_aggregator) |a|
            if (a) "true" else "false"
        else
            "null";
        const head_slot_json: []const u8 = if (upstream.head_slot) |slot| blk: {
            var num_buf: [32]u8 = undefined;
            const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{slot});
            break :blk num_str;
        } else "null";

        try writer.print(
            \\{{"name":{s},"url":{s},"path":{s},"healthy":{s},"last_success_ms":{s},"error_count":{d},"last_error":{s},"last_justified_slot":{s},"last_finalized_slot":{s},"is_aggregator":{s},"head_slot":{s}}}
        , .{
            name_json,
            url_json,
            path_json,
            if (upstream.healthy) "true" else "false",
            if (upstream.last_success_ms) |ms| blk: {
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{ms});
                break :blk num_str;
            } else "null",
            upstream.error_count,
            last_error_json orelse "null",
            if (upstream.last_justified_slot) |slot|
            blk: {
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{slot});
                break :blk num_str;
            } else "null",
            if (upstream.last_finalized_slot) |slot|
            blk: {
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{slot});
                break :blk num_str;
            } else "null",
            is_aggregator_json,
            head_slot_json,
        });
    }

    // Write consensus info
    try writer.print(
        \\],"consensus":{{"total_upstreams":{d},"responding_upstreams":{d},"consensus_threshold":50,"has_consensus":{s}}}}}
    , .{
        upstreams_data.consensus.total_upstreams,
        upstreams_data.consensus.responding_upstreams,
        if (upstreams_data.consensus.has_consensus) "true" else "false",
    });

    try respondText(req, .ok, buffer.items, "application/json");
}

fn handleStatic(
    allocator: std.mem.Allocator,
    static_dir: []const u8,
    path: []const u8,
    req: *std.http.Server.Request,
) !bool {
    var relative_path = path;
    if (std.mem.eql(u8, relative_path, "/")) {
        relative_path = "/index.html";
    }
    if (std.mem.startsWith(u8, relative_path, "/")) {
        relative_path = relative_path[1..];
    }
    if (std.mem.indexOf(u8, relative_path, "..") != null) {
        try respondText(req, .bad_request, "invalid path\n", "text/plain");
        return true;
    }

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ static_dir, relative_path });
    defer allocator.free(file_path);

    var file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(data);

    const content_type = guessContentType(file_path);
    try respondText(req, .ok, data, content_type);
    return true;
}

fn splitPath(target: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, target, '?');
    return iter.next() orelse target;
}

/// Respond with a text/JSON body. Uses keep_alive = false and transfer_encoding = .none
/// to avoid Zig std.http.Server discardBody() unreachable when reusing connections.
fn respondText(
    req: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    content_type: []const u8,
) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
    };
    try req.respond(body, .{
        .status = status,
        .keep_alive = false,
        .transfer_encoding = .none,
        .extra_headers = &headers,
    });
}

fn jsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    const writer = buffer.writer();
    try std.json.stringify(input, .{}, writer);
    return buffer.toOwnedSlice();
}

fn guessContentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

test "splitPath removes query string" {
    try std.testing.expectEqualStrings("/status", splitPath("/status?foo=bar"));
    try std.testing.expectEqualStrings("/metrics", splitPath("/metrics"));
    try std.testing.expectEqualStrings("/", splitPath("/?query=value"));
}

test "guessContentType" {
    try std.testing.expectEqualStrings("text/html", guessContentType("index.html"));
    try std.testing.expectEqualStrings("application/javascript", guessContentType("script.js"));
    try std.testing.expectEqualStrings("text/css", guessContentType("style.css"));
    try std.testing.expectEqualStrings("application/json", guessContentType("data.json"));
    try std.testing.expectEqualStrings("image/png", guessContentType("image.png"));
    try std.testing.expectEqualStrings("image/svg+xml", guessContentType("icon.svg"));
    try std.testing.expectEqualStrings("image/x-icon", guessContentType("favicon.ico"));
    try std.testing.expectEqualStrings("application/octet-stream", guessContentType("file.bin"));
    try std.testing.expectEqualStrings("application/octet-stream", guessContentType("no_extension"));
}

test "jsonString escapes special characters" {
    const input = "test \"quoted\" string\nwith newline";
    const output = try jsonString(std.testing.allocator, input);
    defer std.testing.allocator.free(output);

    // Should be properly escaped JSON string
    try std.testing.expect(std.mem.indexOf(u8, output, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\n") != null);
}
