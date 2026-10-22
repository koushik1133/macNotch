"""
Build the SparkV enterprise deck (Team plan, 30-day pilot) in the Apple-minimal style.

Reads   docs/decks/enterprise/outline.json
Writes  docs/decks/enterprise/SparkV-Enterprise-Deck.pptx
        docs/decks/enterprise/preview/index.html   (?slide=N shows one 1600 x 900 frame)
        docs/decks/enterprise/layout-report.json

Run:    /opt/anaconda3/bin/python3 build_enterprise.py [--chrome] [--shots DIR]

Uses docs/decks/generator/sparkv_deck.py unchanged. Layouts the library does not have
(source line in KPI tiles, chart + tile grid, multi-shot showcase, two lists, step lists,
table + chart, pricing + chart, pilot CTA) live in the Deck subclass below and are built only
from library primitives, so the same layout check and HTML preview apply.
All copy, numbers and notes come from the outline. [TBD: ...] text stays visible (grey italic).
"""
import argparse
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "generator"))

from pptx import Presentation  # noqa: E402
import sparkv_deck as sd  # noqa: E402
from sparkv_deck import (Deck as _BaseDeck, accent, chrome_check, chrome_screenshot,  # noqa: E402
                         load_outline, col_x, span, TYPE, TextFitError, LayoutError)

PX = sd.PX_PER_IN
MARGIN, CONTENT_W, TOP, BOTTOM = sd.MARGIN, sd.CONTENT_W, sd.TOP, sd.BOTTOM
SLIDE_W, SLIDE_H, GUTTER = sd.SLIDE_W, sd.SLIDE_H, sd.GUTTER

PPTX = os.path.join(HERE, "SparkV-Enterprise-Deck.pptx")
PREVIEW = os.path.join(HERE, "preview", "index.html")
REPORT = os.path.join(HERE, "layout-report.json")

LIVE = "Real render of the current build, sample data."


def lh(style, lines=1):
    ts = TYPE[style]
    return lines * ts.size * ts.lh / 72


# =========================================================================== layouts
class Deck(_BaseDeck):
    """Library deck plus the enterprise layouts (library primitives only)."""

    # Sample-data hygiene (same rule as the investor deck): these two renders show a sample note
    # "Pricing: Free, Pro $9, Team $19 per seat" that contradicts SparkV's real pricing. Until they
    # are re-captured, a clean render of the same feature from the outline's image lists is used.
    SAFE_IMAGE = {
        "16-universal-search-panel.png": "15-universal-search.png",
        "36-meeting-notes.png": "37-meeting-live-answers.png",
    }

    def image_path(self, name, final=None, media_root=None):
        if not os.path.isabs(name):
            name = self.SAFE_IMAGE.get(name, name)
        return super().image_path(name, final, media_root)


    # ------------------------------------------------------------- KPI tiles with a source line
    def tiles(self, s, metrics, boxes, value_style="kpi"):
        """Mist cards: big number, caption (small), optional source line (note, ink-3) pinned to
        the card bottom. One number size for every tile on the slide."""
        padx, pady, gap = 28 / PX, 24 / PX, 12 / PX
        ts = TYPE[value_style]
        k = 1.0
        for m, (x, y, w, h) in zip(metrics, boxes):
            iw = w - 2 * padx
            p = self._metric_value_para(m, value_style)
            _, _, kk = self.fit_text([p], iw, lh(value_style) + 0.001, ts.min_scale,
                                     f"slide {s.page} metric {m.get('value')}")
            k = min(k, kk)
            lab = self.measure([self.P(m["label"], "small")], iw)[0] if m.get("label") else 0
            src = self.measure([self.P(m["source"], "note")], iw)[0] if m.get("source") else 0
            room = h - 2 * pady - (gap + lab if lab else 0) - (gap + src if src else 0) - 0.004
            k = min(k, room / lh(value_style))
        if k < ts.min_scale - 1e-9:
            raise TextFitError(f"slide {s.page}: KPI tiles too small (scale {k:.2f})")
        for m, (x, y, w, h) in zip(metrics, boxes):
            iw = w - 2 * padx
            card = self.card(s, x, y, w, h, name="metric card")
            p = self._metric_value_para(m, value_style).scaled(k)
            vh = p.pitch / 72 + 0.0005
            self.text(s, x + padx, y + pady, iw, vh, [p], value_style, parent=card, name="metric value")
            yy = y + pady + vh + gap
            if m.get("label"):
                lab = self.measure([self.P(m["label"], "small")], iw)[0] + 0.0005
                self.text(s, x + padx, yy, iw, lab, m["label"], "small", parent=card, name="metric label")
            if m.get("source"):
                src = self.measure([self.P(m["source"], "note")], iw)[0] + 0.0005
                self.text(s, x + padx, y + h - pady - src, iw, src, m["source"], "note", parent=card,
                          name="metric source")

    # ------------------------------------------------------------- bottom strip
    def strip(self, s, texts, style="body"):
        """1-3 short texts along the bottom of the content area, each under a hairline.
        Returns the strip's top y."""
        spans = {1: [(1, 12)], 2: [(1, 6), (7, 6)], 3: [(1, 4), (5, 4), (9, 4)],
                 4: [(1, 3), (4, 3), (7, 3), (10, 3)]}[len(texts)]
        need = max(self.measure([self.P(t, style)], span(w))[0] for t, (_, w) in zip(texts, spans)) + 0.0005
        top = BOTTOM - need - 0.15
        for t, (c0, w) in zip(texts, spans):
            self.line(s, col_x(c0), top, col_x(c0) + span(w), top, name="strip rule")
            self.text(s, col_x(c0), top + 0.15, span(w), need, t, style, name="strip text")
        return top

    # ------------------------------------------------------------- title
    def title_ent(self, title, *, eyebrow, lead, line, image, notes, lid_w=9.167):
        s = self._new("title_slide", "mist", notes, False, None, False)
        e = self.text(s, MARGIN, TOP, CONTENT_W, None, eyebrow, "eyebrow", align="c", color="red", name="eyebrow")
        t = self.text(s, MARGIN, e.b + 18 / PX, CONTENT_W, None, title, "display", align="c",
                      max_h=lh("display", 2) + 0.001, name="headline")
        l_ = self.text(s, MARGIN, t.b + 26 / PX, CONTENT_W, None, lead, "lead", align="c",
                       max_h=lh("lead", 1) + 0.001, name="lead")
        b = self.text(s, MARGIN, l_.b + 12 / PX, CONTENT_W, None, line, "body", align="c",
                      max_h=lh("body", 1) + 0.001, name="title line")
        dy = max(3.767, b.b + 0.35)
        self.macbook(s, (SLIDE_W - lid_w) / 2, dy, lid_w, image, pad_px=16, clip_bottom=SLIDE_H, name="hero device")
        return s

    # ------------------------------------------------------------- 4 KPIs across + strip
    def kpi_row(self, title, *, eyebrow, lead, metrics, strip, notes, footer):
        s = self._new("metrics_dashboard", "white", notes, footer, None, False)
        y = self._header(s, eyebrow, title, lead, h1="h1_dash", title_lines=1, lead_lines=1)
        st = self.strip(s, [strip])
        room = st - 0.35 - (y + 0.4)
        h = min(2.3, room)
        top = y + 0.4 + (room - h) / 2
        n = len(metrics)
        sp_ = 12 // n
        boxes = [(col_x(1 + i * sp_), top, span(sp_), h) for i in range(n)]
        self.tiles(s, metrics, boxes)
        return s

    # ------------------------------------------------------------- chart card + tile grid
    def dash_chart(self, title, *, eyebrow, lead, metrics, chart, notes, footer, chart_span=7, tile_cols=1, value_style="kpi"):
        s = self._new("metrics_dashboard", "white", notes, footer, None, False)
        y = self._header(s, eyebrow, title, lead, h1="h1_dash", title_lines=1, lead_lines=1)
        top = y + 0.35
        self.chart_card(s, col_x(1), top, span(chart_span), BOTTOM - top, chart)
        x0, W = col_x(chart_span + 1), span(12 - chart_span)
        gap = 24 / PX
        n = len(metrics)
        rows = math.ceil(n / tile_cols)
        tw = (W - (tile_cols - 1) * gap) / tile_cols
        th = (BOTTOM - top - (rows - 1) * gap) / rows
        boxes = [(x0 + (i % tile_cols) * (tw + gap), top + (i // tile_cols) * (th + gap), tw, th) for i in range(n)]
        self.tiles(s, metrics, boxes, value_style)
        return s

    # ------------------------------------------------------------- feature showcase, several shots
    def _media_plan(self, items):
        plans = []
        for it in items:
            bx, by, bw, bh = it["box"]
            al, va = it.get("align", "c"), it.get("valign", "t")
            if it["kind"] == "mac":
                lid = min(bw * 6.833 / 7.467, self.macbook_lid_for_height(bh))
                h = self.macbook_height(lid)
                x = bx + {"l": 0, "c": (bw - lid) / 2, "r": bw - lid}[al]
                y = by + {"t": 0, "m": (bh - h) / 2, "b": bh - h}[va]
                plans.append((it, (x, y, lid, h), None))
            else:
                path = self.image_path(it["file"])
                pad = 0.12 if it["kind"] == "screen" else 0.0
                f = self.fit_image(path, bx + pad, by + pad, bw - 2 * pad, bh - 2 * pad, mode="contain",
                                   align=al, valign=va)
                plans.append((it, (f["x"] - pad, f["y"] - pad, f["w"] + 2 * pad, f["h"] + 2 * pad), f))
        return plans

    def showcase(self, title, *, eyebrow, lead, bullets, media, notes, footer, page=None, hidden=False):
        """Text on columns 1-5 (vertically centred, bullets at body size under hairlines);
        screenshots on columns 6-12. media: [{kind: mac|window|screen, file, box: (x, y, w, h)
        relative to the media area, align, valign}]; the group is centred vertically."""
        s = self._new("feature_showcase", "mist", notes, footer, page, hidden)
        x, w = col_x(1), span(5)
        avail = BOTTOM - TOP
        row_pad = 12 / PX
        parts = [("eyebrow", eyebrow, 0, 1), ("h1_side", title, 20 / PX, 3), ("body", lead, 22 / PX, 3)]
        hs = [min(self.measure([self.P(t, st)], w)[0], lh(st, n)) for st, t, _, n in parts]
        bh = [self.measure([self.P(b, "body")], w)[0] + 2 * row_pad for b in bullets]
        total = sum(hs) + sum(g for _, _, g, _ in parts) + (30 / PX + sum(bh) if bullets else 0)
        if total > avail + 1e-6:
            raise LayoutError(f"showcase {s.page}: text block {total:.2f} in > {avail:.2f} in, split the slide")
        y = TOP + (avail - total) / 2
        for st, t, gap, n in parts:
            el = self.text(s, x, y + gap, w, None, t, st, max_h=lh(st, n) + 0.001, name=st)
            y = el.b
        if bullets:
            y += 30 / PX
            self.line(s, x, y, x + w, y, name="list rule")
            for b, h in zip(bullets, bh):
                self.text(s, x, y + row_pad, w, h - 2 * row_pad, b, "body", name="bullet")
                y += h
                self.line(s, x, y, x + w, y, name="list rule")
        MX, MW = col_x(6), span(7)
        plans = self._media_plan(media)
        for it, (px_, py_, pw, ph), _ in plans:
            if px_ < -1e-6 or px_ + pw > MW + 1e-6:
                raise LayoutError(f"showcase {s.page}: {it['file']} leaves the media columns")
        y0 = min(p[1][1] for p in plans)
        y1 = max(p[1][1] + p[1][3] for p in plans)
        if y1 - y0 > avail + 1e-6:
            raise LayoutError(f"showcase {s.page}: media {y1 - y0:.2f} in tall > {avail:.2f} in")
        dy = TOP + (avail - (y1 - y0)) / 2 - y0
        for it, (px_, py_, pw, ph), f in plans:
            if it["kind"] == "mac":
                self.macbook(s, MX + px_, dy + py_, pw, it["file"], name="device")
                continue
            path = self.image_path(it["file"])
            if it["kind"] == "window":
                self.picture(s, path, MX + f["x"], dy + f["y"], f["w"], f["h"], radius=0.08,
                             name=f"window {it['file']}")
            else:
                top_c, bot_c = self.edge_colors(path)
                card = self.rect(s, MX + px_, dy + py_, pw, ph, grad=[(0, top_c), (1, bot_c)], radius=0.14,
                                 name=f"screen card {it['file']}")
                self.picture(s, path, MX + f["x"], dy + f["y"], f["w"], f["h"], radius=0.05, parent=card,
                             name=f"screen {it['file']}")
        return s

    # ------------------------------------------------------------- two lists + chips
    def two_lists(self, title, *, eyebrow, lead, columns, chips, notes, footer):
        s = self._new("two_column_comparison", "mist", notes, footer, None, False)
        y = self._header(s, eyebrow, title, lead, h1="h1", title_lines=1, lead_lines=1)
        st = self.strip(s, chips, style="small_ink")
        top = y + 0.4
        mark_sz, row_pad = 0.14, 12 / PX
        for (c0, w_), (head, bullets, mark) in zip([(1, 6), (7, 6)], columns):
            x, w = col_x(c0), span(w_)
            hd = self.text(s, x, top, w, lh("h3") + 0.0005, head, "h3", name="list head")
            yy = hd.b + 0.12
            self.line(s, x, yy, x + w, yy, color="ink", name="list head rule")
            tx = x + mark_sz + 0.14
            for b in bullets:
                h = self.measure([self.P(b, "body_ink")], x + w - tx)[0] + 0.0005
                self.mark(s, mark, x, yy + row_pad + 0.035, mark_sz, color="ink", name="list mark")
                self.text(s, tx, yy + row_pad, x + w - tx, h, b, "body_ink", name="list item")
                yy += h + 2 * row_pad
                self.line(s, x, yy, x + w, yy, name="list rule")
            if yy > st - 0.3 + 1e-6:
                raise LayoutError(f"two_lists {s.page}: lists run into the strip")
        return s

    # ------------------------------------------------------------- vertical steps + window shot
    def steps_image(self, title, *, eyebrow, lead, steps, image, strip, notes, footer):
        s = self._new("timeline", "white", notes, footer, None, False)
        y = self._header(s, eyebrow, title, lead, h1="h1", title_lines=1, lead_lines=1)
        st = self.strip(s, strip)
        top, bot = y + 0.35, st - 0.3
        x, w = col_x(1), span(8)
        key_w = 2.0
        row_pad = 11 / PX
        rows = []
        for i, stp in enumerate(steps):
            h = max(lh("h3"), self.measure([self.P(stp["text"], "body")], w - key_w)[0]) + 0.0005
            rows.append(h)
        total = sum(rows) + 2 * row_pad * len(rows)
        if top + total > bot + 1e-6:
            raise LayoutError(f"steps_image {s.page}: steps need {total:.2f} in, have {bot - top:.2f}")
        yy = top + (bot - top - total) / 2
        self.line(s, x, yy, x + w, yy, name="step rule")
        for i, (stp, h) in enumerate(zip(steps, rows)):
            self.text(s, x, yy + row_pad + 0.03, 0.32, lh("label") + 0.0005, f"{i + 1:02d}", "label",
                      name="step number")
            self.text(s, x + 0.36, yy + row_pad, key_w - 0.5, lh("h3") + 0.0005, stp["label"], "h3",
                      name="step label")
            self.text(s, x + key_w, yy + row_pad, w - key_w, h, stp["text"], "body", name="step text")
            yy += h + 2 * row_pad
            self.line(s, x, yy, x + w, yy, name="step rule")
        path = self.image_path(image)
        f = self.fit_image(path, col_x(9), top, span(4), bot - top, mode="contain", align="r", valign="m")
        self.picture(s, path, f["x"], f["y"], f["w"], f["h"], radius=0.08, name=f"window {image}")
        return s

    # ------------------------------------------------------------- horizontal timeline + strip
    def timeline_strip(self, title, *, eyebrow, lead, nodes, strip, notes, footer):
        s = self._new("timeline", "white", notes, footer, None, False)
        y = self._header(s, eyebrow, title, lead, h1="h1", title_lines=1, lead_lines=1)
        st = self.strip(s, strip)
        n = len(nodes)
        cw = (CONTENT_W - (n - 1) * GUTTER) / n
        xs = [MARGIN + i * (cw + GUTTER) for i in range(n)]
        th = lh("h3") + 0.0005
        text_h = max(self.measure([self.P(nd["text"], "body")], cw)[0] for nd in nodes) + 0.0005
        block = 0.25 + th + 0.1 + text_h
        top, bot = y + 0.5, st - 0.4
        if top + block > bot + 1e-6:
            raise LayoutError(f"timeline_strip {s.page}: needs {block:.2f} in")
        yy = top + (bot - top - block) / 2
        rail = self.line(s, MARGIN, yy, MARGIN + CONTENT_W, yy, name="timeline rail")
        for i, (xi, nd) in enumerate(zip(xs, nodes)):
            act = nd.get("active")
            d = 0.16 if act else 0.12
            self.rect(s, xi, yy - d / 2, d, d, oval=True, fill="red" if act else "ink", hosts=(rail,),
                      name="timeline dot")
            self.text(s, xi, yy + 0.25, cw, th, nd["label"], "h3", name="timeline label")
            self.text(s, xi, yy + 0.25 + th + 0.1, cw, text_h, nd["text"], "body", name="timeline text")
        return s

    # ------------------------------------------------------------- table + chart
    def table_chart(self, title, *, eyebrow, lead, columns, rows, widths, highlight_row, chart, note,
                    notes, footer, table_span=7):
        s = self._new("comparison_table", "white", notes, footer, None, False)
        y = self._header(s, eyebrow, title, lead, h1="h1", title_lines=1, lead_lines=1)
        top = y + 0.35
        tw = span(table_span)
        nh = self.measure([self.P(t, "small") for t in note], tw)[0] + 0.0005
        bottom = self._table(s, MARGIN, top, tw, columns, rows, widths=widths, highlight_row=highlight_row,
                             max_bottom=BOTTOM - nh - 0.25)
        self.text(s, MARGIN, BOTTOM - nh, tw, nh, note, "small", name="table note")
        self.chart_card(s, col_x(table_span + 1), top, span(12 - table_span), BOTTOM - top, chart)
        return s

    # ------------------------------------------------------------- pricing cards + chart
    def pricing_chart(self, title, plans, *, eyebrow, lead, chart, aside, notes, footer):
        s = self._new("pricing_table", "mist", notes, footer, None, False)
        y = self._header(s, eyebrow, title, lead, h1="h1", title_lines=1, lead_lines=1)
        top = y + 0.35
        ah = self.measure([self.P(aside, "small")], span(9))[0] + 0.0005
        bottom = BOTTOM - ah - 0.2
        self._pricing_cards(s, plans, top, bottom, 30 / PX, 24 / PX, 3)
        self.text(s, MARGIN, BOTTOM - ah, span(9), ah, aside, "small", name="pricing aside")
        self.chart_card(s, col_x(10), top, span(3), BOTTOM - top, chart)
        return s

    # ------------------------------------------------------------- closing CTA
    def pilot_cta(self, title, *, lead, steps, contact, image, notes, lid_w=7.4):
        s = self._new("quote_or_cta", "mist", notes, False, None, False)
        y = self._header(s, None, title, lead, align="c", h1="h1_large", title_lines=1, lead_lines=1)
        top = y + 0.4
        spans = [(1, 4), (5, 4), (9, 4)]
        need = max(self.measure([self.P(t, "body_ink")], span(w))[0] for t, (_, w) in zip(steps, spans)) + 0.0005
        for i, (t, (c0, w)) in enumerate(zip(steps, spans)):
            x = col_x(c0)
            self.line(s, x, top, x + span(w), top, name="step rule")
            self.text(s, x, top + 0.16, span(w), lh("label") + 0.0005, f"{i + 1:02d}", "label", name="step number")
            self.text(s, x, top + 0.16 + lh("label") + 0.1, span(w), need, t, "body_ink", name="step text")
        yy = top + 0.16 + lh("label") + 0.1 + need
        c = self.text(s, MARGIN, yy + 0.25, CONTENT_W, None, contact, "body", align="c",
                      max_h=lh("body") + 0.001, name="contact")
        dy = c.b + 0.4
        if dy + 1.2 > SLIDE_H:
            raise LayoutError("pilot_cta: no room for the device")
        self.macbook(s, (SLIDE_W - lid_w) / 2, dy, lid_w, image, pad_px=14, clip_bottom=SLIDE_H, name="device")
        return s


# =========================================================================== content
def build() -> Deck:
    o = load_outline("enterprise")
    S = {s["id"]: s for s in o["slides"]}
    src = {x["id"]: x for x in o["sources"]}
    d = Deck(o["deck"]["title"])

    def img(s, role):
        return next(i["file"] for i in s["images"] if i["role"] == role)

    def split_kpi(line):
        return [p.strip() for p in line.split("|")]

    # 01 title ---------------------------------------------------------------------
    s = S["title"]
    # R1 hero recording is not captured yet: the outline's fallback still is used.
    hero = next(i for i in s["images"] if i["role"] == "hero_fullbleed")
    hero_file = hero["file"] if os.path.exists(os.path.join(HERE, hero["file"].split("@")[0])) else hero["fallback"]
    d.title_ent(s["header"], eyebrow="SparkV Team", lead=s["subtitle"],
                line=f"{s['body'][0]} · {s['body'][1]} · **{s['body'][2]}**",
                image=hero_file, notes=s["notes"])

    # 02 problem ---------------------------------------------------------------------
    s = S["problem"]
    mets = []
    for line in s["body"][:4]:
        v, lab, so = split_kpi(line)
        mets.append({"value": v, "label": lab, "source": so})
    d.kpi_row(s["header"], eyebrow="The problem", lead=s["subtitle"], metrics=mets,
              strip="**Your numbers:** " + s["body"][4], notes=s["notes"],
              footer="3x compares speech with a phone keyboard, not a desktop keyboard. McKinsey figure is from 2012.")

    # 03 market ----------------------------------------------------------------------
    s = S["market"]
    c = s["chart"]
    mets = []
    for line in s["body"]:
        if line.startswith("[TBD"):
            mets.append({"value": "[TBD]", "label": line})
        else:
            v, lab, so = split_kpi(line)
            mets.append({"value": v, "label": lab, "source": so})
    d.dash_chart(s["header"], eyebrow="Market", lead=s["subtitle"], metrics=mets, tile_cols=2, chart={
        "type": "column", "title": c["title"], "categories": c["categories"],
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "bar",
                    "point_colors": {1: "ink"}}],
        "number_format": c["number_format"],
        "source": "IDC preliminary, Jan 2026 (9to5Mac, MacTech). 2024 bar derived: 25.6 / 1.111 (IDC growth rate). "
                  + ". ".join(c["annotations"]) + ".",
    }, notes=s["notes"], footer="Context for fleet size, not a SparkV revenue claim.")

    # 04 hub -------------------------------------------------------------------------
    s = S["hub"]
    bullets = [re.sub(r"^(\w+):", r"**\1:**", b) for b in s["body"]]
    d.showcase(s["header"], eyebrow="Agents hub", lead=s["subtitle"], bullets=bullets,
               media=[{"kind": "mac", "file": img(s, "main"), "box": (0, 0, span(7), 6.0), "valign": "m"}],
               notes=s["notes"], footer=LIVE)

    # 05 write -----------------------------------------------------------------------
    s = S["write"]
    W = span(7)
    d.showcase(s["header"], eyebrow="Write", lead=s["subtitle"], bullets=s["body"], media=[
        {"kind": "screen", "file": img(s, "band"), "box": (0, 0, W, 1.25)},
        {"kind": "screen", "file": img(s, "main"), "box": (0, 1.5, W, 2.3)},
        {"kind": "window", "file": img(s, "inset"), "box": (0, 4.05, W, 1.95)},
    ], notes=s["notes"], footer=LIVE + " Dictation and Reply Drafter need a live check.")

    # 06 meetings --------------------------------------------------------------------
    s = S["meetings"]
    d.showcase(s["header"], eyebrow="Meetings", lead=s["subtitle"], bullets=s["body"], media=[
        # One meeting window: the "main" render (36) is swapped for the clean "secondary" (37), so
        # showing both would repeat the same image.
        {"kind": "window", "file": img(s, "secondary"), "box": (0, 0, W, 2.3), "align": "c"},
        {"kind": "window", "file": img(s, "inset"), "box": (0, 2.45, W, 2.05)},
    ], notes=s["notes"], footer=LIVE + " Audio capture needs a live check.")

    # 07 find ------------------------------------------------------------------------
    s = S["find"]
    d.showcase(s["header"], eyebrow="Find", lead=s["subtitle"], bullets=s["body"], media=[
        {"kind": "window", "file": img(s, "main"), "box": (0, 0, 3.9, 2.6), "align": "l"},
        {"kind": "window", "file": img(s, "inset"), "box": (4.15, 0, W - 4.15, 2.6), "align": "r"},
        {"kind": "screen", "file": img(s, "band"), "box": (0, 2.85, W, 1.4)},
    ], notes=s["notes"], footer=LIVE + " The screen assistant needs a live check.")

    # 08 UI audit --------------------------------------------------------------------
    s = S["ui_audit"]
    d.showcase(s["header"], eyebrow="UI Audit", lead=s["subtitle"], bullets=s["body"][:4], media=[
        {"kind": "window", "file": img(s, "main"), "box": (0, 0, W, 4.4)},
    ], notes=s["notes"], footer="Verified end to end on the bundled test site on 127.0.0.1. Use only on sites you own or may test.")
    # The fifth bullet is the verified run; it gets its own proof slide instead of a sixth list row.
    v = s["body"][4]
    d.kpi_row("UI Audit, verified end to end", eyebrow="UI Audit · proof", lead=v,
              metrics=[{"value": "6", "label": "pages crawled on the planted-issue test site"},
                       {"value": "69", "label": "findings"},
                       {"value": "3", "label": "critical findings"},
                       {"value": "15", "label": "high findings"}],
              strip="**Runner self-test:** 48/48 passed. P produced a 51,666-character fix prompt covering 60 issues.",
              notes=s["notes"],
              footer="SparkV's own controller on 127.0.0.1; Apple Intelligence wrote the summary on device. Needs Node 20+ and Playwright's Chromium.")

    # 09 ROI -------------------------------------------------------------------------
    s = S["roi"]
    c = s["chart"]
    mets = []
    for line in s["body"][:3]:
        v, lab, so = split_kpi(line)
        mets.append({"value": v, "label": lab, "source": so.replace("assumptions below", "assumptions in backup A1")})
    d.dash_chart(s["header"], eyebrow="ROI model", lead=s["subtitle"], metrics=mets, tile_cols=1, value_style="tile", chart={
        "type": "bar", "title": c["title"], "subtitle": "Model: assumptions, not measured",
        "categories": c["categories"],
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "bar"}],
        "number_format": c["number_format"],
        "source": "Model (backup A1). Dictation speed-up is half of Stanford 2016's 3x phone-keyboard result. "
                  "Break-even: minutes per week = 96 / (46 working weeks x hourly rate) x 60; at $40/h, 3.1 min.",
    }, notes=s["notes"], footer=s["body"][3] + ".")

    # 10 privacy ---------------------------------------------------------------------
    s = S["privacy"]
    cl = s["columns"]
    d.two_lists(s["header"], eyebrow="Privacy and security", lead=s["subtitle"],
                columns=[(cl[0]["title"], cl[0]["bullets"], "check"), (cl[1]["title"], cl[1]["bullets"], "cross")],
                chips=s["body"], notes=s["notes"],
                footer="Gap to disclose: [TBD: managed preference to disable Groq] org-wide.")

    # 11 deploy ----------------------------------------------------------------------
    s = S["deploy"]
    d.steps_image(s["header"], eyebrow="Deployment", lead=s["subtitle"], steps=s["steps"],
                  image=img(s, "main"), strip=s["body"], notes=s["notes"],
                  footer="Check PPPC behaviour against Apple's Privacy Preferences Policy Control payload docs for your macOS version.")

    # 12 admin -----------------------------------------------------------------------
    s = S["admin_support"]
    d.minimal_body(s["header"], eyebrow="Admin and support", lead=s["subtitle"],
                   points=[(r["label"], r["text"]) for r in s["rows"]], notes=s["notes"],
                   footer="Not available today: SSO, SCIM, a central policy console, live Spaces sync.")

    # 13 competition -----------------------------------------------------------------
    s = S["competition"]
    t, c = s["table"], s["chart"]
    dt = {r["item"]: r for r in c["data_table"]}
    stack = [n for n in ("Wispr Flow Teams", "Granola Business", "Raycast Pro", "Paste", "CleanShot X")]
    d.table_chart(s["header"], eyebrow="Consolidation", lead=s["subtitle"],
                  columns=t["columns"], rows=t["rows"], widths=[2.2, 2.4, 2.4], highlight_row=len(t["rows"]) - 1,
                  note=s["body"], chart={
                      "type": "column", "title": c["title"], "categories": c["categories"],
                      "series": [{"name": "Year-one cost per seat", "values": [dt["Stack total"]["usd"], dt["SparkV Team"]["usd"]],
                                  "color": "bar", "point_colors": {1: "red"}}],
                      "number_format": c["number_format"],
                      "source": "Stack = " + " + ".join(f"{n} {sd.fmt_num(dt[n]['usd'], '$#,##0.00').replace('.00', '')}"
                                                        for n in stack)
                                + ". Monthly prices x 12. NotchNook and Alcove left out (one-time). Business plan §3.",
                  }, notes=s["notes"], footer="Third-party list prices, Oct 2026. Legal review required before external use.")

    # 14 pricing ---------------------------------------------------------------------
    s = S["pricing"]
    c = s["chart"]
    rows = {r[0]: r[1:] for r in s["table"]["rows"]}
    plans = [
        {"name": "Free", "price": "$0", "note": rows["For"][0],
         "features": [rows["Includes"][0], "1 Mac", rows["Try it"][0]]},
        {"name": "Pro", "price": "$39", "unit": "one-time", "inr": "₹1,499", "inr_aside": "launch $29",
         "note": rows["For"][1], "features": [rows["Includes"][1], "2 Macs per person", rows["Try it"][1]]},
        {"name": "Team", "price": "$8", "unit": "per seat / month", "inr": "₹499", "inr_aside": "billed yearly ($96)",
         "note": rows["For"][2], "features": [rows["Includes"][2], "2 Macs per seat", rows["Try it"][2]],
         "highlight": True, "tag": "Recommended"},
    ]
    d.pricing_chart(s["header"], plans, eyebrow="Pricing", lead=s["subtitle"], aside=s["body"][0], chart={
        "type": "column", "title": c["title"], "categories": c["categories"],
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "ink"}],
        "number_format": c["number_format"], "source": "List-price arithmetic ($96 or ₹5,988 per seat per year); not a forecast.",
    }, notes=s["notes"], footer="Source: SparkV Business Plan §6a. Pro: 12 months of updates, optional renewal $19/yr.")

    # 15 pilot -----------------------------------------------------------------------
    s = S["pilot"]
    nodes = [dict(st_, active=(i == 0)) for i, st_ in enumerate(s["steps"])]
    d.timeline_strip(s["header"], eyebrow="The pilot", lead=s["subtitle"], nodes=nodes, strip=s["body"],
                     notes=s["notes"], footer="Measurement method agreed on day 0: [TBD: time-log method, e.g. a short daily form].")

    # 16 CTA -------------------------------------------------------------------------
    s = S["cta"]
    steps = [re.sub(r"^\d\.\s*", "", b) for b in s["body"][:3]]
    contact = " · ".join(p.strip() for p in s["body"][3].split("|"))
    d.pilot_cta(s["header"], lead=s["subtitle"], steps=steps, contact=contact, image=img(s, "accent"),
                notes=s["notes"])

    # A1-A4 hidden backup slides (from the outline's chart data tables and sources) -----
    roi = S["roi"]["chart"]["data_table"]
    d.appendix_table("ROI model assumptions", columns=["Workflow", "Assumption", "Minutes per week"],
                     rows=[[r["workflow"], r["assumption"], str(r["minutes"])] for r in roi],
                     widths=[2.0, 7.0, 1.6], lead="Backup for slide 10. Assumptions, not measurements.",
                     notes="Backup for the ROI slide. " + S["roi"]["notes"], page="A1", hidden=True,
                     footer="Source: SparkV ROI model (enterprise blueprint, slide 9 assumptions table).")
    comp = S["competition"]["chart"]["data_table"]
    d.appendix_table("Year-one cost per seat, by tool", columns=["Item", "Basis", "USD"],
                     rows=[[r["item"], r["basis"], sd.fmt_num(r["usd"], "$#,##0.00")] for r in comp],
                     widths=[3.0, 5.6, 1.8], highlight_row=len(comp) - 1, lead="Backup for slide 14.",
                     notes="Backup for the consolidation slide. " + S["competition"]["notes"], page="A2", hidden=True,
                     footer="Source: " + src["bp_section3"]["title"] + ". " + src["bp_section3"]["note"] + ".")
    pr = S["pricing"]["chart"]["data_table"]
    mk = S["market"]["chart"]["data_table"]
    d.appendix_table("Team cost by seat count and Mac shipments", columns=["Item", "Basis", "Value"],
                     rows=[[f"{r['seats']} seats", "Annual Team list price", f"${r['usd_per_year']:,} · ₹{r['inr_per_year']:,}"] for r in pr]
                     + [[f"Macs {r['year']}", r["basis"], f"{r['mac_units_m']:.1f}M units · {r['share_pct']:.1f}% share"] for r in mk],
                     widths=[2.2, 5.4, 3.0], lead="Backup for slides 03 and 15.",
                     notes="Backup data for the pricing chart (list-price arithmetic, not a forecast) and the Mac shipments chart.",
                     page="A3", hidden=True, footer="Sources: SparkV Business Plan §6a; IDC preliminary, Jan 2026.")
    d.appendix_table("Sources", columns=["Source", "Note"],
                     rows=[[x["title"], x.get("note", "")] for x in o["sources"]],
                     widths=[5.0, 6.0], lead="Links are in the speaker notes.",
                     notes="Source links:\n" + "\n".join(f"{x['title']}: {x['url']}" for x in o["sources"]),
                     page="A4", hidden=True, footer="Verify every third-party figure on the linked page before external use.")
    return d


# =========================================================================== checks
def extra_checks(d: Deck) -> list:
    """No text box shrunk below its style size (split the slide instead)."""
    probs = []
    for s in d.slides:
        for e in s.els:
            if e.kind == "text" and e.props.get("scale", 1.0) < 0.999 and e.name != "metric value":
                probs.append({"slide": s.page, "severity": "error", "check": "shrunk", "element": e.name,
                              "message": f"text scaled to {e.props['scale']:.0%}; split the slide instead"})
    return probs


def verify_pptx(path: str, d: Deck) -> dict:
    prs = Presentation(path)
    slides = list(prs.slides)
    info = {"slides": len(slides), "hidden": [], "charts": [], "missing_notes": [], "pictures": 0, "tbd_slides": []}
    for i, sl in enumerate(slides, 1):
        page = d.slides[i - 1].page
        if sl._element.get("show") == "0":
            info["hidden"].append(page)
        if not (sl.has_notes_slide and sl.notes_slide.notes_text_frame.text.strip()):
            info["missing_notes"].append(page)
        txt = " ".join(sh.text_frame.text for sh in sl.shapes if sh.has_text_frame)
        if "[TBD" in txt:
            info["tbd_slides"].append(page)
        for sh in sl.shapes:
            if sh.has_chart:
                ch = sh.chart
                info["charts"].append({"slide": page, "type": str(ch.chart_type).split(" ")[0],
                                       "series": len(list(ch.plots[0].series)),
                                       "data_labels": ch.plots[0].has_data_labels})
            if sh.shape_type == 13:
                info["pictures"] += 1
    assert info["slides"] == len(d.slides), "slide count mismatch"
    assert not info["missing_notes"], f"slides without notes: {info['missing_notes']}"
    return info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome", action="store_true", help="also run the headless Chrome overflow check")
    ap.add_argument("--shots", help="write a PNG per slide into this folder (headless Chrome)")
    a = ap.parse_args()
    d = build()
    d.save(PPTX)
    probs = d.check_layout() + extra_checks(d)
    idx = d.html_preview(PREVIEW, problems=probs)
    if a.chrome:
        probs += chrome_check(idx)
    with open(REPORT, "w") as f:
        json.dump(probs, f, indent=1, ensure_ascii=False)
    if a.shots:
        os.makedirs(a.shots, exist_ok=True)
        for s in d.slides:
            chrome_screenshot(idx, s.index, os.path.join(a.shots, f"slide-{s.index:02d}-{s.page}.png"))
    info = verify_pptx(PPTX, d)
    errs = [p for p in probs if p.get("severity") == "error"]
    print(f"slides: {len(d.slides)}  pptx: {PPTX}\npreview: {idx}\nreopen: {json.dumps(info, ensure_ascii=False)}")
    print(f"problems: {len(errs)} errors, {len(probs) - len(errs)} warnings")
    for p in probs:
        print(" ", p)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
