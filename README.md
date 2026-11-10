```
⠉⡏⠁
⠀⡇⠀
⣀⣇⡀
```

# pastel.zig

A text editor written in Zig and compiled to WebAssembly.

```sh
zig/build.sh                  # zig 0.17 → pastel.wasm
python3 -m http.server 8001   # → localhost:8001
```

`zig/src/main.zig` is the whole editor: buffer, undo, wrap, highlighting, renderer, effects.
No `std`, `wasm32-freestanding`, `ReleaseFast`. `index.html` only forwards input and blits the framebuffer.

More in [`zig/`](zig/README.md). Manrope by Mikhail Sharanda, OFL 1.1.
