# tardy

tardy *(def: delaying or delayed beyond the right or expected time; late.)* is an asynchronous runtime for writing applications and services in Zig.
Most of the code for this project originated in [zzz](https://github.com/tardy-org/zzz), a performance oriented networking framework.

- tardy utilizes the latest Asynchronous APIs while minimizing allocations.
- tardy natively supports Linux, Mac, BSD, and Windows.
- tardy is configurable, allowing you to optimize the runtime for your specific use-case.

[![Discord](https://img.shields.io/discord/1294761432922980392?logo=discord)](https://discord.gg/FP9Xb7WGPK)

## Summary
tardy is a thread-local, I/O driven runtime for Zig, providing the core implementation for asynchronous libraries and services.
- Per-thread Runtime isolation for minimal contention
- Native async I/O (io_uring, epoll, kqueue, poll, etc.)
- Asynchronous `Socket`s and `File`s.
- Coroutines (internally called Frames).

## Installing
Compatible Zig Version: `0.15.2`

Latest Release: `0.3.0`
```
zig fetch --save git+https://github.com/tardy-org/tardy#v0.3.0
```

You can then add the dependency in your `build.zig` file:
```zig
const tardy = b.dependency("tardy", .{
    .target = target,
    .optimize = optimize,
}).module("tardy");

exe_mod.addImport("tardy", tardy);
```

## Building and Running Examples
- NOTE: by default build/install step uses `-Dexample=none` , meaning it wont build any examples

- List available examples
```sh
zig build --help
```

- Build/run a specific example
```sh
zig build -Dexample=[nameOfExample]
```
```sh
zig build run -Dexample=[nameOfExample]
```

- Build all examples
```sh
zig build -Dexample=all
```

## TCP Example
A basic multi-threaded TCP echo server.

```zig
const std = @import("std");

const AcceptResult = @import("tardy").AcceptResult;
const Cross = @import("tardy").Cross;
const Pool = @import("tardy").Pool;
const RecvResult = @import("tardy").RecvResult;
const Runtime = @import("tardy").Runtime;
const SendResult = @import("tardy").SendResult;
const Socket = @import("tardy").Socket;
const Task = @import("tardy").Task;
const Timer = @import("tardy").Timer;

const Tardy = @import("tardy").Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/echo");

fn echo_frame(rt: *Runtime, server: *const Socket) !void {
    const socket = try server.accept(rt);
    defer socket.close_blocking();

    var sock_reader = socket.reader(rt, &.{});
    const sock_r = &sock_reader.interface;

    var sock_writer = socket.writer(rt, &.{});
    const sock_w = &sock_writer.interface;
    defer sock_w.flush() catch unreachable;

    log.debug(
        "{d} - accepted socket [{f}]",
        .{ std.time.milliTimestamp(), socket.addr },
    );

    // spawn off a new frame.
    try rt.spawn(.{ rt, server }, echo_frame, 1024 * 16);

    var buffer: [501]u8 = undefined;
    while (true) {
        const recv_length = sock_r.readSliceShort(&buffer) catch |e| {
            log.err("Failed to recv on socket | {t}", .{e});
            break;
        };

        if (recv_length == 0) return;

        sock_w.writeAll(buffer[0..recv_length]) catch |e| {
            log.err("Failed to send on socket | {t}", .{e});
            break;
        };

        log.debug("Echoed: {s}", .{buffer[0..recv_length]});
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tardy: Tardy = try .init(allocator, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 256,
        .size_aio_reap_max = 256,
    });
    defer tardy.deinit();

    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(.{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(1024);

    try tardy.entry(
        &server,
        struct {
            fn start(rt: *Runtime, tcp_server: *const Socket) !void {
                try rt.spawn(.{ rt, tcp_server }, echo_frame, 1024 * 16);
            }
        }.start,
    );
}
```

There exist a lot more examples, highlighting a variety of use cases and features [here](https://github.com/tardy-org/tardy/tree/main/examples). For an example of tardy in use, you can check out any of the projects in the [ecosystem](#ecosystem).

## Ecosystem
- [zzz](https://github.com/tardy-org/zzz): a framework for writing performant and reliable networked services.
- [secsock](https://github.com/tardy-org/secsock): Async TLS for the Tardy Socket.

## Contribution
We use Nix Flakes for managing the development environment. Nix Flakes provide a reproducible, declarative approach to managing dependencies and development tools.

### Prerequisites
 - Install [Nix](https://nixos.org/download/)
```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```
 - Enable [Flake support](https://nixos.wiki/wiki/Flakes) in your Nix config (`~/.config/nix/nix.conf`): `experimental-features = nix-command flakes`

### Getting Started
1. Clone this repository:
```bash
git clone https://github.com/tardy-org/tardy.git
cd tardy
```

2. Enter the development environment:
```bash
nix develop
```

This will provide you with a shell that contains all of the necessary tools and dependencies for development.

Once you are inside of the development shell, you can update the development dependencies by:
1. Modifying the `flake.nix`
2. Running `nix flake update`
3. Committing both the `flake.nix` and the `flake.lock`

### License
Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in tardy by you, shall be licensed as MPL2.0, without any additional terms or conditions.
