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

        try std.Io.File.stdout().writeStreamingAll(io, file_contents);
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

    // Build request body
    var body_out: std.Io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();

    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(allocator);

    try messages.append(allocator, .{ .role = "user", .content = prompt_str });

    var jw: std.json.Stringify = .{ .writer = &body_out.writer };
    try jw.write(.{
        .model = "anthropic/claude-haiku-5.5",
        .messages = messages.items,
        .tools = all_tools,
    });
    const body = body_out.written();

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

    var response_out: std.Io.Writer.Allocating = .init(allocator);
    defer response_out.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
        },
        .response_writer = &response_out.writer,
    });
    const response_body = response_out.written();

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const choices = parsed.value.object.get("choices") orelse @panic("No choices in response");
    if (choices.array.items.len == 0) {
        @panic("No choices in response");
    }

    const message_json = choices.array.items[0].object.get("message") orelse return error.MissingMessage;

    const message = try std.json.parseFromValue(Message, allocator, message_json, .{ .ignore_unknown_fields = true });
    try messages.append(allocator, message.value);

    const tool_calls_json = message_json.object.get("tool_calls") orelse .null;

    const parsed_tool_calls = switch (tool_calls_json) {
        .null => null,
        .array => try std.json.parseFromValue([]const ToolCall, allocator, tool_calls_json, .{ .ignore_unknown_fields = true }),
        else => return error.InvalidToolCalls,
    };

    defer if (parsed_tool_calls) |parsed_tool_call| parsed_tool_call.deinit();

    const tool_calls: []const ToolCall = if (parsed_tool_calls) |calls| calls.value else &.{};

    if (tool_calls.len == 0) {
        const content = choices.array.items[0].object.get("message").?.object.get("content").?.string;
        try std.Io.File.stdout().writeStreamingAll(io, content);
    }

    blk: for (tool_calls) |tool_call| {
        const function_name = tool_call.function.name;
        inline for (tools) |T| {
            if (std.mem.eql(u8, function_name, T.schema.function.name)) {
                const result = try T.run(io, allocator, tool_call);
                try messages.append(allocator, .{ .role = "tool", .tool_call_id = tool_call.id, .content = result });
                continue :blk;
            }
        }
        return error.UnknownTool;
    }
}
