const std = @import("std");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const io = @import("io.zig");

const log = std.log.scoped(.connection);

const Connection = @This();

const ClientCapabilitiesKind = enum {
    supportsVariableType,
    supportsVariablePaging,
    supportsRunInTerminalRequest,
    supportsMemoryReferences,
    supportsProgressReporting,
    supportsInvalidatedEvent,
    supportsMemoryEvent,
    supportsArgsCanBeInterpretedByShell,
    supportsStartDebuggingRequest,
    supportsANSIStyling,
};

const ClientCapabilitiesSet = std.EnumSet(ClientCapabilitiesKind);

const AdapterCapabilitiesKind = enum {
    supportsConfigurationDoneRequest,
    supportsFunctionBreakpoints,
    supportsConditionalBreakpoints,
    supportsHitConditionalBreakpoints,
    supportsEvaluateForHovers,
    supportsStepBack,
    supportsSetVariable,
    supportsRestartFrame,
    supportsGotoTargetsRequest,
    supportsStepInTargetsRequest,
    supportsCompletionsRequest,
    supportsModulesRequest,
    supportsRestartRequest,
    supportsExceptionOptions,
    supportsValueFormattingOptions,
    supportsExceptionInfoRequest,
    supportTerminateDebuggee,
    supportSuspendDebuggee,
    supportsDelayedStackTraceLoading,
    supportsLoadedSourcesRequest,
    supportsLogPoints,
    supportsTerminateThreadsRequest,
    supportsSetExpression,
    supportsTerminateRequest,
    supportsDataBreakpoints,
    supportsReadMemoryRequest,
    supportsWriteMemoryRequest,
    supportsDisassembleRequest,
    supportsCancelRequest,
    supportsBreakpointLocationsRequest,
    supportsClipboardContext,
    supportsSteppingGranularity,
    supportsInstructionBreakpoints,
    supportsExceptionFilterOptions,
    supportsSingleThreadExecutionRequests,
    supportsANSIStyling,
};
const AdapterCapabilitiesSet = std.EnumSet(AdapterCapabilitiesKind);

const AdapterCapabilities = struct {
    support: AdapterCapabilitiesSet = .{},
    completionTriggerCharacters: ?[][]const u8 = null,
    exceptionBreakpointFilters: ?[]protocol.ExceptionBreakpointsFilter = null,
    additionalModuleColumns: ?[]protocol.ColumnDescriptor = null,
    supportedChecksumAlgorithms: ?[]protocol.ChecksumAlgorithm = null,
    breakpointModes: ?[]protocol.BreakpointMode = null,
};

pub const RawMessage = std.json.Parsed(std.json.Value);

const State = enum {
    /// Adapter and debuggee are running
    launched,
    /// Adapter and debuggee are running
    attached,
    /// Adapter is running and the initialized event has been handled
    initialized,
    /// Adapter is running and the initialize request has been responded to
    partially_initialized,
    /// Adapter is running and the initialize request has been sent
    initializing,
    /// Adapter is running
    spawned,
    /// Adapter is not running
    not_spawned,

    pub fn fully_initialized(state: State) bool {
        return switch (state) {
            .initialized, .launched, .attached => true,

            .partially_initialized, .initializing, .spawned, .not_spawned => false,
        };
    }
};

pub const Dependency = union(enum) {
    response: Command,
    event: Event,
    seq: i32,
    none,
};

pub const RetainedRequestData = union(enum) {
    stack_trace: struct {
        thread_id: i32,
        request_scopes: bool,
        request_variables: bool,
    },
    scopes: struct {
        frame_id: i32,
        request_variables: bool,
    },
    variables: struct {
        variables_reference: i32,
    },
    source: struct {
        path: ?[]const u8,
        source_reference: i32,
    },
    next: struct {
        thread_id: i32,
        request_stack_trace: bool,
        request_scopes: bool,
        request_variables: bool,
    },
    no_data,
};

pub const Response = struct {
    command: Command,
    request_seq: i32,
    request_data: RetainedRequestData,
};

pub const ResponseStatus = enum { success, failure };
pub const HandledResponse = struct {
    response: Response,
    status: ResponseStatus,
};

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    object: protocol.Object,
    command: Command,
    seq: i32,
    /// Send request when dependency is satisfied
    depends_on: Dependency,
};

pub const Command = blk: {
    @setEvalBranchQuota(10_000);

    const EnumField = std.builtin.Type.EnumField;
    var enum_fields: []const EnumField = &[_]EnumField{};
    var enum_value: usize = 0;

    for (std.meta.declarations(protocol)) |decl| {
        const T = @field(protocol, decl.name);
        if (@typeInfo(@TypeOf(T)) == .@"fn") continue;
        if (!std.mem.endsWith(u8, @typeName(T), "Request")) continue;
        if (!@hasField(T, "command")) @compileError("Request with no command!");

        for (std.meta.fields(T)) |field| {
            if (!std.mem.eql(u8, field.name, "command")) continue;
            if (@typeInfo(field.type) != .@"enum") continue;

            // fields of the type of "command"
            for (std.meta.fields(field.type)) |f| {
                enum_fields = enum_fields ++ &[_]EnumField{.{
                    .name = f.name,
                    .value = enum_value,
                }};
                enum_value += 1;
            }
        }
    }
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const Event = blk: {
    @setEvalBranchQuota(10_000);

    const EnumField = std.builtin.Type.EnumField;
    var enum_fields: []const EnumField = &[_]EnumField{};
    var enum_value: usize = 0;

    for (std.meta.declarations(protocol)) |decl| {
        const T = @field(protocol, decl.name);
        if (@typeInfo(@TypeOf(T)) == .@"fn") continue;
        if (!std.mem.endsWith(u8, @typeName(T), "Event")) continue;
        if (!@hasField(T, "event")) @compileError("Event with no event!");

        for (std.meta.fields(T)) |field| {
            if (!std.mem.eql(u8, field.name, "event")) continue;
            if (@typeInfo(field.type) != .@"enum") continue;

            // fields of the type of "event"
            for (std.meta.fields(field.type)) |f| {
                enum_fields = enum_fields ++ &[_]EnumField{.{
                    .name = f.name,
                    .value = enum_value,
                }};
                enum_value += 1;
            }
        }
    }
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

allocator: std.mem.Allocator,
/// Used for deeply cloned values
arena: std.heap.ArenaAllocator,
adapter: std.process.Child,

client_capabilities: ClientCapabilitiesSet = .{},
adapter_capabilities: AdapterCapabilities = .{},

queued_requests: std.ArrayList(Request),
expected_responses: std.ArrayList(Response),
handled_responses: std.ArrayList(HandledResponse),
handled_events: std.ArrayList(Event),

total_requests: u32 = 0,
debug_requests: std.ArrayList(Request),

total_responses_received: u32 = 0,
responses: std.ArrayList(RawMessage),
debug_handled_responses: std.ArrayList(RawMessage),

total_events_received: u32 = 0,
events: std.ArrayList(RawMessage),
debug_handled_events: std.ArrayList(RawMessage),

state: State,
debug: bool,

/// Used for the seq field in the protocol
seq: u32 = 1,

pub fn init(allocator: std.mem.Allocator, adapter_argv: []const []const u8, debug: bool) Connection {
    var adapter = std.process.Child.init(
        adapter_argv,
        allocator,
    );

    adapter.stdin_behavior = .Pipe;
    adapter.stdout_behavior = .Pipe;
    adapter.stderr_behavior = .Pipe;

    return .{
        .state = .not_spawned,
        .adapter = adapter,
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .queued_requests = std.ArrayList(Request).init(allocator),
        .debug_requests = std.ArrayList(Request).init(allocator),
        .responses = std.ArrayList(RawMessage).init(allocator),
        .expected_responses = std.ArrayList(Response).init(allocator),
        .handled_responses = std.ArrayList(HandledResponse).init(allocator),
        .handled_events = std.ArrayList(Event).init(allocator),

        .debug_handled_responses = std.ArrayList(RawMessage).init(allocator),
        .events = std.ArrayList(RawMessage).init(allocator),
        .debug_handled_events = std.ArrayList(RawMessage).init(allocator),
        .debug = debug,
    };
}

pub fn deinit(connection: *Connection) void {
    const table = .{
        connection.responses.items,
        connection.debug_handled_responses.items,
        connection.events.items,
        connection.debug_handled_events.items,
    };

    inline for (table) |entry| {
        for (entry) |*item| {
            item.deinit();
        }
    }

    for (connection.debug_requests.items) |*request| {
        request.arena.deinit();
    }
    connection.debug_requests.deinit();

    for (connection.queued_requests.items) |*request| {
        request.arena.deinit();
    }
    connection.queued_requests.deinit();

    connection.expected_responses.deinit();
    connection.handled_responses.deinit();
    connection.handled_events.deinit();
    connection.responses.deinit();
    connection.debug_handled_responses.deinit();
    connection.events.deinit();
    connection.debug_handled_events.deinit();

    connection.arena.deinit();
}

pub fn queue_request(connection: *Connection, comptime command: Command, arguments: anytype, depends_on: Dependency, request_data: RetainedRequestData) !i32 {
    connection.total_requests += 1;
    try connection.queued_requests.ensureUnusedCapacity(1);
    try connection.expected_responses.ensureUnusedCapacity(1);
    try connection.debug_requests.ensureTotalCapacity(connection.total_requests);

    // don't use the request's arena so as not to free the expected_responses data
    // when the request is sent
    const cloner = connection.create_cloner();
    const cloned_request_data = try utils.clone_anytype(cloner, request_data);

    // FIXME: This leaks for some reason.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();

    const args = switch (@TypeOf(arguments)) {
        @TypeOf(null) => protocol.Object{},
        protocol.Object => arguments,
        else => try utils.value_to_object(arena.allocator(), arguments),
    };

    const request = protocol.Request{
        .seq = connection.new_seq(),
        .type = .request,
        .command = @tagName(command),
        .arguments = .{ .object = args },
    };

    connection.queued_requests.appendAssumeCapacity(.{
        .arena = arena,
        .object = try utils.value_to_object(arena.allocator(), request),
        .seq = request.seq,
        .command = command,
        .depends_on = depends_on,
    });

    connection.expected_responses.appendAssumeCapacity(.{
        .request_seq = request.seq,
        .command = command,
        .request_data = cloned_request_data,
    });

    return request.seq;
}

pub fn send_request(connection: *Connection, index: usize) !void {
    const request = connection.queued_requests.items[index];
    if (!dependency_satisfied(connection.*, request)) return error.DependencyNotSatisfied;

    switch (connection.state) {
        .partially_initialized => {
            switch (request.command) {
                .launch, .attach => {},
                else => return error.AdapterNotDoneInitializing,
            }
        },
        .initializing => {
            switch (request.command) {
                .initialize => {},
                else => return error.AdapterNotDoneInitializing,
            }
        },
        .not_spawned => return error.AdapterNotSpawned,
        .initialized, .spawned, .attached, .launched => {},
    }

    try connection.check_request_capability(request.command);
    const message = try io.create_message(connection.allocator, request.object);
    defer connection.allocator.free(message);
    try connection.adapter_write_all(message);

    _ = connection.queued_requests.orderedRemove(index);
    if (connection.debug) {
        connection.debug_requests.appendAssumeCapacity(request);
    } else {
        request.arena.deinit();
    }
}

fn dependency_satisfied(connection: Connection, to_send: Connection.Request) bool {
    switch (to_send.depends_on) {
        .event => |event| {
            for (connection.handled_events.items) |item| {
                if (item == event) return true;
            }
        },
        .seq => |seq| {
            for (connection.handled_responses.items) |item| {
                if (item.response.request_seq == seq) return true;
            }
        },
        .response => |command| {
            for (connection.handled_responses.items) |item| {
                if (item.response.command == command) return true;
            }
        },
        .none => return true,
    }

    return false;
}

pub fn remove_event(connection: *Connection, seq: i32) RawMessage {
    _, const index = connection.get_event(seq) catch @panic("Only call this if you got an event");
    return connection.events.orderedRemove(index);
}

pub fn delayed_handled_event(connection: *Connection, event: Event, raw_event: RawMessage) void {
    connection.handled_events.appendAssumeCapacity(event);
    if (connection.debug) {
        connection.debug_handled_events.appendAssumeCapacity(raw_event);
    } else {
        raw_event.deinit();
    }
}

pub fn handled_event(connection: *Connection, event: Event, seq: i32) void {
    _, const index = connection.get_event(seq) catch unreachable;
    const raw_event = connection.events.orderedRemove(index);
    connection.handled_events.appendAssumeCapacity(event);
    if (connection.debug) {
        connection.debug_handled_events.appendAssumeCapacity(raw_event);
    } else {
        raw_event.deinit();
    }
}

pub fn handled_response(connection: *Connection, response: Response, status: ResponseStatus) void {
    _, const index = connection.get_response_by_request_seq(response.request_seq) catch @panic("Only call this if you got a response");
    const raw_resp = connection.responses.orderedRemove(index);
    connection.handled_responses.appendAssumeCapacity(.{
        .response = response,
        .status = status,
    });
    if (connection.debug) {
        connection.debug_handled_responses.appendAssumeCapacity(raw_resp);
    } else {
        raw_resp.deinit();
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn queue_request_init(connection: *Connection, arguments: protocol.InitializeRequestArguments, depends_on: Dependency) !i32 {
    if (connection.state.fully_initialized()) {
        return error.AdapterAlreadyInitalized;
    }

    connection.client_capabilities = utils.bit_set_from_struct(arguments, ClientCapabilitiesSet, ClientCapabilitiesKind);

    const seq = try connection.queue_request(.initialize, arguments, depends_on, .no_data);
    connection.state = .initializing;
    return seq;
}

pub fn handle_response_init(connection: *Connection, response: Response) !void {
    std.debug.assert(connection.state == .initializing);
    const cloner = connection.create_cloner();

    const resp = try connection.get_parse_validate_response(protocol.InitializeResponse, response.request_seq, .initialize);
    defer resp.deinit();
    if (resp.value.body) |body| {
        connection.adapter_capabilities.support = utils.bit_set_from_struct(body, AdapterCapabilitiesSet, AdapterCapabilitiesKind);
        connection.adapter_capabilities.completionTriggerCharacters = try utils.clone_anytype(cloner, body.completionTriggerCharacters);
        connection.adapter_capabilities.exceptionBreakpointFilters = try utils.clone_anytype(cloner, body.exceptionBreakpointFilters);
        connection.adapter_capabilities.additionalModuleColumns = try utils.clone_anytype(cloner, body.additionalModuleColumns);
        connection.adapter_capabilities.supportedChecksumAlgorithms = try utils.clone_anytype(cloner, body.supportedChecksumAlgorithms);
        connection.adapter_capabilities.breakpointModes = try utils.clone_anytype(cloner, body.breakpointModes);
    }

    connection.state = .partially_initialized;
    connection.handled_response(response, .success);
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn queue_request_launch(connection: *Connection, arguments: protocol.LaunchRequestArguments, extra_arguments: protocol.Object, depends_on: Dependency) !i32 {
    var args = try utils.value_to_object(connection.arena.allocator(), arguments);
    try utils.object_merge(connection.arena.allocator(), &args, extra_arguments);
    return try connection.queue_request(.launch, args, depends_on, .no_data);
}

pub fn handle_response_launch(connection: *Connection, response: Response) void {
    connection.state = .launched;
    connection.handled_response(response, .success);
}

pub fn queue_request_configuration_done(connection: *Connection, arguments: ?protocol.ConfigurationDoneArguments, extra_arguments: protocol.Object, depends_on: Dependency) !i32 {
    var args = try utils.value_to_object(connection.arena.allocator(), arguments);
    try utils.object_merge(connection.arena.allocator(), &args, extra_arguments);
    return try connection.queue_request(.configurationDone, args, depends_on, .no_data);
}

pub fn handle_response_disconnect(connection: *Connection, response: Response) !void {
    const resp = try connection.get_and_parse_response(protocol.DisconnectResponse, response.request_seq);
    defer resp.deinit();
    try validate_response(resp.value, response.request_seq, .disconnect);

    if (resp.value.success) {
        connection.state = .initialized;
    }

    connection.handled_response(response, .success);
}

pub fn handle_event_initialized(connection: *Connection, seq: i32) void {
    connection.state = .initialized;
    connection.handled_event(.initialized, seq);
}

fn check_request_capability(connection: *Connection, command: Command) !void {
    const s = connection.adapter_capabilities.support;
    const c = connection.adapter_capabilities;
    const result = switch (command) {
        .dataBreakpointInfo, .setDataBreakpoints => s.contains(.supportsDataBreakpoints),
        .stepBack, .reverseContinue => s.contains(.supportsStepBack),

        .configurationDone => s.contains(.supportsConfigurationDoneRequest),
        .setFunctionBreakpoints => s.contains(.supportsFunctionBreakpoints),
        .setVariable => s.contains(.supportsSetVariable),
        .restartFrame => s.contains(.supportsRestartFrame),
        .gotoTargets => s.contains(.supportsGotoTargetsRequest),
        .stepInTargets => s.contains(.supportsStepInTargetsRequest),
        .completions => s.contains(.supportsCompletionsRequest),
        .modules => s.contains(.supportsModulesRequest),
        .restart => s.contains(.supportsRestartRequest),
        .exceptionInfo => s.contains(.supportsExceptionInfoRequest),
        .loadedSources => s.contains(.supportsLoadedSourcesRequest),
        .terminateThreads => s.contains(.supportsTerminateThreadsRequest),
        .setExpression => s.contains(.supportsSetExpression),
        .terminate => s.contains(.supportsTerminateRequest),
        .cancel => s.contains(.supportsCancelRequest),
        .breakpointLocations => s.contains(.supportsBreakpointLocationsRequest),
        .setInstructionBreakpoints => s.contains(.supportsInstructionBreakpoints),
        .readMemory => s.contains(.supportsReadMemoryRequest),
        .writeMemory => s.contains(.supportsWriteMemoryRequest),
        .disassemble => s.contains(.supportsDisassembleRequest),
        .goto => s.contains(.supportsGotoTargetsRequest),

        .setExceptionBreakpoints => (c.exceptionBreakpointFilters orelse &.{}).len > 1,

        .locations,
        .evaluate,
        .source,
        .threads,
        .variables,
        .scopes,
        .@"continue",
        .pause,
        .stackTrace,
        .stepIn,
        .stepOut,
        .setBreakpoints,
        .next,
        .disconnect,
        .launch,
        .attach,
        .initialize,
        => true,

        .startDebugging, .runInTerminal => @panic("This is a reverse request"),
    };

    if (!result) {
        return error.AdapterDoesNotSupportRequest;
    }
}

pub fn adapter_spawn(connection: *Connection) !void {
    if (connection.state != .not_spawned) {
        return error.AdapterAlreadySpawned;
    }
    try connection.adapter.spawn();
    connection.state = .spawned;
}

pub fn adapter_wait(connection: *Connection) !std.process.Child.Term {
    std.debug.assert(connection.state != .not_spawned);
    const code = try connection.adapter.wait();
    connection.state = .not_spawned;
    return code;
}

pub fn adapter_kill(connection: *Connection) !std.process.Child.Term {
    std.debug.assert(connection.state != .not_spawned);
    const code = try connection.adapter.kill();
    connection.state = .not_spawned;
    return code;
}

pub fn adapter_write_all(connection: *Connection, message: []const u8) !void {
    std.debug.assert(connection.state != .not_spawned);
    try connection.adapter.stdin.?.writer().writeAll(message);
}

pub fn new_seq(s: *Connection) i32 {
    const seq = s.seq;
    s.seq += 1;
    return @intCast(seq);
}

pub fn queue_messages(connection: *Connection, timeout_ms: u64) !void {
    const stdout = connection.adapter.stdout orelse return;
    if (try io.message_exists(stdout, connection.allocator, timeout_ms)) {
        const responses_capacity = connection.total_responses_received + 1;
        try connection.responses.ensureUnusedCapacity(1);
        try connection.handled_responses.ensureTotalCapacity(responses_capacity);
        try connection.debug_handled_responses.ensureTotalCapacity(responses_capacity);

        const events_capacity = connection.total_events_received + 1;
        try connection.events.ensureUnusedCapacity(1);
        try connection.handled_events.ensureTotalCapacity(events_capacity);
        try connection.debug_handled_events.ensureTotalCapacity(events_capacity);

        const parsed = try io.read_message(stdout, connection.allocator);
        errdefer {
            std.log.err("{}\n", .{parsed});
            parsed.deinit();
        }
        const object = if (parsed.value == .object) parsed.value.object else return error.InvalidMessage;
        const t = object.get("type") orelse return error.InvalidMessage;
        if (t != .string) return error.InvalidMessage;
        const string = t.string;

        if (std.mem.eql(u8, string, "response")) {
            const name = utils.pull_value(object.get("command"), .string) orelse "";
            log.debug("New response \"{s}\"", .{name});
            connection.responses.appendAssumeCapacity(parsed);
            connection.total_responses_received += 1;
        } else if (std.mem.eql(u8, string, "event")) {
            const name = utils.pull_value(object.get("event"), .string) orelse "";
            log.debug("New event \"{s}\"", .{name});
            connection.events.appendAssumeCapacity(parsed);
            connection.total_events_received += 1;
        } else {
            return error.UnknownMessage;
        }
    }
}

pub fn get_response_by_request_seq(connection: *Connection, request_seq: i32) !struct { RawMessage, usize } {
    for (connection.responses.items, 0..) |resp, i| {
        const object = resp.value.object; // messages shouldn't be queued up unless they're an object
        const raw_seq = object.get("request_seq") orelse continue;
        const seq = switch (raw_seq) {
            .integer => |int| int,
            else => return error.InvalidSeqFromAdapter,
        };
        if (seq == request_seq) {
            return .{ resp, i };
        }
    }

    return error.ResponseDoesNotExist;
}

pub fn get_event(connection: *Connection, name_or_seq: anytype) error{EventDoesNotExist}!struct { RawMessage, usize } {
    const T = @TypeOf(name_or_seq);
    const is_string = comptime utils.is_zig_string(T);
    if (T != i32 and !is_string) {
        @compileError("Event name_or_seq must be a []const u8 or an i32 found " ++ @typeName(T));
    }

    const key = if (T == i32) "seq" else "event";
    const wanted = if (T == i32) .integer else .string;
    for (connection.events.items, 0..) |event, i| {
        // messages shouldn't be queued up unless they're an object
        std.debug.assert(event.value == .object);
        const value = utils.get_value(event.value, key, wanted) orelse continue;
        if (T == i32) {
            if (name_or_seq == value) return .{ event, i };
        } else {
            if (std.mem.eql(u8, value, name_or_seq)) return .{ event, i };
        }
    }

    return error.EventDoesNotExist;
}

fn value_to_object_then_write(connection: *Connection, value: anytype) !void {
    try connection.value_to_object_then_inject_then_write(value, &.{}, .{});
}

fn value_to_object_then_inject_then_write(connection: *Connection, value: anytype, ancestors: []const []const u8, extra: protocol.Object) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // value to object
    var object = try utils.value_to_object(arena.allocator(), value);
    // inject
    if (extra.map.count() > 0) {
        var ancestor = try utils.object_ancestor_get(&object, ancestors);
        var iter = extra.map.iterator();
        while (iter.next()) |entry| {
            try ancestor.map.put(arena.allocator(), entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // write
    const message = try io.create_message(connection.allocator, object);
    defer connection.allocator.free(message);
    try connection.adapter_write_all(message);
}

pub fn wait_for_response(connection: *Connection, seq: i32) !void {
    while (true) {
        for (connection.responses.items) |item| {
            const request_seq = utils.pull_value(item.value.object.get("request_seq"), .integer) orelse continue;
            if (request_seq == seq) {
                return;
            }
        }
        try connection.queue_messages(std.time.ms_per_s);
    }
}

pub fn wait_for_event(connection: *Connection, name: []const u8) !i32 {
    while (true) {
        try connection.queue_messages(std.time.ms_per_s);
        for (connection.events.items) |item| {
            const value_event = item.value.object.get("event").?;
            const event = switch (value_event) {
                .string => |string| string,
                else => unreachable, // this shouldn't run unless the message is invalid
            };
            if (std.mem.eql(u8, name, event)) {
                const seq = utils.get_value(item.value, "seq", .integer) orelse continue;
                return @truncate(seq);
            }
        }
    }

    unreachable;
}

pub fn get_and_parse_response(connection: *Connection, comptime T: type, seq: i32) !std.json.Parsed(T) {
    const raw_resp, _ = try connection.get_response_by_request_seq(seq);
    return try std.json.parseFromValue(T, connection.allocator, raw_resp.value, .{ .ignore_unknown_fields = true });
}

pub fn get_parse_validate_response(connection: *Connection, comptime T: type, request_seq: i32, command: Command) !std.json.Parsed(T) {
    const raw_resp, _ = try connection.get_response_by_request_seq(request_seq);
    const resp = try std.json.parseFromValue(T, connection.allocator, raw_resp.value, .{ .ignore_unknown_fields = true });
    errdefer resp.deinit();
    try validate_response(resp.value, request_seq, command);

    return resp;
}

pub fn get_and_parse_event(connection: *Connection, comptime T: type, event: Event) !std.json.Parsed(T) {
    const raw_event, _ = try connection.get_event(@tagName(event));
    // this clones everything in the raw_event
    return try std.json.parseFromValue(T, connection.allocator, raw_event.value, .{});
}

fn validate_response(resp: anytype, request_seq: i32, command: Command) !void {
    if (!resp.success) return error.RequestFailed;
    if (resp.request_seq != request_seq) return error.RequestResponseMismatchedRequestSeq;
    if (!std.mem.eql(u8, resp.command, @tagName(command))) return error.WrongCommandForResponse;
}

const Cloner = struct {
    data: *Connection,
    allocator: std.mem.Allocator,
    pub fn clone_string(cloner: Cloner, string: []const u8) ![]const u8 {
        return try cloner.allocator.dupe(u8, string);
    }
};

fn create_cloner(connection: *Connection) Cloner {
    return Cloner{
        .data = connection,
        .allocator = connection.arena.allocator(),
    };
}
