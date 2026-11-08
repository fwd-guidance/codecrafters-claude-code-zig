const std = @import("std");

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

pub const Tool = struct {
    type: []const u8,
    function: struct { name: []const u8, description: []const u8, parameters: struct {
        type: []const u8,
        properties: struct {
            file_path: struct {
                type: []const u8,
                description: []const u8,
            },
        },
        required: []const []const u8,
    } },
};

pub const Read = struct {
    pub const Args = struct {
        file_path: []const u8,
    };

    pub const schema = Tool{
        .type = "function",
        .function = .{
            .name = "Read",
            .description = "Read and return the contents of a file",
            .parameters = .{
                .type = "object",
                .properties = .{
                    .file_path = .{
                        .type = "string",
                        .description = "The path to the file to read",
                    },
                },
                .required = &[_][]const u8{"file_path"},
            },
        },
    };

    pub fn run(io: std.Io, allocator: std.mem.Allocator, tool_call: ToolCall) ![]u8 {
        const parsed_function_arguments = try std.json.parseFromSlice(Read.Args, allocator, tool_call.function.arguments, .{});
        defer parsed_function_arguments.deinit();

        const file_path = parsed_function_arguments.value.file_path;

        const file_contents = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch |err| {
            switch (err) {
                // TODO: probably want to handle file erorrs
                else => return err,
            }
        };
        defer allocator.free(file_contents);

        //try std.Io.File.stdout().writeStreamingAll(io, file_contents);
        return file_contents;
    }
};

const tools = .{Read};

pub const all_tools = blk: {
    var schemas: [tools.len]Tool = undefined;
    for (tools, 0..) |T, i| schemas[i] = T.schema;
    break :blk schemas;
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Retain message strings, tool calls, and tool results across iterations.
    const history_allocator = init.arena.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();

    _ = arg_it.next(); // argv0
    const flag = arg_it.next() orelse @panic("Usage: main -p <prompt>");
    const prompt_str = arg_it.next() orelse @panic("Usage: main -p <prompt>");
    if (!std.mem.eql(u8, flag, "-p")) {
        @panic("Usage: main -p <prompt>");
    }

    const api_key = init.environ_map.get("OPENROUTER_API_KEY") orelse @panic("OPENROUTER_API_KEY is not set");
    const base_url = init.environ_map.get("OPENROUTER_BASE_URL") orelse "https://openrouter.ai/api/v1";

    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(allocator);

    try messages.append(allocator, .{ .role = "user", .content = prompt_str });

    // Build URL and auth header
    const url_str = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
    defer allocator.free(url_str);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    // Make HTTP request
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    while (true) {
        // Build request body
        var body_out: std.Io.Writer.Allocating = .init(allocator);
        defer body_out.deinit();

        var jw: std.json.Stringify = .{
            .writer = &body_out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        try jw.write(.{
            .model = "anthropic/claude-haiku-5.5",
            .messages = messages.items,
            .tools = all_tools,
        });

        var response_out: std.Io.Writer.Allocating = .init(allocator);
        defer response_out.deinit();
        const response = try client.fetch(.{
            .location = .{ .url = url_str },
            .method = .POST,
            .payload = body_out.written(),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth_value },
            },
            .response_writer = &response_out.writer,
        });

        if (response.status != .ok) {
            std.debug.print("Chat request failed (HTTP {d}): {s}\n", .{
                @backingInt(response.status), response_out.written(),
            });
            return error.ChatRequestFailed;
        }
        const response_body = response_out.written();

        // Parse response
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, history_allocator, response_body, .{ .allocate = .alloc_always });

        const choices = parsed.object.get("choices") orelse @panic("No choices in response");
        if (choices.array.items.len == 0) {
            @panic("No choices in response");
        }

        const message_json = choices.array.items[0].object.get("message") orelse return error.MissingMessage;

        const message = try std.json.parseFromValueLeaky(Message, history_allocator, message_json, .{ .ignore_unknown_fields = true });
        try messages.append(allocator, message);

        const tool_calls: []const ToolCall = message.tool_calls orelse &.{};

        if (tool_calls.len == 0) {
            if (message.content) |content| {
                try std.Io.File.stdout().writeStreamingAll(io, content);
            }
            break;
        }

        blk: for (tool_calls) |tool_call| {
            const function_name = tool_call.function.name;
            inline for (tools) |T| {
                if (std.mem.eql(u8, function_name, T.schema.function.name)) {
                    const result = try T.run(io, history_allocator, tool_call);
                    try messages.append(allocator, .{ .role = "tool", .tool_call_id = tool_call.id, .content = result });
                    continue :blk;
                }
            }
            return error.UnknownTool;
        }
    }
}
