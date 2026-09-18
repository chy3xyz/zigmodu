//! The alpha module's domain: a fixed-window mean of the mid, and the rule that
//! turns a distance from that mean into a directional view.
//!
//! A real strategy would carry volatility, depth and its own signals; what
//! matters in this example is that the state is a value with no idea who calls
//! it — which is what lets one thread own it.

/// Window length. A mean needs history before it means anything.
pub const window_len = 8;

pub const Window = struct {
    samples: [window_len]i64 = @splat(0),
    head: usize = 0,
    filled: usize = 0,

    /// Feed one mid. Returns false while the window has no full history yet.
    pub fn push(self: *Window, mid: i64) bool {
        self.samples[self.head] = mid;
        self.head = (self.head + 1) % window_len;
        if (self.filled < window_len) {
            self.filled += 1;
            return false;
        }
        return true;
    }

    pub fn mean(self: *const Window) i64 {
        var sum: i64 = 0;
        for (self.samples) |p| sum += p;
        return @divTrunc(sum, window_len);
    }

    /// How stretched the price is against the mean (signed).
    pub fn pull(self: *const Window, mid: i64) i64 {
        return self.mean() - mid;
    }

    /// Mean reversion: below the mean is a buy, above it a sell. The size is a
    /// view as well — sizing authority stays with risk.
    pub fn sizeFor(distance: i64) i64 {
        return 1 + @min(@divTrunc(@abs(distance), 2), 4);
    }
};
