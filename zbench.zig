//!zig-autodoc-guide: docs/intro.md
//!zig-autodoc-guide: docs/quickstart.md
//!zig-autodoc-guide: docs/advanced.md

const std = @import("std");
const c = @import("./util/color.zig");
const format = @import("./util/format.zig");

/// Benchmark is a type representing a single benchmark session.
/// It provides metrics and utilities for performance measurement.
pub const Benchmark = struct {
    /// Timer used to track the duration of the benchmark.
    timer: std.time.Timer,
    /// Total number of operations performed during the benchmark.
    total_operations: usize = 0,
    /// Minimum duration recorded among all runs (initially set to the maximum possible value).
    min_duration: u64 = std.math.maxInt(u64),
    /// Maximum duration recorded among all runs.
    max_duration: u64 = 0,
    /// Maximum duration (approx) we are willing to wait for a benchmark
    max_duration_limit: u64,
    /// Maximum amount of runs to repeat for any given benchmark
    max_operations: u64,
    /// Total duration accumulated over all runs.
    total_duration: u64 = 0,
    /// A dynamic list storing the duration of each run.
    durations: std.ArrayList(u64),
    /// Memory allocator used by the benchmark.
    allocator: std.mem.Allocator,

    /// Initializes a new Benchmark instance.
    ///
    /// max_duration_limit: Max amount of time (in nanoseconds) we are willing
    /// to wait for any given invocation of `run`. Set this to a high number
    /// if you don't want time restrictions (ie. std.math.maxInt(u64)). NOTE: This
    /// is only an estimate and bench-runs may exceed the limit slightly.
    ///
    /// max_opererations: Maximum amount of benchmark-runs performed for any
    /// given invocation of `run`. This may be lower if the bench-time
    /// exceeds max_duration_estimate.
    ///
    /// allocator: Memory allocator to be used.
    pub fn init(
        max_duration_limit: u64,
        max_operations: u64,
        allocator: std.mem.Allocator,
    ) !Benchmark {
        const bench = Benchmark{
            .max_duration_limit = max_duration_limit,
            .max_operations = max_operations,
            .allocator = allocator,
            .timer = std.time.Timer.start() catch return error.TimerUnsupported,
            .durations = std.ArrayList(u64).init(allocator),
        };
        return bench;
    }

    /// Runner: Must be one of either -
    ///     Standalone function with *either* of the following signature/function type -
    ///         1: fn (std.mem.Allocator) void          : Required
    ///         2: fn () void                           : Required
    ///
    ///     Aggregate (Struct/Union/Enum) with following associated methods -
    ///         pub fn init(std.mem.Allocator) !Self    : Required
    ///         pub fn run(Self) void                   : Required
    ///         pub fn deinit(Self) void                : Optional
    ///         pub fn reset(Self) void                 : Optional
    ///
    /// NOTE:
    ///     `*Self` instead of `Self` also works for the above methods.
    ///
    ///     `reset` can be useful for increasing benchmarking speed. If it is
    ///     not supplied, the runner instance is "deinited" and "inited" between
    ///     every run.
    pub fn run(
        self: *Benchmark,
        comptime Runner: anytype,
        name: []const u8,
    ) !BenchmarkResult {
        const err_msg = "Benchmark.run: `Runner` must be an aggregate (Enum, Union or Struct), or a function.\nIf a function, it must have the signature `fn (std.mem.Allocator) void` or `fn () void`";
        // We hit this branch when runner is an aggregate (struct/enum/union)
        if (@TypeOf(Runner) == type) {
            const err_msg_aggregate = "Benchmark.run: `Runner` did not have both `run` and `init` as associated methods";
            const decls = switch (@typeInfo(Runner)) {
                .Struct => |agr| agr.decls,
                .Union => |agr| agr.decls,
                .Enum => |agr| agr.decls,

                else => @compileError(err_msg),
            };

            comptime var has_init = false;
            comptime var has_run = false;
            comptime var has_reset = false;
            comptime var has_deinit = false;
            comptime for (decls) |dec| {
                if (std.mem.eql(u8, dec.name, "reset")) {
                    has_reset = true;
                } else if (std.mem.eql(u8, dec.name, "deinit")) {
                    has_deinit = true;
                } else if (std.mem.eql(u8, dec.name, "init")) {
                    has_init = true;
                } else if (std.mem.eql(u8, dec.name, "run")) {
                    has_run = true;
                }
            };

            comptime if (!has_init or !has_run) @compileError(err_msg_aggregate);

            var run_instance = try Runner.init(self.allocator);
            while (self.total_duration < self.max_duration_limit and self.total_operations < self.max_operations) {
                self.start();
                run_instance.run();
                self.stop();

                self.total_operations += 1;

                if (has_reset) {
                    run_instance.reset();
                    continue;
                } else if (has_deinit) {
                    run_instance.deinit();
                }

                run_instance = try Runner.init(self.allocator);
            }

            if (has_deinit) run_instance.deinit();
        } else {
            while (self.total_duration < self.max_duration_limit and self.total_operations < self.max_operations) {
                self.start();

                if (@TypeOf(Runner) == fn (std.mem.Allocator) void) {
                    Runner(self.allocator);
                } else if (@TypeOf(Runner) == fn () void) {
                    Runner();
                } else {
                    @compileError(err_msg);
                }

                self.stop();

                self.total_operations += 1;
            }
        }

        const ret = BenchmarkResult{
            .name = name,
            .percs = self.calculatePercentiles(),
            .avg_duration = self.calculateAverage(),
            .std_duration = self.calculateStd(),
            .min_duration = self.min_duration,
            .max_duration = self.max_duration,
            .total_operations = self.total_operations,
        };

        self.reset();
        return ret;
    }

    /// Starts or restarts the benchmark timer.
    pub fn start(self: *Benchmark) void {
        self.timer.reset();
    }

    /// Stop the benchmark and record the duration
    pub fn stop(self: *Benchmark) void {
        const elapsedDuration = self.timer.read();
        self.total_duration += elapsedDuration;

        if (elapsedDuration < self.min_duration) self.min_duration = elapsedDuration;
        if (elapsedDuration > self.max_duration) self.max_duration = elapsedDuration;

        // NOTE: Why is the error conditon unreachable..?
        self.durations.append(elapsedDuration) catch unreachable;
    }

    /// Reset the benchmark
    pub fn reset(self: *Benchmark) void {
        self.total_operations = 0;
        self.min_duration = std.math.maxInt(u64);
        self.max_duration = 0;
        self.total_duration = 0;
        self.durations.clearRetainingCapacity();
    }

    pub fn quickSort(items: []u64, low: usize, high: usize) void {
        if (low < high) {
            const pivotIndex = partition(items, low, high);
            if (pivotIndex != 0) {
                quickSort(items, low, pivotIndex - 1);
            }
            quickSort(items, pivotIndex + 1, high);
        }
    }

    fn partition(items: []u64, low: usize, high: usize) usize {
        const pivot = items[high];
        var i = low;

        var j = low;
        while (j <= high) : (j += 1) {
            if (items[j] < pivot) {
                std.mem.swap(u64, &items[i], &items[j]);
                i += 1;
            }
        }
        std.mem.swap(u64, &items[i], &items[high]);
        return i;
    }

    /// Calculate the p75, p99, and p995 durations
    pub fn calculatePercentiles(self: Benchmark) Percentiles {
        // quickSort might fail with an empty input slice, so safety checks first
        const len = self.durations.items.len;
        if (len <= 1) {
            return Percentiles{ .p75 = 0, .p99 = 0, .p995 = 0 };
        }
        quickSort(self.durations.items, 0, len - 1);

        const p75Index: usize = len * 75 / 100;
        const p99Index: usize = len * 99 / 100;
        const p995Index: usize = len * 995 / 1000;

        const p75 = self.durations.items[p75Index];
        const p99 = self.durations.items[p99Index];
        const p995 = self.durations.items[p995Index];

        return Percentiles{ .p75 = p75, .p99 = p99, .p995 = p995 };
    }

    /// Calculate the average duration
    pub fn calculateAverage(self: Benchmark) u64 {
        // prevent division by zero
        const len = self.durations.items.len;
        if (len == 0) return 0;

        var sum: u64 = 0;
        for (self.durations.items) |duration| {
            sum += duration;
        }

        const avg = sum / len;

        return avg;
    }

    /// Calculate the standard deviation of the durations
    // NOTE: We are doing integer division, roots and unsafe casting..
    // Atleast it's very unlikely to overflow here, as this would
    // only happen if the duration variance is over 514 years, and it's reasonable
    // to assume no user will ever sit around and wait that for such a benchmark
    // to complete, to then be able to calculate its standard deviation..
    pub fn calculateStd(self: Benchmark) u64 {
        if (self.durations.items.len <= 1) return 0;

        const avg = self.calculateAverage();
        var nvar: u64 = 0;
        for (self.durations.items) |dur| {
            const d: i64 = @bitCast(dur);
            const a: i64 = @bitCast(avg);

            nvar += @bitCast((d - a) * (d - a));
        }

        return std.math.sqrt(nvar / (self.durations.items.len - 1));
    }

    pub fn deinit(self: Benchmark) void {
        self.durations.deinit();
    }
};

pub const Percentiles = struct {
    p75: u64,
    p99: u64,
    p995: u64,
};

/// BenchmarkResult stores the resulting computed metrics/statistics from a benchmark
pub const BenchmarkResult = struct {
    name: []const u8,
    percs: Percentiles,
    avg_duration: usize,
    std_duration: usize,
    min_duration: usize,
    max_duration: usize,
    total_operations: usize,

    pub fn prettyPrint(self: BenchmarkResult, header: bool) !void {
        var p75_buffer: [128]u8 = undefined;
        const p75_str = try format.duration(p75_buffer[0..], self.percs.p75);

        var p99_buffer: [128]u8 = undefined;
        const p99_str = try format.duration(p99_buffer[0..], self.percs.p99);

        var p995_buffer: [128]u8 = undefined;
        const p995_str = try format.duration(p995_buffer[0..], self.percs.p995);

        var avg_std_buffer: [128]u8 = undefined;
        var avg_std_offset = (try format.duration(avg_std_buffer[0..], self.avg_duration)).len;
        avg_std_offset += (try std.fmt.bufPrint(avg_std_buffer[avg_std_offset..], " ± ", .{})).len;
        avg_std_offset += (try format.duration(avg_std_buffer[avg_std_offset..], self.std_duration)).len;

        // FIXME: This looks quite ugly, maybe there's a better way to do all this?
        var min_max_buffer: [128]u8 = undefined;
        min_max_buffer[0] = '(';
        var min_max_offset = (try format.duration(min_max_buffer[1..], self.min_duration)).len + 1;
        min_max_offset += (try std.fmt.bufPrint(min_max_buffer[min_max_offset..], " ... ", .{})).len;
        min_max_offset += (try format.duration(min_max_buffer[min_max_offset..], self.max_duration)).len;
        min_max_buffer[min_max_offset] = ')';
        min_max_offset += 1;

        if (header) prettyPrintHeader();
        std.debug.print("{s:<25} \x1b[90m{d:<8} \x1b[33m{s:<22} \x1b[94m{s:<28} \x1b[90m{s:<10} \x1b[90m{s:<10} \x1b[90m{s:<10}\x1b[0m\n", .{ self.name, self.total_operations, avg_std_buffer[0..avg_std_offset], min_max_buffer[0..min_max_offset], p75_str, p99_str, p995_str });
    }
};

pub fn prettyPrintHeader() void {
    std.debug.print("{s:<25} {s:<8} {s:<22} {s:<28} {s:<10} {s:<10} {s:<10}\n", .{ "benchmark", "runs", "time (avg ± σ)", "(min ............. max)", "p75", "p99", "p995" });
    std.debug.print("---------------------------------------------------------------------------------------------------------------------\n", .{});
}

// TODO: Allow sorting by different metrics?
pub fn prettyPrintResults(results: []const BenchmarkResult, header: bool) !void {
    if (header) {
        prettyPrintHeader();
    }

    for (results) |res| try res.prettyPrint(false);
}
