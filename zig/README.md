# pastel.zig

A small text editor written in Zig, set in Manrope on a flat page: white, or black in dark mode.
All of it lives in `src/main.zig` and compiles to WebAssembly: the text buffer, editing and undo,
proportional word-wrapped layout, Zig syntax highlighting, a software renderer, and every effect.
`../index.html` is glue. It forwards keys, clicks and the clipboard, and puts Zig's
framebuffer on a canvas.

```sh
./build.sh                                   # → ../pastel.wasm (needs Zig 0.17: brew install zig)
cd .. && python3 -m http.server 8001         # → http://localhost:8001
```

**Look.** Pastel highlights in mint, sky, rose and lavender. On white they're highlighter marks
under keywords, builtins, strings and numbers. On black they colour the text itself.

**The ASCII field** (after [ascii-sharks](https://github.com/stackedlol/ascii-sharks)). Effects deposit ink into a grid of cells, the ink
fades, and each cell shows a glyph from the ramp `.,:;t%SX8#@`. A 4×4 Bayer dither decides between
neighbouring glyphs. The field draws under the text, so the words always read.

- **Typing:** an expanding ripple and little fish that swim off leaving wakes. Typing fast makes
  them bigger. Each word gets the next highlight colour, and each new letter springs in from small.
- **Deleting:** the text dissolves into dense rose glyphs that fade down the ramp, while fish sink
  away and a red box collapses on the gap.
- **Enter, clicks and jumps:** an ASCII streak along the way and a splash where you land.

**ff-tracking** (Mustafa Saraç's look, MIT). Finished words
and landing spots get corner brackets that snap in from wide to tight, red and hatched, then settle.
The newest lock carries an `X:col Y:line` tag in a 3×5 pixel font.

**Feel.** Built to be tactile without getting in the way of reading:
- The caret squashes while a key is held and springs back on release, and recoils with each letter.
- A new letter stamps in: it drops, lands, squashes and wobbles back to shape.
- A small jolt runs back along the line, and the page gives a slight nudge (a CSS transform the host
  reads from `shakeX`/`shakeY`).
- Soft synthesized key clicks: a deeper one for Enter and a lighter tick for delete. Toggle them in
  the corner.
- Every letter gets a ring of page colour wherever the field is active, and ff-tracking draws under
  the text.

**Editing:** undo and redo (⌘Z, ⇧⌘Z), shift or drag to select, double-click for a word, copy,
cut and paste, auto-indent after `{`, soft tabs. Saved to localStorage. Text is ASCII only, so
anything else is typed as `?`. Only what changed is redrawn, and nothing runs while the page is still.

`src/atlas.bin` is Manrope 500 at 36 px: 95 glyphs with their advance widths. `src/ramp.bin` is the
ramp in Manrope 700 at 22 px. Manrope is by Mikhail Sharanda, SIL Open Font License 1.1.
