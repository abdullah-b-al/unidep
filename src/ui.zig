const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const Args = @import("main.zig").Args;
const request = @import("request.zig");
const io = @import("io.zig");
const handlers = @import("handlers.zig");
const Callbacks = handlers.Callbacks;
const config = @import("config.zig");
const log = std.log.scoped(.ui);

const Path = std.BoundedArray(u8, std.fs.max_path_bytes);

const State = struct {
    active_source_thread_id: ?i32 = null,
    active_source: union(enum) {
        path: Path,
        reference: i32,
        none,
    } = .none,

    home_path: Path = Path.init(0) catch unreachable,
    picker: ?Picker = null,

    launch_config_index: ?usize = null,
    ask_for_launch_config: bool = false,
    begin_session: bool = false,
    scroll_to_active_line: bool = false,
    update_active_source_to_top_of_stack: bool = false,
};

pub var state = State{};

pub fn init_ui(allocator: std.mem.Allocator) !*glfw.Window {
    try glfw.init();

    const gl_major = 4;
    const gl_minor = 0;
    glfw.windowHint(.context_version_major, gl_major);
    glfw.windowHint(.context_version_minor, gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    state.home_path = try Path.fromSlice(env_map.get("HOME") orelse "");

    const window = try glfw.Window.create(1000, 1000, "TestWindow:thabit", null);
    window.setSizeLimits(400, 400, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    // opengl
    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    // imgui
    zgui.init(allocator);
    zgui.io.setConfigFlags(.{ .dock_enable = true });

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    _ = zgui.io.addFontFromFile(
        "/home/ab55al/.local/share/fonts/JetBrainsMono-Regular.ttf",
        std.math.floor(24.0 * scale_factor),
    );

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);

    return window;
}

pub fn deinit_ui(window: *glfw.Window) void {
    zgui.backend.deinit();
    zgui.deinit();
    window.destroy();
    glfw.terminate();
}

pub fn ui_tick(window: *glfw.Window, callbacks: *Callbacks, connection: *Connection, data: *SessionData, args: Args) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const gl = zopengl.bindings;
    glfw.pollEvents();

    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 1.0 });

    const fb_size = window.getFramebufferSize();

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

    if (state.ask_for_launch_config) {
        state.ask_for_launch_config = !pick("Pick Launch configuration", config.launch, .launch_config);
    }

    if (state.begin_session) {
        state.begin_session = !(request.begin_session(arena.allocator(), connection) catch |err| blk: {
            log_err(err, @src());
            break :blk true;
        });
    }

    if (state.update_active_source_to_top_of_stack) blk: {
        state.update_active_source_to_top_of_stack = false;
        if (thread_of_active_source(data.*)) |thread| {
            if (thread.stack.items.len > 0) {
                const source = thread.stack.items[0].source orelse break :blk;
                const eql = switch (state.active_source) {
                    .none => break :blk,
                    .path => |path| utils.source_is(source, path.slice()),
                    .reference => |ref| utils.source_is(source, ref),
                };

                if (eql) set_active_source(thread.id, source, true);
            }
        } else if (data.threads.get(state.active_source_thread_id orelse break :blk)) |thread| {
            if (thread.stack.items.len > 0) {
                const source = thread.stack.items[0].source orelse break :blk;
                set_active_source(thread.id, source, true);
            }
        }
    }

    const action = get_action();
    if (action) |act| {
        handle_action(act, callbacks, data, connection) catch return;
    }

    const static = struct {
        var built_layout = false;
    };
    if (!static.built_layout) {
        static.built_layout = true;
        var dockspace_id = zgui.DockSpaceOverViewport(0, zgui.getMainViewport(), .{});

        zgui.dockBuilderRemoveNode(dockspace_id);
        const viewport = zgui.getMainViewport();
        const empty = zgui.dockBuilderAddNode(dockspace_id, .{});
        zgui.dockBuilderSetNodeSize(empty, viewport.getSize());

        const dock_main_id: ?*zgui.Ident = &dockspace_id;
        const id_console = zgui.dockBuilderSplitNode(dock_main_id.?.*, .down, 0.30, null, &dockspace_id);

        const id_threads = zgui.dockBuilderSplitNode(dock_main_id.?.*, .right, 0.30, null, &dockspace_id);
        // const id_threads = zgui.dockBuilderSplitNode(dock_main_id.?.*, .none, 0.50, null, &id_sources);

        zgui.dockBuilderDockWindow("Source Code", dockspace_id);

        // tabbed
        zgui.dockBuilderDockWindow("Threads", id_threads);
        zgui.dockBuilderDockWindow("Sources", id_threads);

        zgui.dockBuilderDockWindow("Console", id_console);

        zgui.dockBuilderFinish(dockspace_id);

        _ = zgui.DockSpace("Main DockSpace", viewport.getSize(), .{});
    }

    source_code(arena.allocator(), "Source Code", data, connection);
    console(arena.allocator(), "Console", data.*, connection);
    threads(arena.allocator(), "Threads", callbacks, data, connection);
    sources(arena.allocator(), "Sources", data.*, connection);

    debug_ui(arena.allocator(), callbacks, connection, data, args) catch |err| std.log.err("{}", .{err});

    zgui.backend.draw();

    window.swapBuffers();
}

fn source_code(arena: std.mem.Allocator, name: [:0]const u8, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (zgui.begin(name, .{})) {}

    const key, const content = get_source_content_of_active_source(data) orelse {
        // Let's try again next frame
        set_source_content_of_active_source(arena, data, connection) catch |err| {
            log.err("{}", .{err});
        };
        return;
    };

    const frame = get_frame_of_source_content(data.*, key);

    if (!zgui.beginTable("Source Code Table", .{
        .column = 2,
        .flags = .{
            .sizing = .fixed_fit,
            .borders = .{
                .inner_h = false,
                .outer_h = false,
                .inner_v = true,
                .outer_v = false,
            },
        },
    })) return;
    defer zgui.endTable();

    const dl = zgui.getWindowDrawList();
    const line_height = zgui.getTextLineHeightWithSpacing();
    const window_width = zgui.getWindowWidth();

    var iter = std.mem.splitScalar(u8, content.content, '\n');
    var line_number: usize = 0;
    while (iter.next()) |line| {
        defer line_number += 1;
        const active_line = if (frame) |f| (f.line == line_number) else false;

        zgui.tableNextRow(.{});

        if (zgui.tableSetColumnIndex(0)) { // line numbers
            if (active_line) {
                const pos = zgui.getCursorScreenPos();
                dl.addRectFilled(.{
                    .pmin = pos,
                    .pmax = .{ pos[0] + window_width, pos[1] + line_height },
                    .col = color_u32(.text_selected_bg),
                });
            }
            if (zgui.selectable(
                tmp_name("##Source Code Selectable {}", .{line_number}),
                .{ .flags = .{ .span_all_columns = true } },
            )) {
                // TODO
            }
            zgui.sameLine(.{ .spacing = 0 });

            if (zgui.isItemClicked(.right)) {
                // TODO
            }

            zgui.text("{} ", .{line_number + 1});
        }

        var pos: [2]f32 = .{ 0, 0 };
        if (zgui.tableSetColumnIndex(1)) { // text
            pos = zgui.getCursorScreenPos();
            zgui.text("{s}", .{line});
        }

        if (active_line) {
            const f = frame.?;
            if (f.column < line.len) {
                const column: usize = @intCast(@max(0, f.column - 1));
                const size = zgui.calcTextSize(line[0..column], .{});
                const char = zgui.calcTextSize(line[column .. column + 1], .{});

                const x = pos[0] + size[0];
                const y = pos[1] + size[1];
                dl.addLine(.{
                    .p1 = .{ x, y },
                    .p2 = .{ x + char[0], y },
                    .col = color_u32(.text),
                    .thickness = 1,
                });
            }

            if (state.scroll_to_active_line) {
                state.scroll_to_active_line = false;
                zgui.setScrollHereY(.{ .center_y_ratio = 0.5 });
            }
        }
    }
}

fn sources(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    _ = arena;
    defer zgui.end();
    if (zgui.begin(name, .{})) {}

    const fn_name = @src().fn_name;
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    for (data.sources.items) |source| {
        const source_path = if (source.path) |path| tmp_shorten_path(path) else null;
        const label = if (source_path) |path|
            std.fmt.bufPrintZ(&buf, "{s}##" ++ fn_name, .{path}) catch return
        else if (source.sourceReference) |ref|
            std.fmt.bufPrintZ(&buf, "{s}({})##" ++ fn_name, .{ source.name orelse "", ref }) catch return
        else
            return;

        if (zgui.button(label, .{})) {
            if (thread_of_source(source, data)) |thread| {
                set_active_source(thread.id, source, true);
            } else {
                set_active_source(null, source, true);
            }
        }
    }
}

fn threads(arena: std.mem.Allocator, name: [:0]const u8, callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    _ = arena;

    defer zgui.end();
    if (zgui.begin(name, .{})) {}

    { // buttons
        // line 1
        if (zgui.button("Lock All", .{})) {
            var iter = data.threads.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.unlocked = false;
            }
        }

        zgui.sameLine(.{});
        if (zgui.button("Unlock All", .{})) {
            var iter = data.threads.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.unlocked = true;
            }
        }

        // line 2

        if (zgui.button("Pause", .{})) {
            request.pause(data.*, connection);
        }
        zgui.sameLine(.{});
        if (zgui.button("Continue", .{})) {
            request.continue_threads(data.*, connection);
        }

        // line 3
        if (zgui.button("Next Line", .{})) {
            request.next(callbacks, data.*, connection, .line);
        }
        zgui.sameLine(.{});
        if (zgui.button("Next Statement", .{})) {
            request.next(callbacks, data.*, connection, .statement);
        }
        zgui.sameLine(.{});
        if (zgui.button("Next Instruction", .{})) {
            request.next(callbacks, data.*, connection, .instruction);
        }
    } // buttons

    _ = zgui.beginChild("Code View", .{});
    defer zgui.endChild();

    var style = zgui.getStyle();
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;
        const style_idx: zgui.StyleCol = if (thread.unlocked) .text else .text_disabled;
        zgui.pushStyleColor4f(.{ .idx = .text, .c = style.getColor(style_idx) });
        defer zgui.popStyleColor(.{ .count = 1 });

        {
            const label = if (thread.unlocked) "Lock  " else "Unlock";
            if (zgui.button(tmp_name("{s}##{}", .{ label, thread.id }), .{})) {
                thread.unlocked = !thread.unlocked;
            }
        }

        zgui.sameLine(.{});

        const stack_name = tmp_name("{s} #{}", .{ thread.name, thread.id });
        if (zgui.treeNode(stack_name)) {
            zgui.indent(.{ .indent_w = 1 });

            for (thread.stack.items) |frame| {
                if (zgui.selectable(tmp_name("{s}", .{frame.name}), .{})) {
                    if (frame.source) |s| set_active_source(thread.id, s, true);
                }
            }

            zgui.unindent(.{ .indent_w = 1 });
            zgui.treePop();
        }
    }
}

fn console(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;

    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.output.items) |item| {
        zgui.text("{s}", .{item.body.output});
    }
}

fn debug_threads(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const table = .{
        .{ .name = "Actions" },
        .{ .name = "ID" },
        .{ .name = "Name" },
        .{ .name = "State" },
    };

    const columns_count = std.meta.fields(@TypeOf(table)).len;
    if (zgui.beginTable("Thread Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        defer zgui.endTable();
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        var iter = data.threads.iterator();
        while (iter.next()) |entry| {
            const thread = entry.value_ptr;
            zgui.tableNextRow(.{});
            { // column 1
                _ = zgui.tableNextColumn();
                if (zgui.button(tmp_name("Get Full State##{*}", .{entry.key_ptr}), .{})) {
                    request.get_thread_state(connection, thread.id) catch return;
                }
                if (zgui.button(tmp_name("Stack Trace##{*}", .{entry.key_ptr}), .{})) {
                    const args = protocol.StackTraceArguments{
                        .threadId = thread.id,
                        .startFrame = null, // request all frames
                        .levels = null, // request all levels
                        .format = null,
                    };
                    _ = connection.queue_request(.stackTrace, args, .none, .{
                        .stack_trace = .{
                            .thread_id = thread.id,
                            .request_scopes = false,
                            .request_variables = false,
                        },
                    }) catch return;
                }

                zgui.sameLine(.{});
                if (zgui.button(tmp_name("Scopes##{*}", .{entry.key_ptr}), .{})) {
                    for (thread.stack.items) |frame| {
                        _ = connection.queue_request(
                            .scopes,
                            protocol.ScopesArguments{ .frameId = frame.id },
                            .none,
                            .{ .scopes = .{ .frame_id = frame.id, .request_variables = false } },
                        ) catch return;
                    }
                }

                zgui.sameLine(.{});
                if (zgui.button(tmp_name("Variables##{*}", .{entry.key_ptr}), .{})) {
                    for (data.scopes.items) |scope_entry| {
                        for (scope_entry.data) |scope| {
                            _ = connection.queue_request(
                                .variables,
                                protocol.VariablesArguments{ .variablesReference = scope.variablesReference },
                                .none,
                                .{ .variables = .{ .variables_reference = scope.variablesReference } },
                            ) catch return;
                        }
                    }
                }
            } // column 1

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.id, .{})});

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.name, .{})});

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.state, .{})});
        }
    }
}

fn debug_modules(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData) void {
    _ = arena;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const table = .{
        .{ .name = "ID", .field = "id" },
        .{ .name = "Name", .field = "name" },
        .{ .name = "Path", .field = "path" },
        .{ .name = "Address Range", .field = "addressRange" },
        .{ .name = "Optimized", .field = "isOptimized" },
        .{ .name = "Is User Code", .field = "isUserCode" },
        .{ .name = "Version", .field = "version" },
        .{ .name = "Symbol Status", .field = "symbolStatus" },
        .{ .name = "Symbol File Path", .field = "symbolFilePath" },
        .{ .name = "Date Timestamp", .field = "dateTimeStamp" },
    };
    const columns_count = std.meta.fields(@TypeOf(table)).len;

    if (zgui.beginTable("Modules Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.modules.items) |module| {
            zgui.tableNextRow(.{});
            inline for (table) |entry| {
                _ = zgui.tableNextColumn();
                const value = @field(module, entry.field);
                zgui.text("{s}", .{anytype_to_string(value, .{
                    .value_for_null = "Unknown",
                })});
            }
        }
        zgui.endTable();
    }
}

fn debug_stack_frames(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "Thread ID {}##variables slice", .{thread.id}) catch return;
        draw_table_from_slice_of_struct(n, protocol.StackFrame, thread.stack.items);
        zgui.newLine();
    }
}

fn debug_scopes(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.scopes.items) |item| {
        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "Frame ID {}##scopes slice", .{item.frame_id}) catch return;
        draw_table_from_slice_of_struct(n, protocol.Scope, item.data);
        zgui.newLine();
    }
}

fn debug_variables(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.variables.items) |item| {
        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "Reference {}##variables slice", .{item.reference}) catch return;
        draw_table_from_slice_of_struct(n, protocol.Variable, item.data);
        zgui.newLine();
    }
}

fn debug_breakpoints(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    draw_table_from_slice_of_struct("breakpoints", protocol.Breakpoint, data.breakpoints.items);
}

fn debug_sources(arena: std.mem.Allocator, name: [:0]const u8, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const columns_count = std.meta.fields(protocol.Source).len + 1;
    if (zgui.beginTable("Source Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        zgui.tableSetupColumn("Actions", .{});
        inline for (std.meta.fields(protocol.Source)) |field| {
            zgui.tableSetupColumn(field.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.sources.items, 0..) |source, i| {
            const button_name = std.fmt.allocPrintZ(arena, "Get Content##{}", .{i}) catch return;
            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            if (zgui.button(button_name, .{})) blk: {
                if (source.path) |path| {
                    const key, const new_source = io.open_file_as_source_content(arena, path) catch break :blk;
                    data.set_source_content(key, new_source) catch break :blk;
                } else {
                    _ = connection.queue_request(
                        .source,
                        protocol.SourceArguments{
                            .source = source,
                            .sourceReference = source.sourceReference.?,
                        },
                        .none,
                        .{ .source = .{ .path = source.path, .source_reference = source.sourceReference.? } },
                    ) catch return;
                }
            }

            inline for (std.meta.fields(protocol.Source)) |field| {
                _ = zgui.tableNextColumn();
                const value = @field(source, field.name);
                zgui.text("{s}", .{anytype_to_string(value, .{})});
            }
        }
        zgui.endTable();
    }
}

fn debug_sources_content(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    zgui.text("len {}", .{data.sources_content.count()});
    zgui.newLine();

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Sources Content Tabs", .{})) return;

    var buf: [512:0]u8 = undefined;
    var sources_iter = data.sources_content.iterator();
    var i: usize = 0;
    while (sources_iter.next()) |entry| : (i += 1) {
        const key = entry.key_ptr.*;
        const content = entry.value_ptr.*;

        const tab_name = switch (key) {
            .path => |path| std.fmt.bufPrintZ(&buf, "{s}##Sources", .{path}) catch continue,
            else => std.fmt.bufPrintZ(&buf, "{}##Sources", .{i}) catch continue,
        };

        const active_line: ?i32 = blk: {
            const frame = get_frame_of_source_content(data, key) orelse break :blk null;
            break :blk frame.line;
        };

        var line_number: i32 = 0;
        if (zgui.beginTabItem(tab_name, .{})) {
            defer zgui.endTabItem();

            var iter = std.mem.splitScalar(u8, content.content, '\n');
            while (iter.next()) |line| {
                const color: [4]f32 = if (active_line == line_number) .{ 1, 0, 0, 1 } else .{ 1, 1, 1, 1 };
                zgui.textColored(color, "{s}", .{line});

                line_number += 1;
            }
        }
    }
}

fn debug_ui(arena: std.mem.Allocator, callbacks: *Callbacks, connection: *Connection, data: *SessionData, args: Args) !void {
    _ = callbacks;

    const static = struct {
        var built_layout = false;
    };
    if (!static.built_layout) {
        static.built_layout = true;
        const dockspace_id = zgui.DockSpaceOverViewport(1000, zgui.getMainViewport(), .{});

        zgui.dockBuilderRemoveNode(dockspace_id);
        const viewport = zgui.getMainViewport();
        const empty = zgui.dockBuilderAddNode(dockspace_id, .{});
        zgui.dockBuilderSetNodeSize(empty, viewport.getSize());

        // const dock_main_id: ?*zgui.Ident = &dockspace_id; // This variable will track the document node, however we are not using it here as we aren't docking anything into it.
        // const left = zgui.dockBuilderSplitNode(dock_main_id.?.*, .left, 0.50, null, dock_main_id);
        // const right = zgui.dockBuilderSplitNode(dock_main_id.?.*, .right, 0.50, null, dock_main_id);

        // dock them tabbed
        zgui.dockBuilderDockWindow("Debug General", empty);
        zgui.dockBuilderDockWindow("Debug Modules", empty);
        zgui.dockBuilderDockWindow("Debug Threads", empty);
        zgui.dockBuilderDockWindow("Debug Stack Frames", empty);
        zgui.dockBuilderDockWindow("Debug Scopes", empty);
        zgui.dockBuilderDockWindow("Debug Variables", empty);
        zgui.dockBuilderDockWindow("Debug Breakpoints", empty);
        zgui.dockBuilderDockWindow("Debug Sources", empty);
        zgui.dockBuilderDockWindow("Debug Sources Content", empty);

        zgui.dockBuilderFinish(dockspace_id);

        _ = zgui.DockSpace("Debug DockSpace", viewport.getSize(), .{});
    }

    debug_modules(arena, "Debug Modules", data.*);
    debug_threads(arena, "Debug Threads", data.*, connection);
    debug_stack_frames(arena, "Debug Stack Frames", data.*, connection);
    debug_scopes(arena, "Debug Scopes", data.*, connection);
    debug_variables(arena, "Debug Variables", data.*, connection);
    debug_breakpoints(arena, "Debug Breakpoints", data.*, connection);
    debug_sources(arena, "Debug Sources", data, connection);
    debug_sources_content(arena, "Debug Sources Content", data.*, connection);

    var open: bool = true;
    zgui.showDemoWindow(&open);

    defer zgui.end();
    if (!zgui.begin("Debug General", .{})) return;

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Debug Tabs", .{})) return;

    if (zgui.beginTabItem("Manully Send Requests", .{})) {
        defer zgui.endTabItem();
        try manual_requests(arena, connection, data, args);
    }

    if (zgui.beginTabItem("Adapter Capabilities", .{})) {
        defer zgui.endTabItem();
        adapter_capabilities(connection.*);
    }

    if (zgui.beginTabItem("Sent Requests", .{})) {
        defer zgui.endTabItem();
        for (connection.debug_requests.items) |item| {
            var buf: [512]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "seq({?}){s}", .{ item.debug_request_seq, @tagName(item.command) }) catch unreachable;
            recursively_draw_protocol_object(arena, slice, slice, .{ .object = item.args });
        }
    }

    const table = .{
        .{ .name = "Queued Messages", .items = connection.messages.items },
        .{ .name = "Debug Handled Responses", .items = connection.debug_handled_responses.items },
        .{ .name = "Debug Failed Messages", .items = connection.debug_failed_messages.items },
        .{ .name = "Debug Handled Events", .items = connection.debug_handled_events.items },
    };
    inline for (table) |element| {
        if (zgui.beginTabItem(element.name, .{})) {
            defer zgui.endTabItem();
            for (element.items) |resp| {
                const seq = resp.value.object.get("seq").?.integer;
                var buf: [512]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "seq[{}]", .{seq}) catch unreachable;
                recursively_draw_object(arena, slice, slice, resp.value);
            }
        }
    }

    if (zgui.beginTabItem("Handled Responses", .{})) {
        defer zgui.endTabItem();
        draw_table_from_slice_of_struct(@typeName(Connection.HandledResponse), Connection.HandledResponse, connection.handled_responses.items);
    }

    if (zgui.beginTabItem("Handled Events", .{})) {
        defer zgui.endTabItem();
        for (connection.handled_events.items) |item| {
            zgui.text("{s}", .{@tagName(item.event)});
        }
    }

    if (zgui.beginTabItem("Queued Requests", .{})) {
        defer zgui.endTabItem();
        draw_table_from_slice_of_struct(@typeName(Connection.Request), Connection.Request, connection.queued_requests.items);
        // for (connection.queued_requests.items) |item| {
        //     zgui.text("{s}", .{
        //         @tagName(item.command),
        //     });
        // }
    }
}

fn adapter_capabilities(connection: Connection) void {
    if (connection.state == .not_spawned) return;

    var iter = connection.adapter_capabilities.support.iterator();
    while (iter.next()) |e| {
        const name = @tagName(e);
        var color = [4]f32{ 1, 1, 1, 1 };
        if (std.mem.endsWith(u8, name, "Request")) {
            color = .{ 0, 0, 1, 1 };
        }
        zgui.textColored(color, "{s}", .{name});
    }

    const c = connection.adapter_capabilities;
    if (c.completionTriggerCharacters) |chars| {
        for (chars) |string| {
            zgui.text("completionTriggerCharacters {s}", .{string});
        }
    } else {
        zgui.text("No completionTriggerCharacters", .{});
    }
    if (c.supportedChecksumAlgorithms) |checksum| {
        for (checksum) |kind| {
            zgui.text("supportedChecksumAlgorithms.{s}", .{@tagName(kind)});
        }
    } else {
        zgui.text("No supportedChecksumAlgorithms", .{});
    }

    draw_table_from_slice_of_struct(@typeName(protocol.ExceptionBreakpointsFilter), protocol.ExceptionBreakpointsFilter, c.exceptionBreakpointFilters);
    draw_table_from_slice_of_struct(@typeName(protocol.ColumnDescriptor), protocol.ColumnDescriptor, c.additionalModuleColumns);
    draw_table_from_slice_of_struct(@typeName(protocol.BreakpointMode), protocol.BreakpointMode, c.breakpointModes);
}

fn manual_requests(arena: std.mem.Allocator, connection: *Connection, data: *SessionData, args: Args) !void {
    _ = args;
    const static = struct {
        var name_buf: [512:0]u8 = .{0} ** 512;
        var source_buf: [512:0]u8 = .{0} ** 512;
    };

    draw_launch_configurations(config.launch);

    zgui.text("Adapter State: {s}", .{@tagName(connection.state)});
    zgui.text("Debuggee Status: {s}", .{anytype_to_string(data.status, .{ .show_union_name = true })});

    if (zgui.button("Begin Debug Sequence", .{})) {
        state.begin_session = true;
    }

    zgui.sameLine(.{});
    zgui.text("or", .{});

    zgui.sameLine(.{});
    if (zgui.button("Spawn Adapter", .{})) {
        try connection.adapter_spawn();
    }

    zgui.sameLine(.{});
    if (zgui.button("Initialize Adapter", .{})) {
        const init_args = protocol.InitializeRequestArguments{
            .clientName = "thabit",
            .adapterID = "???",
            .columnsStartAt1 = false,
            .linesStartAt1 = false,
        };

        try connection.queue_request_init(init_args, .none);
    }

    zgui.sameLine(.{});
    if (zgui.button("Send Launch Request", .{})) {
        request.launch(arena, connection, .{ .dep = .{ .response = .initialize }, .handled_when = .before_queueing }) catch |err| switch (err) {
            error.NoLaunchConfig => state.ask_for_launch_config = true,
            else => log_err(err, @src()),
        };
    }

    zgui.sameLine(.{});
    if (zgui.button("Send configurationDone Request", .{})) {
        _ = try connection.queue_request_configuration_done(null, .{
            .map = .{},
        }, .{ .dep = .{ .event = .initialized }, .handled_when = .before_queueing });
    }

    if (zgui.button("end connection: disconnect", .{})) {
        try request.end_session(connection, .disconnect);
    }

    if (zgui.button("end connection: terminate", .{})) {
        try request.end_session(connection, .terminate);
    }

    if (zgui.button("Threads", .{})) {
        _ = try connection.queue_request(.threads, null, .none, .no_data);
    }

    _ = zgui.inputText("source reference", .{ .buf = &static.source_buf });
    if (zgui.button("Source Content", .{})) blk: {
        const len = std.mem.indexOfScalar(u8, &static.source_buf, 0) orelse static.source_buf.len;
        const id = static.source_buf[0..len];
        const number = std.fmt.parseInt(i32, id, 10) catch break :blk;
        const source = data.get_source_by_reference(number);
        if (source) |s| {
            _ = try connection.queue_request(
                .source,
                protocol.SourceArguments{
                    .source = s,
                    .sourceReference = s.sourceReference.?,
                },
                .none,
                .{ .source = .{ .path = s.path, .source_reference = s.sourceReference.? } },
            );
        }
    }

    if (zgui.button("Request Set Function Breakpoint", .{})) {
        _ = try connection.queue_request(
            .setFunctionBreakpoints,
            protocol.SetFunctionBreakpointsArguments{
                .breakpoints = data.function_breakpoints.items,
            },
            .none,
            .no_data,
        );
    }

    zgui.newLine();
    _ = zgui.inputText("Function name", .{ .buf = &static.name_buf });
    if (zgui.button("Add Function Breakpoint", .{})) {
        const len = std.mem.indexOfScalar(u8, &static.name_buf, 0) orelse static.name_buf.len;
        try data.add_function_breakpoint(.{
            .name = static.name_buf[0..len],
        });

        static.name_buf[0] = 0; // clear
    }
    zgui.sameLine(.{});
    if (zgui.button("Remove Function Breakpoint", .{})) {
        const len = std.mem.indexOfScalar(u8, &static.name_buf, 0) orelse static.name_buf.len;
        data.remove_function_breakpoint(static.name_buf[0..len]);
        static.name_buf[0] = 0; // clear
    }
    draw_table_from_slice_of_struct("Function Breakpoints", protocol.FunctionBreakpoint, data.function_breakpoints.items);
}

fn draw_table_from_slice_of_struct(name: [:0]const u8, comptime T: type, mabye_value: ?[]const T) void {
    const visiable_name = blk: {
        var iter = std.mem.splitAny(u8, name, "##");
        break :blk iter.next().?;
    };
    zgui.text("{s} len({})", .{ visiable_name, (mabye_value orelse &.{}).len });
    const table = std.meta.fields(T);
    const columns_count = std.meta.fields(T).len;
    if (zgui.beginTable(
        name,
        .{ .column = columns_count, .flags = .{
            .resizable = true,
            .context_menu_in_body = true,
            .borders = .{ .inner_h = true, .outer_h = true, .inner_v = true, .outer_v = true },
        } },
    )) {
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        if (mabye_value) |value| {
            for (value) |v| {
                zgui.tableNextRow(.{});
                inline for (std.meta.fields(@TypeOf(v))) |field| {
                    const info = @typeInfo(field.type);
                    const field_value = @field(v, field.name);
                    _ = zgui.tableNextColumn();
                    if (info == .pointer and info.pointer.child != u8) { // assume slice
                        for (field_value, 0..) |inner_v, i| {
                            if (i < field_value.len - 1) {
                                zgui.text("{s},", .{anytype_to_string(inner_v, .{})});
                                zgui.sameLine(.{});
                            } else {
                                zgui.text("{s}", .{anytype_to_string(inner_v, .{})});
                            }
                        }
                    } else {
                        zgui.text("{s}", .{anytype_to_string(field_value, .{})});
                    }
                }
            }
        }

        zgui.endTable();
    }
}

fn recursively_draw_object(allocator: std.mem.Allocator, parent: []const u8, name: []const u8, value: std.json.Value) void {
    switch (value) {
        .object => |object| {
            const object_name = allocator.dupeZ(u8, name) catch return;

            if (zgui.treeNode(object_name)) {
                zgui.indent(.{ .indent_w = 1 });
                var iter = object.iterator();
                while (iter.next()) |kv| {
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}.{s}", .{ parent, kv.key_ptr.* }) catch unreachable;
                    recursively_draw_object(allocator, slice, slice, kv.value_ptr.*);
                }
                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .array => |array| {
            const array_name = allocator.dupeZ(u8, name) catch return;
            if (zgui.treeNode(array_name)) {
                zgui.indent(.{ .indent_w = 1 });

                for (array.items, 0..) |item, i| {
                    zgui.indent(.{ .indent_w = 1 });
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}[{}]", .{ parent, i }) catch unreachable;
                    recursively_draw_object(allocator, slice, slice, item);
                    zgui.unindent(.{ .indent_w = 1 });
                }

                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .number_string, .string => |v| {
            var color = [4]f32{ 1, 1, 1, 1 };
            if (std.mem.endsWith(u8, name, "event") or std.mem.endsWith(u8, name, "command")) {
                color = .{ 0.5, 0.5, 1, 1 };
            }
            zgui.textColored(color, "{s} = \"{s}\"", .{ name, v });
        },
        inline else => |v| {
            zgui.text("{s} = {}", .{ name, v });
        },
    }
}

fn recursively_draw_protocol_object(allocator: std.mem.Allocator, parent: []const u8, name: []const u8, value: protocol.Value) void {
    switch (value) {
        .object => |object| {
            const object_name = allocator.dupeZ(u8, name) catch return;

            if (zgui.treeNode(object_name)) {
                zgui.indent(.{ .indent_w = 1 });
                var iter = object.map.iterator();
                while (iter.next()) |kv| {
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}.{s}", .{ parent, kv.key_ptr.* }) catch unreachable;
                    recursively_draw_protocol_object(allocator, slice, slice, kv.value_ptr.*);
                }
                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .array => |array| {
            const array_name = allocator.dupeZ(u8, name) catch return;
            if (zgui.treeNode(array_name)) {
                zgui.indent(.{ .indent_w = 1 });

                for (array.items, 0..) |item, i| {
                    zgui.indent(.{ .indent_w = 1 });
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}[{}]", .{ parent, i }) catch unreachable;
                    recursively_draw_protocol_object(allocator, slice, slice, item);
                    zgui.unindent(.{ .indent_w = 1 });
                }

                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .number_string, .string => |v| {
            var color = [4]f32{ 1, 1, 1, 1 };
            if (std.mem.endsWith(u8, name, "event") or std.mem.endsWith(u8, name, "command")) {
                color = .{ 0.5, 0.5, 1, 1 };
            }
            zgui.textColored(color, "{s} = \"{s}\"", .{ name, v });
        },
        inline else => |v| {
            zgui.text("{s} = {}", .{ name, v });
        },
    }
}

fn bool_to_string(opt_bool: ?bool) []const u8 {
    const result = opt_bool orelse return "Unknown";
    return if (result) "True" else "False";
}

fn mabye_string_to_string(string: ?[]const u8) []const u8 {
    return string orelse "";
}

fn protocol_value_to_string(value: protocol.Value) []const u8 {
    switch (value) {
        .string => |string| return string,
        else => @panic("TODO"),
    }
}

const ToStringOptions = struct {
    show_union_name: bool = false,
    value_for_null: []const u8 = "null",
};
fn anytype_to_string(value: anytype, opts: ToStringOptions) []const u8 {
    const static = struct {
        var buffer: [10_000]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    };
    static.fixed.reset();
    return anytype_to_string_recurse(static.fixed.allocator(), value, opts);
}

fn anytype_to_string_recurse(allocator: std.mem.Allocator, value: anytype, opts: ToStringOptions) []const u8 {
    const T = @TypeOf(value);
    if (T == []const u8) {
        return mabye_string_to_string(value);
    }

    switch (@typeInfo(T)) {
        .bool => return bool_to_string(value),
        .float, .int => {
            return std.fmt.allocPrint(allocator, "{}", .{value}) catch unreachable;
        },
        .@"enum" => return @tagName(value),
        .@"union" => {
            switch (value) {
                inline else => |v| {
                    var name_prefix: []const u8 = "";
                    if (opts.show_union_name) {
                        name_prefix = std.fmt.allocPrint(allocator, "{s} = ", .{@tagName(std.meta.activeTag(value))}) catch unreachable;
                    }

                    if (@TypeOf(v) == void) {
                        return @tagName(std.meta.activeTag(value));
                    } else {
                        return std.fmt.allocPrint(allocator, "{s}{s}", .{
                            name_prefix,
                            anytype_to_string_recurse(allocator, v, opts),
                        }) catch unreachable;
                    }
                },
            }
        },
        .@"struct" => |info| {
            var list = std.ArrayList(u8).init(allocator);
            var writer = list.writer();
            inline for (info.fields, 0..) |field, i| {
                writer.print("{s}: {s}", .{
                    field.name,
                    anytype_to_string_recurse(allocator, @field(value, field.name), opts),
                }) catch unreachable;

                if (i < info.fields.len - 1) {
                    _ = writer.write("\n") catch unreachable;
                }
            }

            return list.items;
        },
        .pointer => return @typeName(T),
        .optional => return anytype_to_string_recurse(allocator, value orelse return opts.value_for_null, opts),
        else => {},
    }

    return switch (T) {
        []const u8 => mabye_string_to_string(value),
        // *std.array_hash_map.IndexHeader => {},
        protocol.Value => protocol_value_to_string(value),
        protocol.Object => @panic("TODO"),
        protocol.Array => @panic("TODO"),
        std.debug.SafetyLock => return @typeName(T),
        inline else => @compileError(@typeName(T)),
    };
}

fn get_frame_of_source_content(data: SessionData, key: SessionData.SourceContentKey) ?protocol.StackFrame {
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        for (thread.stack.items) |frame| {
            const source: protocol.Source = frame.source orelse continue;
            const eql = switch (key) {
                .path => |path| path.len > 0 and std.mem.eql(u8, source.path orelse "", path),
                .reference => |ref| ref == source.sourceReference,
            };

            if (eql) {
                return frame;
            }
        }
    }

    return null;
}

fn get_stack_of_frame(data: *const SessionData, frame: protocol.StackFrame) ?SessionData.Stack {
    for (data.stacks.items) |*stack| {
        if (utils.entry_exists(stack.data, "id", frame.id)) {
            return stack.*;
        }
    }

    return null;
}

pub fn get_source_content_of_active_source(data: *const SessionData) ?struct { SessionData.SourceContentKey, SessionData.SourceContent } {
    const entry = switch (state.active_source) {
        .none => return null,
        .path => |path| data.sources_content.getEntry(.{ .path = path.slice() }),
        .reference => |ref| data.sources_content.getEntry(.{ .reference = ref }),
    };

    return if (entry) |e|
        .{ e.key_ptr.*, e.value_ptr.* }
    else
        null;
}

pub fn set_source_content_of_active_source(arena: std.mem.Allocator, data: *SessionData, connection: *Connection) !void {
    return switch (state.active_source) {
        .none => return,
        .path => |path| {
            _, const content = try io.open_file_as_source_content(arena, path.slice());
            try data.set_source_content(.{ .path = path.slice() }, content);
        },
        .reference => |reference| {
            _ = try connection.queue_request(.source, protocol.SourceArguments{
                .source = null,
                .sourceReference = reference,
            }, .none, .{
                .source = .{ .path = null, .source_reference = reference },
            });
        },
    };
}

fn color_u32(tag: zgui.StyleCol) u32 {
    const color = zgui.getStyle().getColor(tag);
    return zgui.colorConvertFloat4ToU32(color);
}

fn tmp_name(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const static = struct {
        var buf: [1024]u8 = undefined;
    };

    return std.fmt.bufPrintZ(&static.buf, fmt, args) catch @panic("oh no!");
}

fn tmp_shorten_path(path: []const u8) []const u8 {
    const static = struct {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
    };

    const count = std.mem.replace(u8, path, state.home_path.slice(), "~", &static.buf);
    const len = if (count > 0) path.len - state.home_path.len + 1 else path.len;
    return static.buf[0..len];
}

fn set_active_source(thread_id: ?i32, source: protocol.Source, scroll_to_active_line: bool) void {
    if (source.sourceReference) |ref| {
        state.active_source = .{ .reference = ref };
    } else if (source.path) |path| {
        state.active_source = .{
            .path = Path.fromSlice(path) catch return,
        };
    }

    state.scroll_to_active_line = scroll_to_active_line;
    state.active_source_thread_id = thread_id;
}

fn thread_of_active_source(data: SessionData) ?SessionData.Thread {
    const thread = data.threads.get(state.active_source_thread_id orelse return null) orelse return null;
    for (thread.stack.items) |frame| {
        const source = frame.source orelse continue;
        const eql = switch (state.active_source) {
            .none => return null,
            .path => |path| utils.source_is(source, path.slice()),
            .reference => |ref| utils.source_is(source, ref),
        };

        if (eql) {
            return thread;
        }
    }

    return null;
}

fn thread_of_source(source: protocol.Source, data: SessionData) ?SessionData.Thread {
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        for (thread.stack.items) |frame| {
            const s = frame.source orelse continue;
            const eql = if (s.path != null and source.path != null)
                std.mem.eql(u8, s.path.?, source.path.?)
            else if (s.sourceReference != null and source.sourceReference != null)
                s.sourceReference.? == source.sourceReference.?
            else
                false;

            if (eql) {
                return thread.*;
            }
        }
    }

    return null;
}

fn draw_launch_configurations(maybe_launch: ?config.Launch) void {
    const launch = maybe_launch orelse return;

    const table = .{
        .{ .name = "Key" },
        .{ .name = "Value" },
    };

    const columns_count = std.meta.fields(@TypeOf(table)).len;

    for (launch.configurations, 0..) |conf, i| {
        const name = tmp_name("Launch Configuration {}", .{i});
        if (zgui.beginTable(name, .{ .column = columns_count, .flags = .{ .resizable = true } })) {
            defer zgui.endTable();
            inline for (table) |entry| zgui.tableSetupColumn(entry.name, .{});
            zgui.tableHeadersRow();

            var iter = conf.map.iterator();
            while (iter.next()) |entry| {
                zgui.tableNextRow(.{});

                _ = zgui.tableNextColumn();
                zgui.text("{s}", .{entry.key_ptr.*});
                _ = zgui.tableNextColumn();
                const value = entry.value_ptr.*;
                if (@TypeOf(value) == std.json.Value and value == .array) {
                    zgui.text("[", .{});
                    for (value.array.items, 0..) |item, ai| {
                        const last = ai + 1 == value.array.items.len;
                        zgui.sameLine(.{});
                        if (!last) {
                            zgui.text("{s},", .{anytype_to_string(item, .{})});
                        } else {
                            zgui.text("{s}", .{anytype_to_string(item, .{})});
                        }
                    }
                    zgui.sameLine(.{});
                    zgui.text("]", .{});
                } else {
                    zgui.text("{s}", .{anytype_to_string(value, .{})});
                }
            }
        }
    }
}

fn pick(name: [:0]const u8, args: anytype, comptime widget: std.meta.Tag(Picker.Widget)) bool {
    if (state.picker == null) {
        state.picker = Picker{};
    }
    // keep the state of the widget alive between frames
    if (std.meta.activeTag(state.picker.?.widget) != widget) {
        state.picker.?.widget = @unionInit(Picker.Widget, @tagName(widget), .{});
    }
    const done = state.picker.?.begin(args, name);
    state.picker.?.end();

    if (done) {
        state.picker = null;
    }
    return done;
}

pub const Picker = struct {
    var window_x: f32 = 0;
    var window_y: f32 = 0;
    var fit_window_in_display = false;

    pub const NextResult = struct {
        size: [2]f32,
        hovered: bool = false,
        clicked: bool = false,
        double_clicked: bool = false,
    };

    pub const Widget = union(enum) {
        none,
        launch_config: LaunchConfig,
    };

    selected_index: usize = 0,

    widget: Widget = .none,

    pub fn begin(picker: *Picker, args: anytype, name: [:0]const u8) bool {
        const display_size = zgui.io.getDisplaySize();
        if (fit_window_in_display) {
            fit_window_in_display = false;
            zgui.setNextWindowSize(.{
                .w = display_size[0],
                .h = display_size[1],
                .cond = .always,
            });
        }
        zgui.setNextWindowPos(.{
            .x = window_x,
            .y = window_y,
            .cond = .always,
        });

        var open = true;
        zgui.openPopup(name, .{});
        const escaped = zgui.isKeyDown(.escape);
        if (!escaped and zgui.beginPopupModal(name, .{ .popen = &open })) {
            defer zgui.endPopup();

            { // center the window
                const window_size = zgui.getWindowSize();
                window_x = (display_size[0] / 2) - (window_size[0] / 2);
                window_y = (display_size[1] / 2) - (window_size[1] / 2);

                if (window_size[0] > display_size[0] or window_size[1] > display_size[1]) {
                    fit_window_in_display = true;
                }
            }

            picker.widget_begin();
            defer picker.widget_end();

            var i: usize = 0;
            while (true) : (i += 1) {
                const start = zgui.getCursorScreenPos();
                const result = picker.widget_next(args) orelse break;

                var color = zgui.getStyle().getColor(.text_selected_bg);
                if (result.clicked) {
                    picker.selected_index = i;
                }

                if (result.double_clicked) {
                    picker.widget_confirm(args, picker.selected_index);
                    return true;
                }

                if (result.hovered) {
                    color[3] = 0.25;
                    zgui.getWindowDrawList().addRectFilled(.{
                        .pmin = start,
                        .pmax = .{ start[0] + result.size[0], start[1] + result.size[1] },
                        .col = zgui.colorConvertFloat4ToU32(color),
                    });
                }

                if (i == picker.selected_index) {
                    color[3] = 0.5;
                    zgui.getWindowDrawList().addRectFilled(.{
                        .pmin = start,
                        .pmax = .{ start[0] + result.size[0], start[1] + result.size[1] },
                        .col = zgui.colorConvertFloat4ToU32(color),
                    });
                }
            }
        } else {
            return true;
        }

        return false;
    }

    pub fn end(_: *Picker) void {}

    pub fn widget_begin(picker: *Picker) void {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.begin(),
        };
    }

    pub fn widget_end(picker: *Picker) void {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.end(),
        };
    }

    pub fn widget_next(picker: *Picker, args: anytype) ?NextResult {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.next(args),
        };
    }

    pub fn widget_confirm(picker: *Picker, args: anytype, index: usize) void {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.confirm(args, index),
        };
    }

    pub const LaunchConfig = struct {
        i: usize = 0,
        show_table_for: [512]bool = .{false} ** 512,

        pub fn begin(widget: *LaunchConfig) void {
            zgui.text("Right click to see full configuration", .{});
            widget.i = 0;
        }
        pub fn end(_: *LaunchConfig) void {}

        pub fn next(widget: *LaunchConfig, maybe_launch: ?config.Launch) ?NextResult {
            defer widget.i += 1;
            const launch = maybe_launch orelse return null;
            if (widget.i >= launch.configurations.len) return null;

            const conf = launch.configurations[widget.i];
            if (widget.show_table_for[widget.i]) {
                const name = tmp_name("Launch Configuration {}", .{widget.i});
                return widget.show_table(name, launch);
            } else {
                var name: []const u8 = tmp_name("Launch Configuration {}", .{widget.i});
                if (conf.map.get("name")) |n| if (n == .string) {
                    name = n.string;
                };
                zgui.text("{s}", .{name});
                if (zgui.isItemClicked(.right)) {
                    widget.show_table_for[widget.i] = true;
                }
                return .{
                    .size = zgui.getItemRectSize(),
                    .hovered = zgui.isItemHovered(.{}),
                    .clicked = zgui.isItemClicked(.left),
                    .double_clicked = zgui.isItemClicked(.left) and zgui.isMouseDoubleClicked(.left),
                };
            }

            return null;
        }

        pub fn confirm(_: *LaunchConfig, maybe_launch: ?config.Launch, index: usize) void {
            const launch = maybe_launch orelse return;
            if (index < launch.configurations.len) {
                state.launch_config_index = index;
            }
        }

        pub fn show_table(widget: *LaunchConfig, name: [:0]const u8, launch: config.Launch) ?NextResult {
            const table = .{
                .{ .name = "Key" },
                .{ .name = "Value" },
            };

            const columns_count = std.meta.fields(@TypeOf(table)).len;

            const conf = launch.configurations[widget.i];
            if (zgui.beginTable(name, .{ .column = columns_count, .flags = .{
                .sizing = .fixed_fit,
                .borders = .{ .outer_h = true, .outer_v = true },
            } })) {
                inline for (table) |entry| zgui.tableSetupColumn(entry.name, .{});

                var iter = conf.map.iterator();
                while (iter.next()) |entry| {
                    zgui.tableNextRow(.{});

                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{entry.key_ptr.*});
                    _ = zgui.tableNextColumn();
                    const value = entry.value_ptr.*;
                    if (@TypeOf(value) == std.json.Value and value == .array) {
                        zgui.text("[", .{});
                        for (value.array.items, 0..) |item, ai| {
                            const last = ai + 1 == value.array.items.len;
                            zgui.sameLine(.{});
                            if (!last) {
                                zgui.text("{s},", .{anytype_to_string(item, .{})});
                            } else {
                                zgui.text("{s}", .{anytype_to_string(item, .{})});
                            }
                        }
                        zgui.sameLine(.{});
                        zgui.text("]", .{});
                    } else {
                        zgui.text("{s}", .{anytype_to_string(value, .{})});
                    }
                }

                zgui.endTable();
                if (zgui.isItemClicked(.right)) {
                    widget.show_table_for[widget.i] = false;
                }
                return .{
                    .size = zgui.getItemRectSize(),
                    .hovered = zgui.isItemHovered(.{}),
                    .clicked = zgui.isItemClicked(.left),
                    .double_clicked = zgui.isItemClicked(.left) and zgui.isMouseDoubleClicked(.left),
                };
            }

            return null;
        }
    };
};

fn log_err(err: anyerror, src: std.builtin.SourceLocation) void {
    log.err("{} {s}:{}:{} {s}()", .{
        err,
        src.file,
        src.line,
        src.column,
        src.fn_name,
    });
}

fn get_action() ?config.Action {
    const mods = config.Key.Mods.init(.{
        .shift = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift),
        .control = zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl),
        .alt = zgui.isKeyDown(.left_alt) or zgui.isKeyDown(.right_alt),
    });

    var iter = config.mappings.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const action = entry.value_ptr.*;
        if (zgui.isKeyPressed(key.key, true) and key.mods.eql(mods)) {
            return action;
        }
    }

    return null;
}

fn handle_action(action: config.Action, callbacks: *Callbacks, data: *SessionData, connection: *Connection) !void {
    switch (action) {
        .continue_threads => request.continue_threads(data.*, connection),
        .pause => request.pause(data.*, connection),
        .next_line => request.next(callbacks, data.*, connection, .line),
        .next_statement => request.next(callbacks, data.*, connection, .statement),
        .next_instruction => request.next(callbacks, data.*, connection, .instruction),
        .begin_session => state.begin_session = true,
    }
}
