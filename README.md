# pike

A minimal cross-platform high-performance async I/O library written in [Zig](https://ziglang.org).

## Features

- [x] Reactor/proactor-based I/O notification support
    - [x] epoll (linux)
    - [x] kqueue (darwin)
    - [x] i/o completion ports (windows)
- [x] Async POSIX socket support
    - [x] `bind`, `listen`, `connect`, `accept`
    - [x] `read`, `recv`, `recvFrom`
    - [x] `write`, `send`, `sendTo`
    - [x] get/set socket options
- [x] Async Windows socket support
    - [x] `bind`, `listen`, `connect`, `accept`
    - [x] `read`, `recv`, `recvFrom`
    - [x] `write`, `send`, `sendTo`
    - [x] get/set socket options
- [x] Async signal support
    - [x] signalfd for epoll (linux)
    - [x] EVFILT_SIGNAL for kqueue (darwin)
    - [x] SetConsoleCtrlHandler for i/o completion ports (windows)
- [x] Async event support
    - [x] sigaction (posix)
    - [x] SetConsoleCtrlHandler (windows)

## Design

### Notifier

A `Notifier` notifies of the completion of I/O events, or of the read/write-readiness of registered file descriptors/handles.

Should a `Notifier` report the completion of I/O events, it is designated to wrap around a proactor-based I/O notification layer in the operating system such as I/O completion ports on Windows.

Should a `Notifier` report the read/write-readiness of registered file descriptors/handles, it is designated to wrap around a reactor-based I/O notification layer in the operating system such as epoll on Linux, or kqueue on Darwin-based operating systems.

The `Notifier`'s purpose is to drive the execution of asynchronous I/O syscalls upon the notification of a reactor/proactor-based I/O event by dispatching suspended asynchronous function frames to be resumed by a thread pool/scheduler (e.g. [kprotty/zap](https://github.com/kprotty/zap)).

### Handle

A `Handle`'s implementation is specific to a `Notifier` implementation, though overall wraps around and represents a file descriptor/handle in a program.

Subject to the `Notifier` implementation a `Handle`'s implementation falls under, state required to drive asynchronous I/O syscalls through a `Handle` is kept inside a `Handle`. 

An example would be an intrusive linked list of suspended asynchronous function frames that are to be resumed upon the recipient of a notification that a file descriptor/handle is ready to be written to/read from.