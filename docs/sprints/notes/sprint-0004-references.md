# Sprint 0004 Visual References

Sources fetched during Phase A:

- Paper Compute: https://papercompute.com/
- Paper Compute stylesheet: https://papercompute.com/_astro/_slug_.CqNWgYyM.css
- Extend: https://www.extend.ai/
- Extend stylesheet: https://www.extend.ai/_next/static/chunks/8d22b78f5b82051e.css

## Paper Compute

Relevant source observations:

- The home page uses a graph-paper background for the hero region with two linear gradients and a fixed grid size. The shipped rule is `.grid-bg { background-image: linear-gradient(var(--pc-grid) 1px, transparent 1px), linear-gradient(90deg, var(--pc-grid) 1px, transparent 1px); background-size: 18px 18px; }`.
- The page is framed with thin border rules (`--pc-border`) and full-bleed dividers, which maps well to the operator-console shell.
- Useful tokens from the shipped CSS:

```css
:root {
  --pc-bg: #2d2d2d;
  --pc-card: #1e1e1e;
  --pc-fg: #f5f4f0;
  --pc-border: #4d4d4d;
  --pc-primary: #ff4717;
  --pc-grid: rgba(255,255,255,.045);
}

:root[data-theme=light] {
  --pc-bg: #F4F1EE;
  --pc-fg: #494948;
  --pc-border: #DFDFDF;
  --pc-primary: #F04E23;
  --pc-grid: rgba(0,0,0,.04);
}
```

Tractor adaptation:

- Keep the graph-paper/cutting-mat idea, but shift away from Paper Compute's warm light base. Use cool neutral surface and muted green grid per sprint constraints.
- Keep framed section rules and compact mono labels.
- Do not import Paper Compute fonts or brand assets.

## Extend

Relevant source observations:

- The page shell is organized around `gap-px` section dividers and shallow rounded blocks (`rounded-xs`, `rounded-md`), with constrained center columns such as `--spacing-desktop-container: 1152px` and `--spacing-desktop-container-xl: 1280px`.
- Navigation and buttons use uppercase mono labels with small tracking values.
- Useful tokens from the shipped CSS:

```css
:root {
  --color-stone-50: #fafaf9;
  --color-stone-100: #f5f5f4;
  --color-stone-200: #e7e5e4;
  --color-stone-600: #57534d;
  --color-stone-800: #292524;
  --radius: .625rem;
  --radius-xs: calc(var(--radius) - 6px);
  --radius-md: calc(var(--radius) - 2px);
  --text-mono-13: .8125rem;
  --text-mono-13--letter-spacing: .78px;
}
```

Tractor adaptation:

- Reuse the product-shell discipline: one fixed header row, a graph work surface, and a 480px inspector sidebar separated by hard grid lines.
- Keep radii at 8px or less.
- Use system font stacks only. The reference sites load web fonts; Tractor must not.

## Tractor Starting Tokens

These are implementation tokens, not copied brand values:

```css
:root {
  --surface: #f1f3f1;
  --surface-panel: #ffffff;
  --ink: #181a18;
  --ink-muted: #626862;
  --divider: #252a25;
  --grid-faint: rgba(61, 97, 70, 0.07);
  --grid-strong: rgba(61, 97, 70, 0.16);
  --accent-live: #d97706;
}
```

Guardrails:

- Cool neutral base, muted green grid, one orange/amber live accent.
- No dominant beige/cream/warm tan.
- No web-font downloads.
- No emojis; timeline/tool tags are text.
