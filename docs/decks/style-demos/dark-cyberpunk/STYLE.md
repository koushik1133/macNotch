# SparkV deck style: Dark Cyberpunk

Reference build: `index.html` in this folder (six 1600 x 900 px frames). These tokens let python-pptx rebuild the same look on a 13.333 x 7.5 in (16:9) slide.

## 1. Units

| Frame | Slide |
| --- | --- |
| 1600 x 900 px | 13.333 x 7.5 in = 960 x 540 pt |

- **1 px = 0.6 pt = 1/120 in = 7,620 EMU.** Every size below is given in px and pt.
- Helper: `def px(v): return Emu(int(v * 7620))` and `def fpt(v): return Pt(v * 0.6)`.

## 2. Colour (60-30-10)

| Role | Token | Hex | Use |
| --- | --- | --- | --- |
| 60 base | void | `#000000` | Slide background, image backdrops |
| 30 neutral | panel | `#0A0A0C` | Panel fill (92% opaque over the grid) |
| 30 neutral | panel-2 | `#111114` | Table header rows, key chips |
| 30 neutral | line | `#26262B` | 1 px hairlines, panel borders, row dividers |
| 30 neutral | line-2 | `#3A3A41` | Chip and outline-tag borders |
| 30 neutral | text | `#F2F2F4` | Headlines, values, primary text |
| 30 neutral | text-2 | `#A1A1AA` | Lead and body text |
| 30 neutral | text-3 | `#6B6B74` | HUD labels, captions, sources |
| 10 accent | neon | `#FF1E2D` | Kicker, key numbers, CTA, brackets, glitch rule, recurring prices |
| 10 accent | neon-deep | `#8A0F18` | Divider above totals, red row tint |
| effect only | neon-glow | `#FF1E2D` at 45% alpha | Outer glow / soft shadow on red items |
| effect only | aberration | `#00E5FF` at 28% alpha | 2 px right offset in headline chromatic shadow; never a fill |
| chart greys | bar-1..5 | `#8A8A93` `#6B6B74` `#4E4E56` `#3A3A41` `#2C2C32` | Stacked bar segments for competitors (largest first) |

Rules: red covers about 10% of any slide. Only one red element type per block (a number, a tag or a border, not all three). On red fills (CTA, badges, "verified" tags) text is `#000000`.

## 3. Type

Google Fonts: **Chakra Petch** (display), **Inter** (body), **JetBrains Mono** (HUD). If they are not installed on the machine that opens the .pptx, fall back to Arial Narrow / Arial / Menlo, or embed the fonts.

| Style | Font, weight | px | pt | Line height (px) | Tracking | Case | Colour |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Wordmark (title slide) | Chakra Petch 700 | 128 | 76.8 | 164 | +6% | UPPER | text + chroma shadow |
| Big stat | Chakra Petch 700 | 128 | 76.8 | 164 | 0 | as is | neon + glow |
| H1 | Chakra Petch 700 | 60 | 36 | 76 | +0.5% | Sentence | text + chroma shadow |
| Price (tier) | Chakra Petch 700 | 56 | 33.6 | 70 | 0 | as is | text |
| KPI value | Chakra Petch 700 | 48 | 28.8 | 60 | 0 | as is | text or neon |
| Tagline | Chakra Petch 600 | 40 | 24 | 52 | 0 | Sentence | text, key phrase neon |
| Panel title (SparkV Pro) | Chakra Petch 700 | 40 | 24 | 50 | 0 | as is | text |
| Readout value | Chakra Petch 600 | 34 | 20.4 | 44 | 0 | as is | text or neon |
| Card title | Chakra Petch 600 | 26 | 15.6 | 34 | 0 | Title | text |
| Table product / row title | Chakra Petch 600 | 20–21 | 12–12.6 | 26 | +2% | Title | text |
| Lead | Inter 400 | 22 | 13.2 | 31 | 0 | Sentence | text-2, bold words Inter 500 text |
| Body | Inter 400 | 16–18 | 9.6–10.8 | 22–26 | 0 | Sentence | text-2 |
| Kicker | JetBrains Mono 500 | 15 | 9 | 20 | +16% | UPPER | neon, trailing `// topic` in text-3 |
| HUD label | JetBrains Mono 500 | 13 | 7.8 | 16 | +14% | UPPER | text-3 |
| Data value (mono) | JetBrains Mono 500–700 | 15–22 | 9–13.2 | 20–26 | 0 | as is | text |
| Tag / badge | JetBrains Mono 500–700 | 11 | 6.6 | 22 (tag), 16 (badge) | +14% | UPPER | see colour rules |
| Source line | JetBrains Mono 400 | 12 | 7.2 | 16 | +2% | Sentence | text-3 |

Chakra Petch draws taller than its size: give every display text box a height of at least 1.28 x the font size (H1 60 px needs a 76 px box), otherwise PowerPoint clips or pushes the line.

## 4. Grid

12 columns on the 1600 px frame.

| Token | px | pt | in |
| --- | --- | --- | --- |
| Side margin | 80 | 48 | 0.667 |
| Column | 98 | 58.8 | 0.817 |
| Gutter | 24 | 14.4 | 0.2 |
| Column step (col + gutter) | 122 | 73.2 | 1.017 |
| Baseline unit | 8 | 4.8 | 0.067 |

- Column `c` (0–11) starts at `x = 80 + 122c` px. A block spanning `s` columns is `122s − 24` px wide.
- Common spans: 3 col = 342 px (2.85 in), 4 = 464 (3.867 in), 5 = 586 (4.883 in), 6 = 708 (5.9 in), 7 = 830 (6.917 in), 8 = 952 (7.933 in), 12 = 1440 (12 in).
- Frame lines are drawn every 40 px, so they line up with the 80 px margin.

### Vertical slots (px from top; pt = x 0.6)

| Slot | y | height | Notes |
| --- | --- | --- | --- |
| HUD header | 40 | 16 | Left: `■ SPARKV//TOPIC` (cols 0–3). Right: `[ 0N / 06 ]` (cols 8–11, right aligned) |
| Kicker | 104 | 20 | `[ 0x0N ] // topic` |
| H1 | 132 | 76 | One line, 12 cols |
| Lead | 216 | 62 | Max 2 lines, 8 cols |
| Glitch rule | 290 | 4 | 12 cols |
| Content | 320 | to 796 | 476 px of content |
| Source line (optional) | 808 | 16 | 12 cols |
| HUD footer | 844 | 16 | Left: context note. Right: `WWW.SPARKV.SI` |

Gaps between stacked blocks are 16 px (rows of cards) or 24 px (a KPI row above a chart). Nothing overlaps; every block sits on the column grid.

## 5. Textures and effects

| Element | Spec | python-pptx approach |
| --- | --- | --- |
| Background | `#000000` + 1 px lines every 40 px, `#FFFFFF` at 3.5% | Pre-render one 1600 x 900 PNG (or 3200 x 1800 for retina) with PIL and place it full-bleed at the back |
| Scanlines | 1 px `#FFFFFF` at 2.8% every 3 px, over everything | Bake into the same background PNG (they read fine under content) |
| Ambient bloom | Radial `#FF1E2D` at 13% → 0, 900 x 520 px ellipse; position varies per slide (title: top centre; problem: lower left; feature: left middle; metrics: lower right; comparison: left; pricing: centre) | Bake into the background PNG per slide |
| Corner brackets | 4 L-shapes, inset 24 px from the frame edge, arms 28 px long, 2 px thick, neon at 90% | 8 thin rectangles, no line |
| Glitch rule | Hairline `#26262B` 1 px across the span at y+2; neon segments: x 0–96 (2 px, y+1), x 108–120 (2 px, y+1), x 132–352 (1 px, neon 55%, y+0), x 368–408 (1 px, y+3); neon glow 6 px | Rectangles; add `a:glow rad=76200` (6 px) to the 2 px segments |
| Headline chroma | Shadows: −2 px x at neon 75%; +2 px x at aberration; 28 px blur neon 35% (wordmark: ±4 px, 48 px blur 50%) | Duplicate the text box twice behind the original: one neon at 25% transparency shifted −2 px (−1.2 pt), one `#00E5FF` at 72% transparency shifted +2 px; add a soft glow on the original via `a:effectLst/a:glow` |
| Red glow on numbers / CTA | 14–30 px blur neon at 45% | `a:glow` with `rad` 14–30 px (106,680–228,600 EMU), colour `FF1E2D`, alpha 45% |
| Panel | Fill `#0A0A0C` (8% transparency), 1 px `#26262B` border, square corners. Top-left tick: 14 x 14 px L in neon, 2 px | Rectangle + two 2 px rectangles for the tick |
| Highlight panel (SparkV, Pro tier) | Fill `#0E0406`, 1 px neon border, outer glow 40–48 px neon 18–22% | Rectangle with `a:glow` |
| Chip (hotkey) | panel-2 fill, 1 px line-2 border, JetBrains Mono 14 px, height 26 px, 10 px side padding | Rounded 0 rectangle |
| Status tag | Verified: neon fill, black text. Needs live check: no fill, 1 px line-2 border, text-2 text. 22 px tall, 8 px padding | |
| Live render image | Real SparkV render with the slate render backdrop keyed to transparent; drop shadow 0 18 px 50 px neon 32% plus 1 px neon edge glow | Insert the PNG from `img/`; add glow or a blurred red ellipse behind it |

## 6. Components (px on the 1600 x 900 frame)

| Slide | Blocks (col start / span / y / height) |
| --- | --- |
| 1 Title | Key visual `img/01-home.png` 2/8/0/196, hanging from the top edge like the notch drawer. Caption 2/8/216/16 centred. Kicker 0/8/296. Wordmark 0/8/328/164. Tagline 0/8/496/52. Lead 0/8/560/62. Glitch 0/8/648. CTA line 0/8/680/20. Readout panel 8/4/296/500 with five rows (label + note left, value right, rows split by hairlines) |
| 2 Problem | Stat column 0/5/320/476: label, big stat `$300+`, caption, two numbered evidence rows (`E-01`, `E-02`, mono neon index 56 px column). Process table 5/7/320/476: header 44 px, five rows, summary bar 56 px with neon-deep top line and red-to-clear tint |
| 3 Feature | MacBook mockup 0/6/320/456: lid 640 x 400 px at x+34, y+20, radius 22 px top, fill `#121215`, border `#2C2C32`; screen inset 12 px; notch 118 x 22 px black, 10 px bottom radius; drawer image `img/10-agents-hub.png` 520 px wide, top-centred under the notch; base 708 x 14 px at y+420. Four feature cards 6/3 and 9/3 at y 320 and 552, each 216 tall: chip row 28, title 34, body 46 (2 lines max), status tag bottom |
| 4 Metrics | Four KPI tiles 0/3, 3/3, 6/3, 9/3 at 320/136. Chart panel 0/7/480/316: scale $0–400, label column 150 px, track 28 px tall, value column 104 px; competitors as one stacked grey bar, SparkV as a solid neon bar; five-item legend. Unit economics panel 7/5/480/316 with six rows; the total row has a neon-deep top line and a neon value. Source line at y 808 |
| 5 Comparison | SparkV panel 0/5/320/476 (highlight panel): label, name, price line in neon mono, seven coverage rows (mono neon tag 84 px column + text), mono footer. Table 5/7/320/428: columns 168 / 176 / 176 / rest px, 20 px side padding, overlap cell has a 2 px neon left rule. Note 5/7/764/32 |
| 6 Pricing | Three tier cards 0/4, 4/4, 8/4 at 320/412; Pro uses the highlight panel and a `LAUNCH $29 · ₹999` badge. Inside: label 16, price 70 (56 px number + mono period), INR 22, sub 22, six check-mark bullets (Inter 16/22, 6 px apart), meta row 32 with a top hairline. CTA button 0/4/748/48 (neon fill, black JetBrains Mono 700 16 px, +14% tracking). Middle note 4/4/748/48. Right HUD 8/4/748/48 right aligned |

## 7. Content rules used here

- Every number is from `docs/SparkV-Business-Plan.md` or `docs/SparkV-Feature-Guide.md` (Oct 2026). Year-one stack = Granola $14 x 12 + Wispr Flow $144/yr + Paste $29.99/yr + CleanShot X $29 + NotchNook $25 = $395.99. Net per Pro sale = 39 − (5% + $0.50) = $36.55.
- No traction, revenue, user or team numbers exist yet. If a slide needs one, write a visible placeholder such as `[TBD: monthly active users]`.
- Feature status tags copy the Feature Guide labels ("Verified headless", "Needs a live check").
- Images: `img/01-home.png` and `img/10-agents-hub.png` are copies of `docs/screenshots/` renders. Only the slate render backdrop was made transparent; the app UI pixels are unchanged.
