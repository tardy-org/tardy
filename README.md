# tardy

tardy *(def: delaying or delayed beyond the right or expected time; late.)* is an asynchronous runtime for writing applications and services in Zig.
Most of the code for this project originated in [zzz](https://github.com/tardy-org/zzz), a performance oriented networking framework.

- tardy utilizes the latest Asynchronous APIs while minimizing allocations.
- tardy natively supports Linux, Mac, BSD, and Windows.
- tardy is configurable, allowing you to optimize the runtime for your specific use-case.

[![Discord](https://img.shields.io/discord/1294761432922980392?logo=discord)](https://discord.gg/HNEszT7qSR)

## Summary
tardy is a thread-local, I/O driven runtime for Zig, providing the core implementation for asynchronous libraries and services.
- Per-thread Runtime isolation for minimal contention
- Native async I/O (io_uring, epoll, kqueue, poll, etc.)
- Asynchronous `Socket`s and `File`s.
- Coroutines (internally called Frames).

## Installing
Compatible Zig Version: `0.16.0`

Latest Release: `0.3.2`
```
zig fetch --save git+https://github.com/tardy-org/tardy#v0.3.2
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

const tardy = @import("tardy");
const AcceptResult = tardy.AcceptResult;
const Cross = tardy.Cross;
const Pool = tardy.Pool;
const RecvResult = tardy.RecvResult;
const Runtime = tardy.Runtime;
const SendResult = tardy.SendResult;
const Socket = tardy.Socket;
const Task = tardy.Task;
const Timer = tardy.Timer;

const Tardy = tardy.Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/echo");

fn echo_frame(rt: *Runtime, server: *const Socket) !void {
    const socket = try server.accept(rt);
    defer socket.close_blocking();

    var sock_reader = socket.reader(rt, &.{});
    const sock_r = &sock_reader.interface;

    var sock_writer = socket.writer(rt, &.{});
    const sock_w = &sock_writer.interface;
    defer sock_w.flush() catch unreachable;

    const time: std.Io.Timestamp = .now(rt.io, .awake);
    log.info(
        "{f} - accepted socket [{f}]",
        .{ time.untilNow(rt.io, .awake), socket.addr },
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

        log.info("Echoed: {s}", .{buffer[0..recv_length]});
    }
}

pub fn main(init: std.process.Init) !void {
    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(init.io, .{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(501);

    // tardy by default is
    // - multithreaded
    // - unbounded in terms of spawnable tasks
    var td: Tardy = try .init(init.gpa, init.io, .{
        .pooling = .static,
        .size_tasks_initial = 256,
        .size_aio_reap_max = 256,
    });
    defer td.deinit();

    try td.entry(
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
