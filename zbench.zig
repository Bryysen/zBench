//!zig-autodoc-guide: docs/intro.md
//!zig-autodoc-guide: docs/quickstart.md
//!zig-autodoc-guide: docs/advanced.md

const std = @import("std");
const log = std.log.scoped(.zbench);

const c = @import("./util/color.zig");
const format = @import("./util/format.zig");

/// Benchmark is a type representing a single benchmark session.
/// It provides metrics and utilities for performance measurement.
pub const Benchmark = struct {
    /// Name of the benchmark.
    name: []const u8,
    /// Number of iterations to be performed in the benchmark.
    N: usize = 1,
    /// Timer used to track the duration of the benchmark.
    timer: std.time.Timer,
    /// Total number of operations performed during the benchmark.
    total_operations: usize = 0,
    /// Minimum duration recorded among all runs (initially set to the maximum possible value).
    min_duration: u64 = std.math.maxInt(u64),
    /// Maximum duration recorded among all runs.
    max_duration: u64 = 0,
    /// Total duration accumulated over all runs.
    total_duration: u64 = 0,
    /// A dynamic list storing the duration of each run.
    durations: std.ArrayList(u64),
    /// Memory allocator used by the benchmark.
    allocator: std.mem.Allocator,

    /// Initializes a new Benchmark instance.
    /// name: A string representing the benchmark's name.
    /// allocator: Memory allocator to be used.
    pub fn init(name: []const u8, allocator: std.mem.Allocator) !Benchmark {
        const bench = Benchmark{
            .name = name,
            .allocator = allocator,
            .timer = std.time.Timer.start() catch return error.TimerUnsupported,
            .durations = std.ArrayList(u64).init(allocator),
        };
        return bench;
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

    /// Returns the elapsed time since the benchmark started.
    pub fn elapsed(self: *Benchmark) u64 {
        var sum: u64 = 0;
        for (self.durations.items) |duration| {
            sum += duration;
        }
        return sum;
    }

    /// Sets the total number of operations performed.
    /// ops: Number of operations.
    pub fn setTotalOperations(self: *Benchmark, ops: usize) void {
        self.total_operations = ops;
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
        var lastIndex: usize = 0;
        if (len > 1) {
            lastIndex = len - 1;
        } else {
            log.debug("Cannot calculate percentiles: recorded less than two durations", .{});
            return Percentiles{ .p75 = 0, .p99 = 0, .p995 = 0 };
        }
        quickSort(self.durations.items, 0, lastIndex - 1);

        const p75Index: usize = len * 75 / 100;
        const p99Index: usize = len * 99 / 100;
        const p995Index: usize = len * 995 / 1000;

        const p75 = self.durations.items[p75Index];
        const p99 = self.durations.items[p99Index];
        const p995 = self.durations.items[p995Index];

        return Percentiles{ .p75 = p75, .p99 = p99, .p995 = p995 };
    }

    /// Prints a report of total operations and timing statistics.
    /// (Similar to BenchmarkResult.prettyPrint)
    pub fn report(self: Benchmark) !void {
        const percentiles = self.calculatePercentiles();

        var total_time_buffer: [128]u8 = undefined;
        const total_time_str = try format.duration(total_time_buffer[0..], self.elapsed());

        var p75_buffer: [128]u8 = undefined;
        const p75_str = try format.duration(p75_buffer[0..], percentiles.p75);

        var p99_buffer: [128]u8 = undefined;
        const p99_str = try format.duration(p99_buffer[0..], percentiles.p99);

        var p995_buffer: [128]u8 = undefined;
        const p995_str = try format.duration(p995_buffer[0..], percentiles.p995);

        var avg_std_buffer: [128]u8 = undefined;
        var avg_std_offset = (try format.duration(avg_std_buffer[0..], self.calculateAverage())).len;
        avg_std_offset += (try std.fmt.bufPrint(avg_std_buffer[avg_std_offset..], " ± ", .{})).len;
        avg_std_offset += (try format.duration(avg_std_buffer[avg_std_offset..], self.calculateStd())).len;
        const avg_std_str = avg_std_buffer[0..avg_std_offset];

        var min_buffer: [128]u8 = undefined;
        const min_str = try format.duration(min_buffer[0..], self.min_duration);

        var max_buffer: [128]u8 = undefined;
        const max_str = try format.duration(max_buffer[0..], self.max_duration);

        var min_max_buffer: [128]u8 = undefined;
        const min_max_str = try std.fmt.bufPrint(min_max_buffer[0..], "({s} ... {s})", .{ min_str, max_str });

        const stdout = std.io.getStdOut().writer();
        prettyPrintHeader();
        try stdout.print("---------------------------------------------------------------------------------------------------------------\n", .{});
        try stdout.print(
            "{s:<22} \x1b[90m{d:<8} \x1b[90m{s:<10} \x1b[33m{s:<22} \x1b[95m{s:<28} \x1b[90m{s:<10} {s:<10} {s:<10}\x1b[0m\n\n",
            .{ self.name, self.total_operations, total_time_str, avg_std_str, min_max_str, p75_str, p99_str, p995_str },
        );
        try stdout.print("\n", .{});
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
    pub fn calculateStd(self: Benchmark) u64 {
        if (self.durations.items.len <= 1) return 0;

        const avg = self.calculateAverage();
        var nvar: u64 = 0;
        for (self.durations.items) |dur| {
            // NOTE: With realistic real-life samples this will never overflow,
            // however a solution without bitcasts would still be cleaner
            const d: i64 = @bitCast(dur);
            const a: i64 = @bitCast(avg);

            nvar += @bitCast((d - a) * (d - a));
        }

        // We are using the non-biased estimator for the variance; sum(Xi - μ)^2 / (n - 1)
        return std.math.sqrt(nvar / (self.durations.items.len - 1));
    }
};

/// BenchFunc is a function type that represents a benchmark function.
/// It takes a pointer to a Benchmark object.
pub const BenchFunc = fn (*Benchmark) void;

/// BenchmarkResult stores the resulting computed metrics/statistics from a benchmark
pub const BenchmarkResult = struct {
    name: []const u8,
    percs: Percentiles,
    avg_duration: usize,
    std_duration: usize,
    min_duration: usize,
    max_duration: usize,
    total_operations: usize,
    total_time: usize,

    /// Formats and prints the benchmark result in a readable format.
    pub fn prettyPrint(self: BenchmarkResult, header: bool) !void {
        var total_time_buffer: [128]u8 = undefined;
        const total_time_str = try format.duration(total_time_buffer[0..], self.total_time);

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
        const avg_std_str = avg_std_buffer[0..avg_std_offset];

        var min_buffer: [128]u8 = undefined;
        const min_str = try format.duration(min_buffer[0..], self.min_duration);

        var max_buffer: [128]u8 = undefined;
        const max_str = try format.duration(max_buffer[0..], self.max_duration);

        var min_max_buffer: [128]u8 = undefined;
        const min_max_str = try std.fmt.bufPrint(min_max_buffer[0..], "({s} ... {s})", .{ min_str, max_str });

        if (header) try prettyPrintHeader();

        const stdout = std.io.getStdOut().writer();
        try stdout.print(
            "{s:<22} \x1b[90m{d:<8} \x1b[90m{s:<14} \x1b[33m{s:<22} \x1b[95m{s:<28} \x1b[90m{s:<10} {s:<10} {s:<10}\x1b[0m\n\n",
            .{ self.name, self.total_operations, total_time_str, avg_std_str, min_max_str, p75_str, p99_str, p995_str },
        );
    }
};

pub fn prettyPrintHeader() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "\n{s:<22} {s:<8} {s:<14} {s:<22} {s:<28} {s:<10} {s:<10} {s:<10}\n",
        .{ "benchmark", "runs", "total time", "time/run (avg ± σ)", "(min ... max)", "p75", "p99", "p995" },
    );
    try stdout.print("-----------------------------------------------------------------------------------------------------------------------------\n", .{});
}

pub const Percentiles = struct {
    p75: u64,
    p99: u64,
    p995: u64,
};

/// BenchmarkResults acts as a container for multiple benchmark results.
/// It provides functionality to format and print these results.
pub const BenchmarkResults = struct {
    /// A dynamic list of BenchmarkResult objects.
    results: std.ArrayList(BenchmarkResult),

    /// Determines the color representation based on the duration of the benchmark.
    /// duration: The duration to evaluate.
    pub fn getColor(self: *const BenchmarkResults, duration: u64) c.Color {
        const max_duration = @max(self.results.items[0].duration, self.results.items[self.results.items.len - 1].duration);
        const min_duration = @min(self.results.items[0].duration, self.results.items[self.results.items.len - 1].duration);

        if (duration <= min_duration) return c.Color.green;
        if (duration >= max_duration) return c.Color.red;

        const prop = (duration - min_duration) * 100 / (max_duration - min_duration + 1);

        if (prop < 50) return c.Color.green;
        if (prop < 75) return c.Color.yellow;

        return c.Color.red;
    }

    /// Formats and prints the benchmark results in a readable format.
    pub fn prettyPrint(self: BenchmarkResults) !void {
        try prettyPrintHeader();
        for (self.results.items) |result| {
            try result.prettyPrint(false);
        }
    }
};

/// Executes a benchmark function within the context of a given Benchmark object.
/// func: The benchmark function to be executed.
/// bench: A pointer to a Benchmark object for tracking the benchmark.
/// benchResult: A pointer to BenchmarkResults to store the results.
pub fn run(comptime func: BenchFunc, bench: *Benchmark, benchResult: *BenchmarkResults) !void {
    defer bench.durations.deinit();
    const MIN_DURATION = 1_000_000_000; // minimum benchmark time in nanoseconds (1 second)
    const MAX_N = 65536; // maximum number of executions for the final benchmark run
    const MAX_ITERATIONS = 16384; // Define a maximum number of iterations

    bench.N = 1; // initial value; will be updated...
    var duration: u64 = 0;
    var iterations: usize = 0; // Add an iterations counter

    // increase N until we've run for a sufficiently long time or exceeded max_iterations
    while (duration < MIN_DURATION and iterations < MAX_ITERATIONS) {
        bench.reset();

        bench.start();
        var j: usize = 0;
        while (j < bench.N) : (j += 1) {
            func(bench);
        }

        bench.stop();
        // double N for next iteration
        if (bench.N < MAX_N / 2) {
            bench.N *= 2;
        } else {
            bench.N = MAX_N;
        }

        iterations += 1; // Increase the iteration counter
        duration += bench.elapsed(); // ...and duration
    }

    // Safety first: make sure the recorded durations aren't all-zero
    if (duration == 0) duration = 1;

    // Adjust N based on the actual duration achieved
    bench.N = @intCast((bench.N * MIN_DURATION) / duration);
    // check that N doesn't go out of bounds
    if (bench.N == 0) bench.N = 1;
    if (bench.N > MAX_N) bench.N = MAX_N;

    // Now run the benchmark with the adjusted N value
    bench.reset();
    var j: usize = 0;
    while (j < bench.N) : (j += 1) {
        bench.start();
        func(bench);
        bench.stop();
    }

    bench.setTotalOperations(bench.N);

    const elapsed = bench.elapsed();
    try benchResult.results.append(BenchmarkResult{
        .name = bench.name,
        .percs = bench.calculatePercentiles(),
        .avg_duration = bench.calculateAverage(),
        .std_duration = bench.calculateStd(),
        .min_duration = bench.min_duration,
        .max_duration = bench.max_duration,
        .total_time = elapsed,
        .total_operations = bench.total_operations,
    });
}
