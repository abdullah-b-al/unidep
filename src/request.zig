const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const ui = @import("ui.zig");
const handlers = @import("handlers.zig");

pub fn begin_session(connection: *Connection, debugee: []const u8) !void {
    // send and respond to initialize
    // send launch or attach
    // when the adapter is ready it'll send a initialized event
    // send configuration
    // send configuration done
    // respond to launch or attach
    const init_args = protocol.InitializeRequestArguments{
        .clientName = "unidep",
        .adapterID = "???",
        .columnsStartAt1 = false,
        .linesStartAt1 = false,
    };

    if (connection.state == .not_spawned) {
        try connection.adapter_spawn();
    }

    const init_seq = try connection.queue_request_init(init_args, .none);

    {
        var extra = protocol.Object{};
        defer extra.deinit(connection.allocator);
        try extra.map.put(connection.allocator, "program", .{ .string = debugee });
        _ = try connection.queue_request_launch(.{}, extra, .{ .seq = init_seq });
    }

    // TODO: Send configurations here

    _ = try connection.queue_request_configuration_done(null, .{}, .{ .event = .initialized });
}

pub fn end_session(connection: *Connection, how: enum { terminate, disconnect }) !void {
    switch (connection.state) {
        .initialized,
        .partially_initialized,
        .initializing,
        .spawned,
        => return error.SessionNotStarted,

        .not_spawned => return error.AdapterNotSpawned,

        .attached => @panic("TODO"),
        .launched => {
            switch (how) {
                .terminate => _ = try connection.queue_request(
                    .terminate,
                    protocol.TerminateArguments{
                        .restart = false,
                    },
                    .none,
                    .no_data,
                ),

                .disconnect => _ = try connection.queue_request(
                    .disconnect,
                    protocol.DisconnectArguments{
                        .restart = false,
                        .terminateDebuggee = null,
                        .suspendDebuggee = null,
                    },
                    .none,
                    .no_data,
                ),
            }
        },
    }
}

// Causes a chain of requests to get the state
pub fn get_thread_state(connection: *Connection, thread_id: i32) !void {
    _ = try connection.queue_request(
        .stackTrace,
        protocol.StackTraceArguments{ .threadId = thread_id },
        .none,
        .{ .stack_trace = .{
            .thread_id = thread_id,
            .request_scopes = true,
            .request_variables = true,
        } },
    );
}

pub fn next(callbacks: *handlers.Callbacks, data: SessionData, connection: *Connection, granularity: protocol.SteppingGranularity) void {
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;
        if (!thread.unlocked) {
            continue;
        }
        const arg = protocol.NextArguments{
            .threadId = thread.id,
            .singleThread = true,
            .granularity = granularity,
        };

        _ = connection.queue_request(.next, arg, .none, .{ .next = .{
            .thread_id = thread.id,
            .request_stack_trace = true,
            .request_scopes = false,
            .request_variables = false,
        } }) catch return;
    }

    const static = struct {
        fn func(_: *SessionData, _: *Connection, _: ?Connection.RawMessage) void {
            ui.state.scroll_to_active_line = true;
            ui.state.update_active_source_to_top_of_stack = true;
        }
    };

    handlers.callback(callbacks, .success, .{ .response = .stackTrace }, null, static.func) catch return;
}
