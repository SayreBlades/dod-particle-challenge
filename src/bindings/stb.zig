// Minimal hand-written extern "c" for stb_image_write (stage 11 only).
// Same philosophy as raylib.zig: declare the exact data contract we use,
// nothing more. The implementation is compiled from src/stb_impl.c.

/// Write an RGBA (comp=4) image to a PNG file. `data` is w*h*comp bytes,
/// rows tightly packed with `stride_in_bytes` per row. Returns nonzero on
/// success, 0 on failure.
pub extern "c" fn stbi_write_png(
    filename: [*:0]const u8,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: ?*const anyopaque,
    stride_in_bytes: c_int,
) c_int;
