# Using the hero in README.md

This direction is dark-first. `brand/silas-hero-dark.png` (3200x1760, 2x) is
the only rendered frame and ships as a plain image — no `<picture>` swap yet:

```html
<p align="center">
  <img src="docs/img/silas-hero-dark.png" width="1600"
       alt="app/agents/analyst/ on the left, a durable turn holding at a signal in the middle, the inbox approval card on the right">
</p>
```

A light companion is a real gap, not a stylistic choice — light-mode GitHub
readers currently see a dark image on a white page. To close it: open
`README Hero.dc.html`, restyle the frame onto the light tokens in
`tokens.css`'s `prefers-color-scheme: light` block, export at 2x as
`silas-hero-light.png`, then switch the snippet above to:

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/img/silas-hero-light.png">
    <img src="docs/img/silas-hero-dark.png" width="1600" alt="…">
  </picture>
</p>
```

Notes

- `width="1600"` against a 3200px asset gives a crisp image on retina.
- Keep the `alt` descriptive — the only version a screen reader, an RSS
  reader, or a text-mode terminal ever sees.
- The hero claims 100/100 kill -9 survival, zero duplicate effects,
  byte-identical replay. If `chaos_host/results/` ever disagrees, the image is
  wrong and must be regenerated — never let the hero out-claim the harness.

## Wordmark in the README header

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/img/silas-wordmark-light.svg">
    <img src="docs/img/silas-wordmark.svg" alt="silas" width="180">
  </picture>
</p>
```

## Favicon (docs site)

```html
<link rel="icon" href="/silas-favicon.svg" type="image/svg+xml">
<link rel="alternate icon" href="/favicon.ico" sizes="32x32">
```

```sh
magick -background none brand/silas-favicon.svg \
  -define icon:auto-resize=16,32,48 favicon.ico
```
