<img src=".github/cursor.svg" alt="">

**text** is the codename for where I sample typing effects. This is the current one:
**pastel.zig**, a text editor written in Zig and compiled to WebAssembly.

```sh
zig/build.sh                  # zig 0.17 → pastel.wasm
python3 -m http.server 8001   # → localhost:8001
```

- `zig/src/main.zig`: the whole editor in ~1.9k lines. Buffer, undo, wrap, highlighting, renderer, effects
- no `std`, `wasm32-freestanding`, `ReleaseFast`, `-fstrip`
- `index.html` only forwards input and blits Zig's framebuffer to a canvas
- `dither/`: an earlier sample, in JS

More in [`zig/`](zig/README.md). Manrope by Mikhail Sharanda, OFL 1.1.
