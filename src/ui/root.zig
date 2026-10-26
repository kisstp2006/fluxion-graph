// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Graph's editor: a function's graph drawn with fluxion-ui, and
//! what the pointer and the keys do to it. See `View`.

pub const View = @import("View.zig");
pub const Canvas = @import("Canvas.zig");
pub const Theme = @import("Theme.zig");
pub const layout = @import("layout.zig");

test {
    _ = View;
    _ = Canvas;
    _ = Theme;
    _ = layout;
}
