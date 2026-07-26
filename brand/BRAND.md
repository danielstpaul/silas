# Silas — brand system

Version 1.0.0 · direction "Signals" · built against `danielstpaul/silas@main`

Silas is safety equipment, not staff: interlocking for agent runs. Reads move
freely; every write holds at a signal until a person clears it; a crash
leaves the run exactly where the log says it was. "Rails" does double duty —
the framework, and the thing a run travels on.

Three rules hold the system together:

1. **The lamp never expresses state.** White is links, focus, the live-step
   dot. State is the four aspect colours (running/waiting/in_doubt/completed)
   plus failed plus a lampless "canceled" — none of them may use the lamp's
   white.
2. **Dark is primary, not a fallback.** The tokens' base is the dark palette;
   light is a `prefers-color-scheme: light` override, the reverse of most
   sites. The audience lives in terminals.
3. **Never out-claim the harness.** Any number in a brand asset must be
   reproducible from `chaos_host/results/`.

---

## Files

```
brand/
  silas-wordmark.svg         lockup, dark/primary (160x40) — TEXT, must be outlined
  silas-wordmark-light.svg   lockup, light
  silas-mark.svg             mark only, dark (24x24) — pure geometry, "proceed" aspect
  silas-mark-light.svg       mark only, light
  silas-mark-held.svg        the "held" aspect — horizontal lamps, amber
  silas-favicon.svg          night tile, 32x32 rx7 — the shipping favicon
  silas-favicon-light.svg    white tile, for light browser chrome
  tokens.css                 drop-in replacement for the :root blocks
  tokens.json                same values, machine-readable
  README-hero.md             <picture> markup for the hero + wordmark
BRAND.md                     this file
```

Design sources (open in the Omelette project, not needed to implement):
`Brand Kit.dc.html`, `README Hero.dc.html`, `Inbox - Rebrand.dc.html`,
`Inbox - Current.dc.html` (the pixel-accurate recreation of what ships today).

---

## The mark

A position-light signal: a circular bezel, two lamps. Diagonal (bottom-left +
top-right) is the "proceed" aspect and the brand's default mark. Horizontal
(both lamps at mid-height, amber) is the "held" aspect — it appears wherever
the UI needs to say "a human is needed here". One instrument, two readings.

- Pure geometry: a circle and two dots. No gradients, no strokes on the
  lamps. Legible at 16px — a circle survives smallness better than any glyph.
- The favicon is the tile (`silas-favicon.svg`), not the bare mark — dark
  browser chrome needs the bezel's contrast.
- **Never** separate the two lamps from the bezel, and never invent a third
  aspect for the logo. The mark has exactly two readings; a third would blur
  the one it's borrowing meaning from (the approval card).

## The wordmark

Archivo ExtraBold (800), lowercase, tracking −4.5%. Lowercase because Silas is
a tool you type, not a company you meet — every competitor's wordmark is a
capitalized logotype. Minimum size 16px cap height; below that use the mark
alone. Clearspace on all sides = the cap height of the s.

### Outlining the wordmark — required before publishing

`brand/silas-wordmark*.svg` ship with a live `<text>` element. On a machine
without Archivo they fall back to a default sans, which is a visibly
different weight and spacing. Convert to paths once, commit the result:

```sh
inkscape silas-wordmark.svg --export-text-to-path --export-plain-svg=out.svg
# or open in Figma/Illustrator/Affinity: select text, Outline / Create Outlines
# or: npm i -g svg-text-to-path && svg-text-to-path silas-wordmark.svg
```

After outlining, delete the SHIP BLOCKER comment from the file.

## Colour

Full values in `brand/tokens.css` and `brand/tokens.json`. Summary (dark is
primary):

| token | dark | light | role |
|---|---|---|---|
| `--bg` | `#0F1013` | `#F4F4F2` | night / paper |
| `--panel` | `#16181D` | `#FFFFFF` | card, input, button face |
| `--ink` | `#E9EBEF` | `#15171B` | body, wordmark |
| `--muted` | `#969CA8` | `#5B5F68` | metadata |
| `--line` | `#262A33` | `#DCDEE3` | borders, rules |
| `--accent` (the lamp) | `#F2F4F8` | `#274FBF` | links, focus, live-step dot |

Indigo (`#4f46e5` / `#818cf8`) is retired — it carried links, the send
button and every step dot at exactly the saturation the category defaults to.
Note the lamp itself changes hue between modes (white at night, route-blue on
paper) — the one token allowed to do that, because it represents light, not a
fixed pigment.

### The seven run states, in aspect

`Turn::STATUSES` has seven entries. Two get relabelled in the UI only —
`waiting` reads **held**, `completed` reads **clear** — the database strings
are untouched; only `TraceHelper`'s human-facing label changes.

| state | dark fg / bg | light fg / bg | UI label | means |
|---|---|---|---|---|
| `queued` | `#969CA8` / `#1D2027` | `#5B5F68` / `#EDEEF1` | queued | in line, not started |
| `running` | `#58A6FF` / `#14233D` | `#1D4ED8` / `#DCE7F5` | running | a worker holds it — the only aspect that pulses |
| `waiting` | `#E3B341` / `#2E2611` | `#92650E` / `#FBEED0` | **held** | parked at zero compute, needs a person |
| `in_doubt` | `#B49AE8` / `#241E33` | `#63459B` / `#EAE3F7` | in_doubt | a crash made the effect ambiguous |
| `completed` | `#3FB950` / `#12291B` | `#157A3D` / `#DCF3E3` | **clear** | answered — the only green in the system |
| `failed` | `#F85149` / `#331815` | `#B91C1C` / `#FBDCDA` | failed | broke — the only aspect that gets red |
| `canceled` | `#737A87` / dashed | `#5B5F68` / dashed | canceled | a person stopped it — a lamp goes out, it doesn't turn red |

Tool invocations map onto the same seven: `pending`→queued, `started`→running,
`required`→waiting/held, `approved`→completed/clear, `declined`→failed,
`expired`→canceled, `in_doubt`→in_doubt.

## Type

| role | family | ships in the gem? |
|---|---|---|
| display / wordmark | Archivo 500–800 | no — docs and README only |
| UI / body | system stack | yes, it *is* the system stack |
| mono | Space Mono 400/700 | no — degrades to `ui-monospace` |

```css
--sans-display: Archivo, "Helvetica Neue", Helvetica, Arial, sans-serif;
--sans-ui:      ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
--mono:         ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
```

The gemspec adds no asset dependency and should keep adding none. Docs load
two webfonts; the product UI loads zero.

## Voice

- Mechanism first, safety-system vocabulary: "block", "hold", "clear",
  "movement". "Held at the signal until you clear it," not "pending review".
- State the limit: "Honestly early and honestly narrow." A venture-backed
  competitor structurally cannot say this.
- Never: "unleash", "autonomous agents at scale", "powered by", or any
  adjective a chaos run cannot verify.
- The `early` chip stays in the docs nav until there are external users.

---

## Implementing it in the gem

Ordered by value per line changed.

**01 · Tokens.** Replace the two `:root` blocks (and flip the media query from
`dark` to `light`, since dark is now the base) in
`app/views/layouts/silas/inbox.html.erb` with `brand/tokens.css`. `--radius`
drops 14px → 8px.

**02 · Seven states, two relabels.** In
`Silas::Inbox::TraceHelper::STATUS_CLASS`, add `pill-violet` for
`in_doubt` and `pill-quiet` for `canceled`/`expired` (both in
`tokens.css`). Then, in the same helper, relabel two human-facing strings —
the enum values in the database are untouched:

```ruby
UI_LABEL = { "waiting" => "held", "completed" => "clear" }.freeze
def status_label(status) = UI_LABEL[status.to_s] || status.to_s.tr("_", " ")
```

Use `status_label` instead of `status` inside `status_pill`'s visible text.

**03 · Wordmark.** `header.top .logo` gets the Archivo stack (in
`tokens.css`), lowercase. Inline `silas-mark.svg` beside it — 3 shapes, no
asset pipeline needed.

**04 · Approvals move to the top of the session**, same as any direction:
render `@session.pending_approvals` above `#silas-turns` in
`sessions/show.html.erb`, leave a one-line "↑ awaiting your key, above" stub
in the trace. Keep the card's `dom_id(invocation)` wrapper so
`Broadcastable` still swaps it in place.

**05 · Arguments as key/value rows**, results collapse behind `<details>` —
same rationale and same diffs as any direction (see the inbox mock for the
exact shape); this direction doesn't change *what* to do here, only the tokens
it renders with.

**06 · A rail, grouped by who's blocked** — Held / Working / Filed, from the
same query `sessions#index` already runs.

**07 · Surface the rescuer.** `Silas::DeadJobRescuerJob` runs every 30s;
show when it last ran. This direction's copy: "rescuer alive · 12s ago".

Changes 01–03 are cosmetic and independent. 04–06 touch partials broadcast
through the host renderer — use `silas_engine_path`, not bare engine helpers.
07 needs one new controller query.
