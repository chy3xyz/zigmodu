//! IM domain: WebSocket messaging, connection registry, buffer pool, io_uring.

pub const ConnectionRegistry = @import("ConnectionRegistry.zig").ConnectionRegistry;
pub const WsFramer = @import("../http/WsFramer.zig").WsFramer;
pub const WsFrameKind = @import("../http/WsFramer.zig").WsFrameKind;
pub const BufferPool = @import("BufferPool.zig").BufferPool;
pub const WsUring = @import("../http/ws_uring.zig").WsUring;
