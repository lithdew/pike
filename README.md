# pike

[![MIT License](https://img.shields.io/apm/l/atomic-design-ui.svg?)](LICENSE)
[![Discord Chat](https://img.shields.io/discord/697002823123992617)](https://discord.gg/HZEbkeQ)

A minimal cross-platform high-performance async I/O library written in [Zig](https://ziglang.org).

## Features

- [x] `async/await` support
- [x] epoll support
- [x] kqueue support 
- [x] IOCP support
- [x] Signal support
    - [x] epoll support
    - [x] kqueue support
    - [x] IOCP support
- [x] TCP sockets
- [ ] UDP sockets
- [ ] Unix sockets
- [ ] File I/O
- [ ] Pipe I/O

## Benchmarks

A naive single-threaded async TCP benchmark was ran using [examples/simple_tcp_client.zig](examples/simple_tcp_client.zig) and [tcpkali](https://github.com/satori-com/tcpkali) on loopback adapter, yielding roughly 3.3 to 6.2 GiB/sec. Using raw single-threaded epoll yields 10 GiB/sec.

```
$ tcpkali -l 9000 -T 10s
Listen on: [0.0.0.0]:9000
Listen on: [::]:9000
Total data sent:     0 bytes (0 bytes)
Total data received: 33913.7 MiB (35561095168 bytes)
Bandwidth per channel: 28444.604⇅ Mbps (3555575.5 kBps)
Aggregate bandwidth: 28444.604↓, 0.000↑ Mbps
Packet rate estimate: 2604182.4↓, 0.0↑ (12↓, 0↑ TCP MSS/op)
Test duration: 10.0015 s.
```