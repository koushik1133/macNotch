# SparkV deck style: Apple minimal

Tokens for rebuilding `index.html` with python-pptx. The HTML frame is 1600 x 900 px, and the PowerPoint slide is 13.333 x 7.5 in (960 x 540 pt).

**Conversion:** 1 px = 0.6 pt = 1/120 in. Every px value below converts exactly. Positions are measured from the rendered page.

## 1. Color (60-30-10)

| Role | Token | Hex | Use |
| --- | --- | --- | --- |
| 60 ground | white | `#FFFFFF` | Backgrounds of slides 2 and 4, pricing cards |
| 60 ground | mist | `#F5F5F7` | Backgrounds of slides 1, 3, 5 and 6, KPI and chart cards |
| 30 ink | ink | `#1D1D1F` | Headlines, names, values, total bar, check marks, table head rule |
| 30 ink | ink-2 | `#6E6E73` | Eyebrows, lead, body copy |
| 30 ink | ink-3 | `#86868B` | Footers, captions, number labels, column heads |
| 30 neutral | hairline | `#D2D2D7` | 1 px rules (0.75 pt in pptx), card outlines |
| 30 neutral | track | `#E8E8ED` | Empty bar track |
| 30 neutral | bar | `#AEAEB2` | Competitor bars |
| 10 accent | red | `#F01822` | Only: title eyebrow, SparkV KPI number, SparkV bar and value, SparkV row in the comparison, Pro card border and tag, CTA button. Use it for large text (18 pt or more) or fills only. |
| Device | bezel | `#0A0A0B` | MacBook lid |
| Device | lid-edge | `#BDBDC2` | Lid outline, 2 px (1.2 pt) |
| Device | base | `#E3E3E7` to `#CFCFD4` (45%) to `#A8A8AD` | Base slab, vertical gradient |
| Device | thumb | `#B4B4B9` to `#CDCDD2` | Notch cut in the base |
| Device | screen | `#2A2E43` (top) to `#171925` (at the screenshot's bottom edge) to `#0F1119` (screen bottom) | Wallpaper. The SparkV screenshots have exactly this `#2A2E43` to `#171925` vertical gradient behind the drawer, so they blend with no seam. |
| Device | notch | `#000000` | Notch, plus a 10 px camera dot `#2B3448` to `#11141C` |
| Button text | white | `#FFFFFF` | On the red CTA |

Rule of thumb: about 60% of each slide is white or mist, about 30% is ink, greys and the dark screen, and red stays under 10%.

## 2. Fonts

| Use | HTML stack | python-pptx font name |
| --- | --- | --- |
| Headlines (light) | -apple-system, "SF Pro Display", "Inter" (Google Fonts), "Helvetica Neue" | `SF Pro Display Light` on a Mac with SF Pro installed; otherwise `Helvetica Neue Light` or `Inter Light` |
| Headline emphasis | same, weight 600 | `SF Pro Display Semibold` / `Helvetica Neue Medium` / `Inter SemiBold` |
| Body | -apple-system, "SF Pro Text", "Inter" | `SF Pro Text` / `Helvetica Neue` / `Inter` |

python-pptx cannot set a numeric weight, so pick the weight through the family name and set `bold=False`. For the emphasis run inside a light headline, add a second run with the semibold family. SF Pro is licensed for Apple-platform use, so for a deck that will be shown on Windows, use Inter for everything.

## 3. Type scale

| Style | px | pt | Weight | Line spacing | Tracking | Color |
| --- | --- | --- | --- | --- | --- | --- |
| Display (slide 1) | 92 | 55.2 | Light, emphasis Semibold | 1.08 | -2% | ink |
| H1 (slides 5, 6) | 64 | 38.4 | Light, emphasis Semibold | 1.12 | -1.5% | ink |
| H1 large (slide 2) | 80 | 48 | Light, emphasis Semibold | 1.16 | -1.5% | ink |
| H1 side (slide 3) | 60 | 36 | Light, emphasis Semibold | 1.12 | -1.5% | ink |
| H1 dashboard (slide 4) | 56 | 33.6 | Light, emphasis Semibold | 1.12 | -1.5% | ink |
| Eyebrow | 22 | 13.2 | Semibold | 28 px (16.8 pt) | 0 | ink-2 (red on slide 1) |
| Lead | 28 | 16.8 | Regular | 1.36 | 0 | ink-2 |
| H3 | 28 | 16.8 | Semibold | 1.2 | 0 | ink |
| Body | 22 | 13.2 | Regular | 1.45 | 0 | ink-2 |
| Small, key rows, chart labels | 17 | 10.2 | Regular or Semibold | 1.45 | 0 | ink-2 or ink |
| Plan list | 16 | 9.6 | Regular | 1.4 | 0 | ink-2 |
| Number label (01, 02) and column head | 15 | 9 | Semibold, column heads in capitals | 1.2 | +4% | ink-3 |
| Chart sub-label | 13 | 7.8 | Regular | 1.2 | 0 | ink-3 |
| Footer | 14 | 8.4 | Regular | 20 px (12 pt) | 0 | ink-3 |
| KPI number | 80 | 48 | Light (SparkV: Medium, red) | 1.1 | -2% | ink or red |
| Tile number | 44 | 26.4 | Light | 1.12 | -1% | ink |
| Plan price | 64 | 38.4 | Light, unit 20 px / 12 pt Regular ink-2 | 1.12 | -2% | ink |
| Plan name | 28 | 16.8 | Semibold | 1.2 | 0 | ink |
| Plan INR | 20 | 12 | Regular, aside ink-3 | 1.3 | 0 | ink |
| Button | 20 | 12 | Semibold | 1 | 0 | white on red |

## 4. Grid and spacing

| Item | px | pt | in |
| --- | --- | --- | --- |
| Slide | 1600 x 900 | 960 x 540 | 13.333 x 7.5 |
| Left and right margin | 120 | 72 | 1.0 |
| Top margin (first baseline box) | 96 | 57.6 | 0.8 |
| Bottom of content area | 820 (80 from the edge) | 492 | 6.833 |
| Columns | 12 x 84 | 12 x 50.4 | 12 x 0.7 |
| Gutter | 32 | 19.2 | 0.267 |
| Content width | 1360 | 816 | 11.333 |
| Footer box | y 844, h 20 | y 506.4, h 12 | y 7.033, h 0.167 |

**Column left edges (in):** 1.000, 1.967, 2.933, 3.900, 4.867, 5.833, 6.800, 7.767, 8.733, 9.700, 10.667, 11.633. Span widths: 4 cols = 3.6 in, 6 cols = 5.533 in, 8 cols = 7.467 in, 12 cols = 11.333 in.

**Spacing scale (px):** 8, 14, 16, 18, 20, 24, 28, 32, 36, 40. Eyebrow to headline 16 to 20, headline to lead 26, section rule to number label 28, row gap between dashboard rows 36.

**Radii:** cards 22 px (13.2 pt), plan cards 24 px (14.4 pt), bars 7 px, button fully rounded (pill), lid 26 px top and 6 px bottom, screen 10 px top.

**Rules:** hairline 1 px `#D2D2D7` (0.75 pt). Table head rule 1 px ink. Pro card border 2 px red (1.2 pt).

**Footer:** left a source line or note, right the two-digit slide number, both 8.4 pt ink-3. Slide 1 has no footer.

## 5. MacBook notch mockup (shapes)

Build it from shapes, back to front:

1. **Lid:** rounded rectangle, fill bezel, 1.2 pt lid-edge outline (no bottom edge needed), padding inside equal to `pad`.
2. **Screen:** rectangle inside the padding, aspect 1.54 : 1, gradient fill as in the color table (stop 2 at the screenshot's bottom edge).
3. **Screenshot:** picture, top edge flush with the screen top, centered horizontally. Never add a border or shadow.
4. **Notch:** black rectangle with rounded bottom corners (14 px), top-centered, width about 30% of the screenshot width, height about 4.5% of it, with the 10 px camera dot centered.
5. **Base:** slab under the lid, 22 px (0.183 in) tall, wider than the lid, base gradient, bottom corners 20 px. Thumb cut: 16% of the base width, 9 px tall, centered on the top edge.

| Slide | Lid (x, y, w) in | Pad | Screen (x, y, w, h) in | Screenshot (x, y, w, h) in | Notch (x, y, w, h) in | Base (x, y, w) in |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 2.083, 3.767, 9.167 (bleeds off the bottom) | 16 px | 2.233, 3.917, 8.867, 5.758 (crop at 7.5) | `01-home.png`: 3.200, 3.917, 6.933, 1.600 | 5.625, 3.917, 2.083, 0.308 | off slide |
| 3 | 5.183, 1.450, 6.833 (h 4.550) | 12 px | 5.300, 1.567, 6.600, 4.283 | `10-agents-hub.png`: 5.300, 1.567, 6.600, 2.458 | 7.608, 1.567, 1.983, 0.300 | 4.867, 6.000, 7.467 |

## 6. Slide layouts (measured boxes, inches: x, y, w, h)

**1. Title (mist).** All text centered on 12 cols. Eyebrow "SparkV" red: 1.0, 0.8, 11.333, 0.233. Display (2 lines): 1.0, 1.183, 11.333, 1.658. Lead: 1.0, 3.058, 11.333, 0.317. Device as in section 5, bleeding off the bottom edge.

**2. Problem (white).** Eyebrow 1.0, 0.8. H1 large (2 lines) on 10 cols: 1.0, 1.2, 9.4, 1.55. Three points on 4 cols each, bottom-aligned to the content area, each with a hairline on top: x 1.0 / 4.867 / 8.733, y 5.1, w 3.6, h 1.733. Inside: number label, H3 (18 px below), body (14 px below).

**3. Feature showcase (mist).** Text block on cols 1 to 4, vertically centered: 1.0, 1.458, 3.6, 4.708 (eyebrow, H1 side, body, then a key list at y 4.842: three rows with hairlines, key column 0.967 in, Semibold ink, label ink-2). Device on cols 5 to 12, vertically centered (section 5).

**4. Metrics (white).** Eyebrow and H1 dashboard across 12 cols (H1 at y 1.167, h 0.525). KPI cards (mist) on cols 1 to 4: 1.0, 1.992, 3.6, 1.717 and 1.0, 3.9, 3.6, 1.717. Chart card (mist) on cols 5 to 12: 4.867, 1.992, 7.467, 3.625, padding 0.233 x 0.267 in, 7 rows (label column 1.967 in, value column 0.8 in right-aligned, bar 14 px tall). A hairline sits above the "Five apps" total row. Three tiles across: y 5.917, h 0.917, w 3.6 each at x 1.0 / 4.867 / 8.733, each with a hairline on top, number column 1.233 in.

Chart data (USD, scale $0 to $400): Granola $168.00 (42%), Wispr Flow $144.00 (36%), Paste $29.99 (7.5%), CleanShot X $29.00 (7.25%), NotchNook $25.00 (6.25%), Five apps $395.99 (99%, ink bar), SparkV Pro $39.00 (9.75%, red bar).

**5. Comparison (mist).** Eyebrow and H1 at y 1.167. Two 6-col columns: left 1.0, right 6.8, each 5.533 wide. Column heads at y 2.1 (h 0.275, 1 px ink rule under). Five rows of 0.7 in from y 2.375, hairline under each. Left cell: name 22 px Semibold, category 16 px ink-2, price right-aligned in a 1.583 in column (20 px ink, qualifier 13 px ink-3). Right cell: SparkV feature name and description. Summary row at y 5.875, h 0.633, no rule; the SparkV summary is red.

**6. Pricing (mist).** Eyebrow and H1 centered, H1 at y 1.167. Three white plan cards on 4 cols: x 1.0 / 4.867 / 8.733, y 2.067, w 3.6, h 4.025, padding 0.267 x 0.283 in, 1 px hairline outline; Pro card has a 2 px red outline and a red "Recommended" tag (14 px Semibold). CTA row centered: red pill button 3.792, 6.392, 2.425, 0.442 (padding 15 x 30 px), aside text at 6.442, 6.533 in 17 px ink-2.

## 7. Content rules

- One idea per slide: one headline, one visual or one table.
- Product screenshots are real SparkV renders from `docs/screenshots/`. Use them at their own aspect ratio, never recolored or cropped inside the drawer.
- Numbers come from `SparkV-Business-Plan.md` or `SparkV-Feature-Guide.md`. Anything the project does not have (users, revenue, market size, team) goes in as a labeled placeholder such as `[TBD: monthly active users]`.
- No overlapping boxes, no shadows on slide content, no gradients except the device.
