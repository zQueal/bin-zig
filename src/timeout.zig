//! Transfer deadlines for HTTP requests: stall detection plus bounded retries.
//!
//! The reference implementation has no transfer deadline, and neither does the
//! Zig 0.15.2 std HTTP client as used elsewhere in this port: if a peer (or a
//! middlebox on the way) stops sending data, the blocking read never returns and
//! `bin` hangs forever printing nothing. That is exactly what a large
//! `bin update` batch hit in the field.
//!
//! How the deadline is enforced:
//!
//!   * `Watch` is armed around one transfer attempt. Every byte read or written
//!     calls `touch()`, so what is measured is *inactivity*, not total transfer
//!     time: a slow but moving download is never killed, while one that goes
//!     silent for `--timeout` seconds is.
//!   * One watchdog thread (started lazily, only when the timeout is enabled)
//!     scans the armed watches every 200ms. On a stall it logs a clear warning,
//!     marks the watch (`stalled()`), and shuts down the socket the request is
//!     waiting on — which is what wakes a blocked read on POSIX.
//!   * Callers run each attempt on its own thread and wait with
//!     `waitForAttempt`, which returns as soon as the attempt finishes *or* the
//!     watch trips. A tripped attempt is abandoned (`Watch.abandon()` stops the
//!     watchdog tracking it) and the caller retries on a fresh connection. This
//!     is what makes the retry work on Windows, where the read cannot be woken
//!     at all: the abandoned thread stays parked in the kernel until exit.
//!   * Transfers that nobody abandons — the parallel-download chunks — keep a
//!     last-resort escalation: a tripped transfer that is still stuck after a
//!     grace period makes the watchdog exit the process, so `bin` can never
//!     hang forever in silence.
//!   * `Retrier` performs the bounded, backed-off retry of transfers that
//!     failed mid-flight.
//!
//! Windows specifics, all measured rather than assumed: shutting the socket
//! down does not wake a read parked in the Zig socket reader (it issues an
//! overlapped `WSARecv` and waits for completion), `SO_RCVTIMEO` has no effect
//! on that path, and cancelling the I/O trips the `unreachable` in std's
//! `WSA_OPERATION_ABORTED` handling. Abandoning the attempt needs no
//! cooperation from the blocked thread, which is why it is the mechanism used.
//!
//! Knobs: `--timeout <seconds>` / `BIN_TIMEOUT` (0 disables detection) and
//! `--retries <n>` / `BIN_RETRIES`.

const std = @import("std");
const builtin = @import("builtin");

/// Default inactivity budget in seconds. No legitimate transfer is silent for
/// this long, and it is short enough to fail before a user gives up on it.
pub const default_stall_seconds: u32 = 30;
/// Default number of *extra* attempts after a transfer fails mid-flight.
pub const default_retries: u32 = 2;

/// Seconds without a single byte before a transfer is aborted; 0 disables.
pub var stall_seconds: u32 = default_stall_seconds;
/// Extra attempts made when a transfer fails mid-flight.
pub var max_retries: u32 = default_retries;

/// Returned when the watchdog tripped and the attempt had to be abandoned.
pub const Stalled = error{Stalled};

const monitor_interval_ms = 200;
/// How long `waitForAttempt` sleeps between checks.
const attempt_poll_ms = 25;
/// How long to wait for a tripped transfer to unblock before giving up on the
/// whole process (only reachable for transfers nobody abandons).
const exit_grace_ms = 10_000;

/// Builds a short log label ("downloading <url>") in a caller-owned buffer.
pub fn label(buf: []u8, prefix: []const u8, url: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}", .{ prefix, url }) catch prefix;
}

pub const Watch = struct {
    label: []const u8 = "",
    /// Milliseconds of the last observed activity. Atomic because `touch()`
    /// runs on the transfer thread while the monitor reads it.
    last: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// The request the transfer is currently waiting on. Guarded by
    /// `registry_mutex`, since the monitor reads it while the transfer thread is
    /// blocked inside that very request and cannot synchronise itself.
    request: ?*const std.http.Client.Request = null,
    active: bool = false,
    tripped: bool = false,
    tripped_at: i64 = 0,

    /// Arms the watchdog for one transfer attempt. `label_text` must outlive it
    /// (the callers use a stack buffer in the retry loop, which does).
    pub fn begin(self: *Watch, label_text: []const u8) void {
        self.* = .{
            .label = label_text,
            .last = std.atomic.Value(i64).init(std.time.milliTimestamp()),
        };
        if (stall_seconds == 0) return;
        self.active = true;
        addWatch(self); // clears `active` again if the registry cannot take it
    }

    /// Disarms the watchdog after an attempt that finished. Safe to call on a
    /// watch that never armed or was already abandoned.
    pub fn end(self: *Watch) void {
        if (!self.active) return;
        removeWatch(self);
        self.active = false;
    }

    /// Stops watching an attempt whose thread is being abandoned: the caller is
    /// no longer waiting for its result, so the watchdog must not escalate to a
    /// process exit on its behalf. The abandoned thread may keep calling
    /// `touch()`/`trackRequest()`; both are no-ops once the watch is inactive.
    pub fn abandon(self: *Watch) void {
        if (!self.active) return;
        removeWatch(self);
        self.active = false;
    }

    /// Records progress. Called after every successful read/write.
    pub fn touch(self: *Watch) void {
        if (!self.active) return;
        self.last.store(std.time.milliTimestamp(), .release);
    }

    /// Records the request the transfer is currently waiting on, so the monitor
    /// can interrupt its socket. Call it for every step that starts a new
    /// connection: following a redirect swaps in a fresh one.
    pub fn trackRequest(self: *Watch, req: *const std.http.Client.Request) void {
        if (!self.active) return;
        registry_mutex.lock();
        defer registry_mutex.unlock();
        self.request = req;
    }

    /// True once the watchdog has tripped for this attempt.
    pub fn stalled(self: *const Watch) bool {
        return self.tripped;
    }
};

/// Waits for an attempt to finish and reports whether it got there. Returns
/// false when `watch` tripped first, meaning the caller should abandon the
/// attempt and retry instead of waiting for a read this platform may never wake.
pub fn waitForAttempt(watch: *Watch, done: *const std.atomic.Value(bool)) bool {
    while (true) {
        if (done.load(.acquire)) return true;
        if (watch.stalled()) return false;
        std.Thread.sleep(attempt_poll_ms * std.time.ns_per_ms);
    }
}

// ---------------------------------------------------------------------------
// Watchdog thread + registry
// ---------------------------------------------------------------------------

const max_watches = 64;

/// Guards every non-atomic `Watch` field and the registry itself. Lock order is
/// registry -> stderr (logging happens while it is held), the only order used.
var registry_mutex: std.Thread.Mutex = .{};
var registry: [max_watches]*Watch = undefined;
var registry_len: usize = 0;
var monitor_started = false;

fn addWatch(w: *Watch) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (registry_len == max_watches) {
        std.log.warn("stall watchdog is full ({d} transfers); timeout disabled for this one", .{max_watches});
        w.active = false;
        return;
    }
    registry[registry_len] = w;
    registry_len += 1;

    if (monitor_started) return;
    monitor_started = true;
    const thread = std.Thread.spawn(.{}, monitorLoop, .{}) catch |err| {
        std.log.warn("stall watchdog disabled (cannot spawn its thread: {s})", .{@errorName(err)});
        w.active = false;
        return;
    };
    thread.detach();
}

fn removeWatch(w: *Watch) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();

    for (registry[0..registry_len], 0..) |entry, i| {
        if (entry != w) continue;
        registry[i] = registry[registry_len - 1];
        registry_len -= 1;
        return;
    }
}

/// Tries to wake the socket the watch is waiting on. Called with
/// `registry_mutex` held; `w.request.connection` is read without further
/// synchronisation because the owning thread is blocked inside that very request
/// (a pointer load, and a stale value can only cost a useless `shutdown`).
///
/// This works on POSIX. On Windows it does not (`shutdown` does not wake a
/// receive that the socket reader has parked in an overlapped `WSARecv`), so
/// there the caller abandons the attempt instead — see the module docs.
fn interrupt(w: *Watch) void {
    if (w.request) |req| {
        if (req.connection) |conn| {
            const handle = conn.stream_reader.getStream().handle;
            std.posix.shutdown(handle, .both) catch {};
        }
    }
}

fn monitorLoop() void {
    while (true) {
        std.Thread.sleep(monitor_interval_ms * std.time.ns_per_ms);

        registry_mutex.lock();
        const now = std.time.milliTimestamp();
        for (registry[0..registry_len]) |w| {
            if (!w.active) continue;

            if (!w.tripped) {
                if (now - w.last.load(.acquire) < @as(i64, stall_seconds) * 1000) continue;
                w.tripped = true;
                w.tripped_at = now;
                // Reported as a warning: the attempt is retried, and only if it
                // cannot be given up on at all does an error-level line (or
                // `bin`'s own failure line) name a failure. It also keeps the
                // deliberately stalled transfer in the tests from being counted
                // as a logged error by the test runner.
                std.log.warn("no data received for {d}s while {s}: giving up on the stalled transfer", .{ stall_seconds, w.label });
                interrupt(w);
                continue;
            }

            if (now - w.tripped_at < exit_grace_ms) continue;
            std.log.err("stalled transfer could not be interrupted after {d}s; exiting", .{exit_grace_ms / 1000});
            std.process.exit(1);
        }
        registry_mutex.unlock();
    }
}

// ---------------------------------------------------------------------------
// Bounded retries
// ---------------------------------------------------------------------------

/// Errors worth another attempt: all of them mean a transfer stopped
/// mid-flight, as opposed to the server answering the request with a decision.
pub fn retryable(err: anyerror) bool {
    return switch (err) {
        error.Stalled,
        error.RequestFailed,
        error.DownloadFailed,
        error.ConnectionClosed,
        error.ConnectionResetByPeer,
        error.EndOfStream,
        error.BrokenPipe,
        error.NetworkSubsystemFailed,
        error.Unexpected,
        => true,
        else => false,
    };
}

fn errorLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.Stalled => "stalled transfer (no data received)",
        else => @errorName(err),
    };
}

pub const Retrier = struct {
    label: []const u8,
    attempt: u32 = 0,

    /// Decides whether `err` should be retried, announces the retry and sleeps
    /// with a small exponential backoff. Returns false when the caller has to
    /// propagate the error.
    pub fn shouldRetry(self: *Retrier, err: anyerror) bool {
        if (self.attempt >= max_retries or !retryable(err)) return false;
        self.attempt += 1;
        const shift: u6 = @intCast(@min(self.attempt - 1, 3));
        const delay_ms: u64 = @min(500 * (@as(u64, 1) << shift), 5_000);
        std.log.warn("{s} failed ({s}); retrying in {d}ms (attempt {d}/{d})", .{
            self.label,
            errorLabel(err),
            delay_ms,
            self.attempt + 1,
            max_retries + 1,
        });
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        return true;
    }
};

/// Applies `BIN_TIMEOUT` / `BIN_RETRIES`, then the `--timeout` / `--retries`
/// tokens that main.zig pulled out of argv (flags win over the environment).
pub fn configure(env: std.process.EnvMap, flag_args: []const []const u8) void {
    if (env.get("BIN_TIMEOUT")) |v| {
        if (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10)) |n| {
            stall_seconds = n;
        } else |_| {}
    }
    if (env.get("BIN_RETRIES")) |v| {
        if (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10)) |n| {
            max_retries = n;
        } else |_| {}
    }

    var i: usize = 0;
    while (i < flag_args.len) : (i += 1) {
        const a = flag_args[i];
        if (std.mem.eql(u8, a, "--timeout") or std.mem.eql(u8, a, "--retries")) {
            if (i + 1 >= flag_args.len) {
                std.log.warn("{s} requires a value", .{a});
                continue;
            }
            i += 1;
            apply(a, flag_args[i]);
        } else if (std.mem.startsWith(u8, a, "--timeout=")) {
            apply("--timeout", a["--timeout=".len..]);
        } else if (std.mem.startsWith(u8, a, "--retries=")) {
            apply("--retries", a["--retries=".len..]);
        }
    }
}

fn apply(flag: []const u8, value: []const u8) void {
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t"), 10) catch {
        std.log.warn("invalid value for {s}: \"{s}\"", .{ flag, value });
        return;
    };
    if (std.mem.eql(u8, flag, "--timeout")) {
        stall_seconds = n;
    } else {
        max_retries = n;
    }
}
