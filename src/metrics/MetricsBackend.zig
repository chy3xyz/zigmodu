const std = @import("std");

/// Pluggable metrics backend interface.
/// Implement this to swap Prometheus for StatsD, Datadog, etc.
pub const MetricsBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createCounter: *const fn (*anyopaque, []const u8, []const u8) anyerror!*anyopaque,
        createGauge: *const fn (*anyopaque, []const u8, []const u8) anyerror!*anyopaque,
        createHistogram: *const fn (*anyopaque, []const u8, []const u8, []const f64) anyerror!*anyopaque,
        counterInc: *const fn (*anyopaque, u64) void,
        counterAdd: *const fn (*anyopaque, u64) void,
        gaugeSet: *const fn (*anyopaque, f64) void,
        gaugeInc: *const fn (*anyopaque) void,
        gaugeDec: *const fn (*anyopaque) void,
        histogramObserve: *const fn (*anyopaque, f64) void,
    };

    pub fn createCounter(self: MetricsBackend, name: []const u8, help: []const u8) !*anyopaque {
        return self.vtable.createCounter(self.ptr, name, help);
    }
    pub fn createGauge(self: MetricsBackend, name: []const u8, help: []const u8) !*anyopaque {
        return self.vtable.createGauge(self.ptr, name, help);
    }
    pub fn createHistogram(self: MetricsBackend, name: []const u8, help: []const u8, buckets: []const f64) !*anyopaque {
        return self.vtable.createHistogram(self.ptr, name, help, buckets);
    }
    pub fn counterInc(self: MetricsBackend, handle: *anyopaque) void {
        self.vtable.counterInc(handle, 1);
    }
    pub fn counterAdd(self: MetricsBackend, handle: *anyopaque, v: u64) void {
        self.vtable.counterAdd(handle, v);
    }
    pub fn gaugeSet(self: MetricsBackend, handle: *anyopaque, v: f64) void {
        self.vtable.gaugeSet(handle, v);
    }
    pub fn gaugeInc(self: MetricsBackend, handle: *anyopaque) void {
        self.vtable.gaugeInc(handle);
    }
    pub fn gaugeDec(self: MetricsBackend, handle: *anyopaque) void {
        self.vtable.gaugeDec(handle);
    }
    pub fn histogramObserve(self: MetricsBackend, handle: *anyopaque, v: f64) void {
        self.vtable.histogramObserve(handle, v);
    }
};
