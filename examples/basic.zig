const std = @import("std");
const zbench = @import("zbench");

fn helloWorld() []const u8 {
    var result: usize = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const square = i * i;
        result += square;
    }

    return "Hello, world!";
}

fn myBenchRunner() void {
    _ = helloWorld();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const second: u64 = 1_000_000_000;
    const bench_iterations: u64 = 128;

    var bench = try zbench.Benchmark.init(second, bench_iterations, gpa.allocator());
    defer bench.deinit();

    const bench_result = try bench.run(myBenchRunner, "ArrayList append");
    try bench_result.prettyPrint(true);
}
