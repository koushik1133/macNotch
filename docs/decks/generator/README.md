# SparkV deck generator (Apple minimal)

`sparkv_deck.py` builds 16:9 `.pptx` decks (13.333 x 7.5 in) in the Apple-minimal style from
`../style-demos/apple-minimal/STYLE.md`. One layout model produces three things:

1. the `.pptx` (python-pptx, blank layouts, native charts, speaker notes, hidden backup slides),
2. an HTML preview (one 1600 x 900 frame per slide, 120 px per inch, same fonts, colours, images),
3. a layout check (text fit, overlaps, containment, safe area, image upscale, min type size, red share).

## Run

```sh
cd "docs/decks/generator"
/opt/anaconda3/bin/python3 demo_customer.py            # build + Python layout check
/opt/anaconda3/bin/python3 demo_customer.py --chrome   # + headless Chrome overflow check
/opt/anaconda3/bin/python3 demo_customer.py --chrome --shots /tmp/shots   # + PNG per slide
```

Outputs: `demo/sparkv-customer-demo.pptx`, `demo/preview/index.html` (open in a browser;
`index.html?slide=N` shows one frame at 1:1), `demo/layout-report.json`. The script exits 1 if any
check reports an error. Requires python-pptx 1.0.2, Pillow and fontTools (all in /opt/anaconda3).

## Minimal use

```python
import sys; sys.path.insert(0, "docs/decks/generator")
from sparkv_deck import Deck, accent, load_outline

o = load_outline("customer")
d = Deck("SparkV customer deck")
s = o["slides"][0]
d.title_slide(accent(s["header"], s["header_accent"]), eyebrow=s["body"][0], lead=s["subtitle"],
              cta=s["body"][1], image="01-home.png", notes=s["notes"])
d.save("docs/decks/customer/sparkv-customer.pptx")
problems = d.check_layout()
d.html_preview("docs/decks/customer/preview/index.html", problems=problems)
```

## Text markup

`**text**` semibold emphasis (ink) · `==text==` SparkV red (use only at 18 pt or more) ·
`[TBD: ...]` always grey italic · `\n` line break. `accent(header, header_accent)` wraps the
outline's accent phrase in `**`.

## Layouts

| Method | Ground | What it places |
| --- | --- | --- |
| `title_slide(title, lead, eyebrow, image, cta)` | mist | red eyebrow, 55 pt display, lead, optional pill, MacBook bleeding off the bottom; no footer |
| `section_header(title, eyebrow, lead, image, captions)` | mist | centred headline, MacBook, up to 3 captions under hairlines |
| `minimal_body(title, eyebrow, lead, points)` | white | 48 pt headline on 10 cols, 1-4 numbered points bottom-aligned |
| `feature_showcase(title, eyebrow, lead, bullets, image, frame)` | mist | text on cols 1-4 (centred), `frame="notch"` MacBook mockup or `"window"` rounded shot on cols 5-12; bullets may be `(key, label)` |
| `metrics_dashboard(title, metrics, chart)` | white | 2-6 number tiles, or 1-3 tiles + chart card |
| `chart_slide(title, chart, side)` | white | one chart card, optional notes column |
| `two_column_comparison(title, left_head, right_head, rows, summary)` | mist | label + two option columns, check/cross marks, red summary |
| `comparison_table(title, columns, rows, widths, highlight_row)` | white | competitor table, highlighted row with mist band and red edge |
| `pricing_table(title, plans, cta, aside)` | mist | 2-4 plan cards (USD + INR), highlighted plan with red outline and tag, CTA row |
| `timeline(title, nodes)` | white | 3-6 nodes on a rail, optional thumbnails, red active dot |
| `quote_or_cta(title, lead, button, caption, extra, image)` / `quote_or_cta(quote=..., attribution=...)` | mist | closing CTA with device, or a quote |
| `appendix_table(title, columns, rows)` | white | dense 9 pt reference table (use `hidden=True`, `page="A1"`) |

Every layout takes `notes`, `footer` (left footer text; page number is automatic), `page`, `hidden`.

Chart spec: `{"type": "column"|"column_stacked"|"bar"|"bar_stacked"|"line"|"doughnut", "title",
"subtitle", "categories", "series": [{"name", "values" (None = missing), "color", "point_colors": {i: colour}}],
"number_format": "$#,##0.00", "axis_max", "tbd": ["[TBD: ...]"], "source"}`. Colours are tokens
(`red`, `ink`, `bar`, `hairline` ...) or hex.

## Guarantees and limits

- Every text box has word wrap on, auto-size off, zero insets and exact line spacing. Its height
  comes from PIL measurement (Helvetica Neue faces, glyph fallback to SF / Apple Symbols, 4%
  width safety margin). Fonts shrink in 2.5% steps down to a per-style floor; past that the build
  raises `TextFitError` naming the slide and text. Nothing silently overflows.
- Layout functions raise `LayoutError` when content cannot fit the grid (too many points, no room
  for the device, and so on).
- Images keep their aspect ratio and are never shown above `max_upscale` (1.25x) of their pixels
  at `ref_ppi` (144 px/in = slide played at 1920 x 1080).
- Fonts: profile `mac` (Helvetica Neue Light / Helvetica Neue / Helvetica Neue Medium, default
  here because SF Pro is not installed), `sf` (auto when SF Pro Display/Text are in /Library/Fonts),
  `inter` (for decks shown on Windows; Inter must be installed there).
- The MacBook screen gradient samples the screenshot's own top and bottom edge colours
  (`wallpaper="auto"`) so the drawer blends with no seam; `wallpaper="style"` uses the STYLE.md stops.
- The HTML chart is an SVG drawing of the same data and axis range; PowerPoint lays out its native
  chart itself, so bar positions differ slightly.
- Layout check rules: siblings in the same container may not overlap unless one lists the other
  in `hosts` (notch on screenshot, dots on the timeline rail); children must sit inside their
  container; top-level elements must sit inside the safe area (x 1.0-12.333, y 0.75-7.25) unless
  marked as bleeding.
