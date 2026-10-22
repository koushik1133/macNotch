# SparkV red/black deck style

Matched to https://www.sparkv.si. The values were read from its computed styles on 22 Oct 2026: `--red #f01822`, dark `--background #09090a`, `--foreground #f7f7f5`, `--muted #9a9aa1`, `--line #ffffff1f`, hero `h1` 92px/520 weight with -0.065em tracking, a red 24x1px eyebrow dash, and a `hero-glow` radial of `rgba(240,24,34,.16) → transparent 66%`. The reference implementation is `index.html` in this folder.

## Canvas and unit conversion

| Item | HTML | PowerPoint |
| --- | --- | --- |
| Slide | 1600 x 900 px | 13.333 x 7.5 in (`prs.slide_width = Inches(13.333)`, `prs.slide_height = Inches(7.5)`) |
| 1 px | 1 px | 0.6 pt = 1/120 in = 7,620 EMU |
| Conversion | `pt = px * 0.6` | `Inches(px / 120)` or `Emu(px * 7620)` |

## Color (60 / 30 / 10)

| Role | Share | Token | Hex | Notes |
| --- | --- | --- | --- | --- |
| Slide background | 60% | `ink-950` | `#09090A` | Every slide. Solid fill. |
| Page or deeper panel | — | `ink-990` | `#050506` | Only outside the slides, or for footers |
| Raised surface | — | `surface` | `#111113` | Mockup wallpaper and panels |
| Raised surface 2 | — | `surface-2` | `#17171A` | Card fill when a fill is needed |
| Display headline | 30% | `white` | `#FFFFFF` | |
| Body / primary text | 30% | `paper` | `#F7F7F5` | Off-white |
| Lead paragraph | 30% | `grey-1` | `#A0A0A3` | White at 62% on ink |
| Muted body | 30% | `grey-2` | `#9A9AA1` | |
| Labels / eyebrows | 30% | `grey-3` | `#808088` | Eyebrow text on the site is white at 52%, which is `#89898A` as a solid color |
| Headline accent word | 30% | `grey-4` | `#4E4E4F` | White at 28% on ink, used for the last phrase of a headline ("center.", "Keep it.") |
| Neutral data bar | 30% | `bar-grey` | `#3A3A3F` | |
| Hairline rule | 30% | `line` | `rgba(255,255,255,.10)`, solid `#222223` | 1 px (0.6 pt) |
| Chip / card border | 30% | `line-2` | `rgba(255,255,255,.15)`, solid `#2C2C2D` | |
| Frosted chip fill | 30% | `chip` | `rgba(255,255,255,.05)`, solid `#151516` | The HTML version adds `backdrop-filter: blur(20px)` |
| Signal red | 10% | `red` | `#F01822` | Primary CTA, eyebrow dash, the highlighted bar, the Pro card border, status dot |
| Red, pressed | 10% | `red-pressed` | `#D7131D` | Button active state only |
| Red as text | 10% | `red-text` | `#F8262F` | One red number per slide at most |
| Red, soft | 10% | `red-soft` | `#FF8A90` | Text on a red-tinted chip |
| Red glow | 10% | `glow` | `rgba(240,24,34,.16)` | A radial gradient behind hero content |

Rules:
- Red covers no more than about 10% of a slide's area. Use it for one CTA, one highlighted data point, the eyebrow dash and accents. Never for body text or for whole backgrounds.
- No other hues. Real product screenshots are the only exception.
- In python-pptx, a transparent white over `#09090A` can be drawn with the solid value shown, or with an `a:alpha` element added to `solidFill` (for example, 10% = `<a:alpha val="10000"/>`).

## Typography

Only system fonts are used; nothing is loaded from the web.

| Use | HTML stack | PowerPoint font |
| --- | --- | --- |
| Sans (everything except labels) | `ui-sans-serif, system-ui, -apple-system, "SF Pro Display", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif` | `SF Pro Display` on a Mac; otherwise `Helvetica Neue`, then `Segoe UI` on Windows |
| Mono (eyebrows, numbers, chips, captions) | `ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace` | `SF Mono`, then `Menlo`, then `Consolas` |

The weight 520 does not exist in PowerPoint. Use SF Pro Display **Medium**, or Helvetica Neue **Medium**. Tracking in python-pptx is set with `rPr.set('spc', str(int(pt * em * 100)))`, where `spc` is in hundredths of a point. Example: 79.2 pt × -0.05 em = -3.96 pt, so `spc="-396"`.

| Style | px (HTML) | pt (PPTX) | Weight | Tracking | Line height | Color | Case |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Display (title slide) | 132 | 79.2 | 520 / Medium | -0.05 em (spc -396) | 0.92 | `#FFFFFF` + `#4E4E4F` accent | Sentence |
| H1 (slide title) | 76 | 45.6 | 520 / Medium | -0.045 em (spc -205) | 0.98 | `#FFFFFF` + `#4E4E4F` accent | Sentence |
| KPI number | 84 | 50.4 | 520 / Medium | -0.045 em (spc -227) | 1.0 | `#FFFFFF` (one may be `#F8262F`) | — |
| Price (pricing card) | 76 | 45.6 | 520 / Medium | -0.045 em | 1.0 | `#FFFFFF` | — |
| Card number (problem) | 52 | 31.2 | 520 / Medium | -0.04 em | 1.0 | `#F7F7F5` | — |
| Secondary big number | 48 | 28.8 | 520 / Medium | -0.04 em | 1.0 | `#F7F7F5` / `#F8262F` | — |
| H3 | 28 (20–24 in dense rows) | 16.8 (12–14.4) | 450 / Regular | -0.035 em | 1.2 | `#F7F7F5` | Sentence |
| Lead | 22 (19 beside a title) | 13.2 (11.4) | 400 | -0.01 em | 1.55 | `#A0A0A3` | Sentence |
| Body | 17 (15 in dense rows) | 10.2 (9) | 400 | 0 | 1.5 | `#9A9AA1` | Sentence |
| Button | 16 | 9.6 | 700 / Bold | -0.01 em | 1 | `#FFFFFF` | Sentence |
| Eyebrow (mono) | 15 | 9 | 500 | +0.16 em (spc 144) | 1 | white 52% (`#89898A`) | UPPERCASE |
| Mono label / caption | 13 (11 for fine print) | 7.8 (6.6) | 400 | +0.12 em | 1.6 | `#808088` | UPPERCASE |
| Chip text (mono) | 12 | 7.2 | 400 | +0.10 em | 1 | `#9A9AA1` | UPPERCASE |
| Page number (mono) | 15 | 9 | 400 | +0.16 em | 1 | white 36% (`#626263`) | — |
| Wordmark | 15 | 9 | 600 / Semibold | +0.42 em | 1 | `#F7F7F5`, with the "V" in `#F01822` | UPPERCASE |

Headline pattern: the last phrase is set in `grey-4` (`#4E4E4F`), as the site does with "forward.". Examples: "AI command **center.**", "Pay once. **Keep it.**"

## Grid and spacing

| Item | px | in | pt |
| --- | --- | --- | --- |
| Side margins (left and right) | 80 | 0.667 | 48 |
| Columns | 12 × 98 | 12 × 0.817 | 12 × 58.8 |
| Gutter | 24 | 0.2 | 14.4 |
| Column *n* left edge (n = 1..12) | 80 + (n−1) × 122 | (80 + (n−1) × 122) / 120 | — |
| Header row (eyebrow + page number) | top 56, height 24 | 0.467 / 0.2 | — |
| Content area | top 120 to bottom 810 (690 tall) | 1.0 to 6.75 in | — |
| Footer rule | y 825, from 80 to 1520 | 6.875 in | 1 px hairline `line` |
| Footer text (mono 13 px) | baseline about y 852 | 7.1 in | — |
| Eyebrow dash | 24 × 1, red, 14 px gap before the text | 0.2 × 0.008 in | — |
| Vertical rhythm | 8 px base; use 12 / 16 / 24 / 32 / 44 / 56 | — | — |

Common spans:
- Title + side intro: title over columns 1–8, intro over columns 9–12, with the intro aligned to the title's bottom.
- Hero split: text over columns 1–5, visual over columns 6–12.
- Two-column comparison: columns 1–6 and 7–12, with rows sharing a hairline bottom rule.
- KPI row: 4 tiles of 3 columns each. Problem cards: 6 tiles of 2 columns each. Pricing: 3 cards of 4 columns each.

Nothing overlaps except the decorative glow, which sits behind the content.

## Components

| Component | Spec |
| --- | --- |
| Primary button | Height 56, padding 0 22, radius 12, fill `#F01822`, text white 16 px bold, shadow `0 12 35 rgba(240,24,34,.22)`. Pressed: `#D7131D`. In PPTX, use a rounded rectangle with adj ≈ 0.21 and no shadow (or a soft outer shadow at 22% red). |
| Ghost / frosted button | Same size, fill white 5%, 1 px border white 15%, text white |
| Chip | Height 30, padding 0 12, pill radius, 1 px border white 15%, fill white 5%, mono 12 px caps. The red chip uses a 45% red border, an 8% red fill and `#FF8A90` text. |
| Key cap | Height 40, min width 112, radius 10, the chip's border and fill, sans 17 px medium |
| Card (plain) | No fill, 1 px **top** rule `line`, padding-top 18–22. The total or highlight card uses a red top rule. |
| Pricing card | Radius 18, 1 px border `line`, fill white 1.5%, padding 26 × 28. The Pro card has a 55% red border and a red radial glow (18%) at its top-right. |
| List bullet | An 8 × 1 px dash in `grey-3` (red in the Pro card), indented 18 px |
| Status dot | 8 px circle in red for the key item, `grey-3` for the others |
| Hero glow | A radial gradient, `rgba(240,24,34,.16)` at the center fading to transparent at 66%, about 1000–1300 px across, placed behind the headline (title slide) or off a top corner (other slides). In PPTX, use an ellipse with a gradient fill from red at 16% alpha to red at 0% alpha, sent to the back. |
| Faint grid (title slide only) | 1 px lines in white 3.5%, 122 px pitch aligned to the columns, radially masked |

## MacBook notch mockup (feature slides)

- **Bezel:** fill `#000000`, 1 px border white 14%, no bottom edge, top radius 28 px, padding 12 px.
- **Screen:** top radius 16 px. Wallpaper is a linear gradient from `#141416` to `#0B0B0D`, with a red radial (18%) at the top center.
- **Menu bar:** a 26 px strip in white 6% with a hairline bottom edge.
- **Drawer:** the real SparkV render, centered and pinned to the top edge of the screen. The render's slate background is masked away along the drawer edge (see the `.m-*` SVG masks in `index.html`, given in the render's own 2x pixel coordinates). For PPTX, crop the PNG to the drawer box: `01-home` x 53–1171, y 0–229; `10-agents-hub` x 63–1161, y 0–403; `50-dictation` x 212–1012, y 0–110; `51-clicky-answer` x 208–1016, y 0–162. Then place it on a black rounded rectangle.
- **Camera:** a 9 px dot (`#0D0D10` with a 2 px `#1B1B20` ring), 7 px from the top center.
- **Fade:** the bottom 28% of the screen fades into `#09090A`.
- **Caption:** below the mockup, a mono 13 px caps caption that starts with "REAL RENDER ·".

## Charts

- Use a single horizontal bar series: thickness 14 px, ends rounded to 4 px, starting from a 200 px label column.
- Neutral bars are `#3A3A3F`. The total bar is `#F7F7F5`. SparkV is the only red bar.
- Values are direct labels in 16 px `#F7F7F5`, placed 12 px past the end of the bar. There is no gridline or axis line, only a mono "Scale 0–$480" note.
- One axis only. State the source in the slide footer.

## Content rules

Use only facts from `SparkV-Feature-Guide.md` and `SparkV-Business-Plan.md`. Competitor prices are third-party listings (22 Oct 2026) and must carry a "verify before quoting" note. Missing numbers (users, revenue, market size, team) appear as `[TBD: …]` placeholders and are never invented. Pricing slides say the prices are planned until licensing ships.
