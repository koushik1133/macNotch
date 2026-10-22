"""
build_technical.py - SparkV Technical Deck in the Apple-minimal style.

Reads   docs/decks/technical/outline.json   (copy, notes, chart data, screenshot names)
Writes  docs/decks/technical/SparkV-Technical-Deck.pptx
        docs/decks/technical/preview/index.html   (1600 x 900 frame per slide, same layout data)
        docs/decks/technical/layout-report.json

Run:    /opt/anaconda3/bin/python3 build_technical.py [--chrome] [--shots DIR]

Uses the shared library docs/decks/generator/sparkv_deck.py unchanged. Layouts the library does
not have (architecture diagram, band strip, range and log charts, pricing matrix, vertical
roadmap, top-edge CTA device) are built here from the library primitives, so the layout check
and the HTML preview cover them too.

Density rule for this deck: body copy is never below 14.4 pt (24 px). Slides whose outline
content does not fit at that size are split into two slides instead of shrinking type.
Captions, labels, chart labels, footers and the hidden backup tables use the STYLE.md sizes.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DECKS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(DECKS, "generator"))

import sparkv_deck as sd  # noqa: E402
from sparkv_deck import (BOTTOM, C, CONTENT_W, MARGIN, PX_PER_IN, SLIDE_H, SLIDE_W, TOP, TS, TYPE,  # noqa: E402
                         Deck, LayoutError, accent, chrome_check, chrome_screenshot, col, col_x, span)
from lxml import etree  # noqa: E402
from pptx import Presentation  # noqa: E402
from pptx.enum.chart import XL_LABEL_POSITION  # noqa: E402
from pptx.oxml.ns import qn  # noqa: E402
from pptx.util import Pt  # noqa: E402

OUT_PPTX = os.path.join(HERE, "SparkV-Technical-Deck.pptx")
OUT_HTML = os.path.join(HERE, "preview", "index.html")
OUT_REPORT = os.path.join(HERE, "layout-report.json")
FOOT = "SparkV · Technical briefing"
RENDER = "Real offscreen renders from current source, sample data."

# Deck-specific type (added to the shared TYPE table at run time; the library file is untouched).
TYPE.update({
    "tb": TS("regular", 14.4, 1.4, 0, "ink2", min_scale=1.0),        # body copy, 24 px
    "tb_ink": TS("regular", 14.4, 1.4, 0, "ink", min_scale=1.0),
    "tb_med": TS("medium", 14.4, 1.3, 0, "ink", min_scale=1.0),
    "node": TS("medium", 14.4, 1.2, 0, "ink", min_scale=1.0),        # diagram box name
    "node_d": TS("regular", 12.0, 1.35, 0, "ink2", min_scale=1.0),   # diagram box detail
    "status": TS("regular", 12.0, 1.35, 0, "ink2", min_scale=1.0),   # status line / band label
    "cell14": TS("regular", 13.2, 1.35, 0, "ink2", min_scale=1.0),
    "cell14_ink": TS("medium", 13.2, 1.35, 0, "ink", min_scale=1.0),
})
OK = "#248A3D"
SEV = {"Critical": "#E5484D", "High": "#F59E0B", "Medium": "#EAB308", "Low": "#3B82F6"}
G = 32 / PX_PER_IN  # grid gutter


def sentences(text: str) -> list:
    return re.split(r"(?<=[.!?])\s+(?=[A-Z'])", text.strip())


def notes_part(slide: dict, a: int, b: int = None) -> str:
    return " ".join(sentences(slide["notes"])[a:b])


class TechDeck(Deck):
    """Deck plus the technical-deck layouts. Everything goes through the library registry."""

    # ------------------------------------------------------------------ measuring
    def hgt(self, content, style: str, w: float) -> float:
        return self.measure(self._paras(content, style, "l", None, 0), w)[0] + 0.0005

    # ------------------------------------------------------------------ vertical stack
    def stack(self, s, x: float, w: float, parts: list, *, top: float = TOP, bottom: float = BOTTOM,
              valign: str = "m", where: str = "") -> float:
        """Place parts top to bottom. part: dict(kind=text|rule|status, content, style, gap, align, color).
        Raises LayoutError when the stack is taller than top..bottom (split the slide instead)."""
        hs = []
        for p in parts:
            if p["kind"] == "rule":
                hs.append(0.0)
            elif p["kind"] == "status":
                hs.append(self.hgt(p["content"], p.get("style", "status"), w - 0.22))
            else:
                hs.append(self.hgt(p["content"], p["style"], w))
        total = sum(hs) + sum(p.get("gap", 0.0) for p in parts)
        if total > bottom - top + 1e-6:
            raise LayoutError(f"slide {s.page} {where}: text stack {total:.2f} in > {bottom - top:.2f} in")
        y = top + {"t": 0.0, "m": (bottom - top - total) / 2, "b": bottom - top - total}[valign]
        for p, h in zip(parts, hs):
            y += p.get("gap", 0.0)
            if p["kind"] == "rule":
                self.line(s, x, y, x + w, y, color=p.get("color", "hairline"), name="list rule")
            elif p["kind"] == "status":
                ts = TYPE[p.get("style", "status")]
                d = 0.09
                self.rect(s, x, y + (ts.size * ts.lh / 72 - d) / 2, d, d, oval=True, fill="ink3", name="status dot")
                self.text(s, x + 0.22, y, w - 0.22, h, p["content"], p.get("style", "status"), name="status")
            else:
                self.text(s, x, y, w, h, p["content"], p["style"], align=p.get("align", "l"),
                          color=p.get("color"), name=p.get("name", p["style"]))
            y += h
        return y

    @staticmethod
    def head_parts(eyebrow, title, lead, h1="h1_side"):
        parts = []
        if eyebrow:
            parts.append(dict(kind="text", content=eyebrow, style="eyebrow", gap=0, name="eyebrow"))
        parts.append(dict(kind="text", content=title, style=h1, gap=(18 / PX_PER_IN if eyebrow else 0),
                          name="headline"))
        if lead:
            parts.append(dict(kind="text", content=lead, style="lead", gap=22 / PX_PER_IN, name="lead"))
        return parts

    @staticmethod
    def list_parts(items, style="tb", pad=0.1, gap=0.3):
        parts = [dict(kind="rule", gap=gap)]
        for it in items:
            parts.append(dict(kind="text", content=it, style=style, gap=pad, name="bullet"))
            parts.append(dict(kind="rule", gap=pad))
        return parts

    # ------------------------------------------------------------------ images
    def shot(self, s, image: str, x, y, w, h=None, *, crop=(0, 0, 0, 0), radius=0.08, align="c",
             valign="m", name="") -> sd.El:
        """Screenshot with rounded corners. h=None: height follows the (cropped) aspect ratio."""
        path = self.image_path(image)
        iw, ih = self.image_size(path)
        l, t, r, b = crop
        ar = iw * (1 - l - r) / (ih * (1 - t - b))
        if h is None:
            pw, ph = w, w / ar
            px, py = x, y
        else:
            pw = min(w, h * ar)
            ph = pw / ar
            px = x + {"l": 0, "c": (w - pw) / 2, "r": w - pw}[align]
            py = y + {"t": 0, "m": (h - ph) / 2, "b": h - ph}[valign]
        return self.picture(s, path, px, py, pw, ph, crop=crop, radius=radius, name=name or f"shot {image}")

    def shot_h(self, image: str, w: float, crop=(0, 0, 0, 0)) -> float:
        iw, ih = self.image_size(self.image_path(image))
        l, t, r, b = crop
        return w * ih * (1 - t - b) / (iw * (1 - l - r))

    # ------------------------------------------------------------------ arrows
    def arrow(self, s, x1, y1, x2, y2, *, color="ink3", width=1.25, parent=None, name="arrow") -> sd.El:
        el = self.line(s, x1, y1, x2, y2, color=color, width=width, parent=parent, name=name)
        conn = s.slide.shapes[-1]
        ln = conn.line._get_or_add_ln()
        te = etree.SubElement(ln, qn("a:tailEnd"))
        te.set("type", "triangle")
        te.set("w", "med")
        te.set("len", "med")
        el.props["arrow"] = True
        return el

    def _html_el(self, e, weights, img_url):
        if e.kind == "line" and e.props.get("arrow"):
            x1, y1, x2, y2 = (sd._px(v) for v in e.props["pts"])
            lw = e.props["width"] / sd.PT_PER_PX
            c = e.props["color"]
            mid = f"ah{e.eid}"
            return (f"<svg class='ln' style='left:0;top:0' width='1600' height='900'><defs><marker id='{mid}' "
                    f"viewBox='0 0 10 10' refX='9' refY='5' markerWidth='4.5' markerHeight='4.5' "
                    f"markerUnits='strokeWidth' orient='auto'><path d='M0,0 L10,5 L0,10 z' fill='{c}'/></marker></defs>"
                    f"<line x1='{x1}' y1='{y1}' x2='{x2}' y2='{y2}' stroke='{c}' stroke-width='{lw:.2f}' "
                    f"marker-end='url(#{mid})'/></svg>")
        return super()._html_el(e, weights, img_url)

    # ------------------------------------------------------------------ chart extras
    def _native_chart(self, s, x, y, w, h, sp, font_name, parent):
        """Library chart, then: log10 value axis, custom per-point labels, range bars
        (series 0 = high in colour, series 1 = low drawn in the card colour on top, overlap 100)."""
        el = super()._native_chart(s, x, y, w, h, sp, font_name, parent)
        gf = [sh for sh in s.slide.shapes if getattr(sh, "has_chart", False)][-1]
        ch = gf.chart
        plot = ch.plots[0]
        if sp.get("log"):
            scaling = ch.value_axis._element.find(qn("c:scaling"))
            lb = etree.Element(qn("c:logBase"))
            lb.set("val", "10")
            scaling.insert(0, lb)
        if sp.get("range"):
            plot.overlap = 100
            plot.gap_width = 90
            mask = plot.series[1]
            mask.format.line.fill.background()
            ser_el = mask._element
            old = ser_el.find(qn("c:dLbls"))
            if old is not None:
                ser_el.remove(old)
            d = etree.Element(qn("c:dLbls"))
            etree.SubElement(d, qn("c:delete")).set("val", "1")
            ser_el.find(qn("c:cat")).addprevious(d)
        for si, labels in (sp.get("labels") or {}).items():
            ser = plot.series[int(si)]
            vals = sp["series"][int(si)]["values"]
            for i, lab in enumerate(labels):
                if lab is None or vals[i] is None:
                    continue
                dl = ser.points[i].data_label
                tf = dl.text_frame
                tf.text = lab
                f = tf.paragraphs[0].runs[0].font
                f.size = Pt(9)
                f.name = self.fp["medium"][0]
                f.color.rgb = sd._rgb("ink")
                dl.position = XL_LABEL_POSITION.OUTSIDE_END
        return el

    def _chart_svg(self, sp, W, H):
        if not (sp.get("log") or sp.get("range") or sp.get("labels")) or not sp["type"].startswith("bar"):
            return super()._chart_svg(sp, W, H)
        fs = 9 / sd.PT_PER_PX
        ink, ink2, ink3, hair = col("ink"), col("ink2"), col("ink3"), col("hairline")
        wmed = self.fp["medium"][3]
        cats, series = sp["categories"], sp["series"]
        labels = sp.get("labels") or {}
        lo, hi = sp["axis_min"], sp["axis_max"]
        out = [f"<svg width='{W}' height='{H}' viewBox='0 0 {W} {H}' font-size='{fs:.1f}'>"]

        def txt(x, y, s_, anchor="start", color=ink2, weight=400, italic=False):
            return (f"<text x='{x:.1f}' y='{y:.1f}' text-anchor='{anchor}' fill='{color}' font-weight='{weight}'"
                    f"{' font-style=\"italic\"' if italic else ''}>{sd._html.escape(str(s_))}</text>")

        lab_w = min(W * 0.4, max(self.m.width(str(c), "regular", False, 9) / sd.PT_PER_PX for c in cats) + 12)
        px0, px1 = lab_w + 6, W - 120
        py0, py1 = 4, H - 4
        slot = (py1 - py0) / len(cats)
        if sp.get("log"):
            a, b = math.log10(lo), math.log10(hi)
            scale = lambda v: px0 + (math.log10(max(v, lo)) - a) / (b - a) * (px1 - px0)  # noqa: E731
        else:
            scale = lambda v: px0 + (v - lo) / (hi - lo) * (px1 - px0)  # noqa: E731
        out.append(f"<line x1='{px0:.1f}' y1='{py0}' x2='{px0:.1f}' y2='{py1}' stroke='{hair}' stroke-width='1.25'/>")
        bh = slot / 1.9
        for ci, c in enumerate(cats):
            y0 = py0 + ci * slot
            by = y0 + (slot - bh) / 2
            out.append(txt(lab_w, y0 + slot / 2 + fs * 0.35, c, "end"))
            s0 = series[0]
            v = s0["values"][ci]
            lab = (labels.get(0) or labels.get("0") or [None] * len(cats))[ci]
            if v is None:
                if lab:
                    out.append(txt(px0 + 8, y0 + slot / 2 + fs * 0.35, lab, "start", ink3, 400, True))
                continue
            clr = s0["point_colors"].get(ci, s0["color"])
            xa = scale(series[1]["values"][ci]) if sp.get("range") else scale(lo)
            xb = scale(v)
            out.append(f"<rect x='{xa:.1f}' y='{by:.1f}' width='{max(0.0, xb - xa):.1f}' height='{bh:.1f}' fill='{clr}'/>")
            out.append(txt(xb + 6, by + bh / 2 + fs * 0.35, lab or sd.fmt_num(v, sp["number_format"]), "start", ink, wmed))
        out.append("</svg>")
        return "".join(out)

    # ------------------------------------------------------------------ tiles
    def tiles(self, s, items, x0, top, w_total, bottom, cols, *, value_style="kpi", gap=24 / PX_PER_IN,
              row_gap=24 / PX_PER_IN, max_h=2.3):
        """Mist cards: value (one size for all) and a 14.4 pt label. items: dict(value, label, accent)."""
        n = len(items)
        rows = math.ceil(n / cols)
        cw = (w_total - (cols - 1) * gap) / cols
        ch = min(max_h, (bottom - top - (rows - 1) * row_gap) / rows)
        padx, pady = 32 / PX_PER_IN, 26 / PX_PER_IN
        for i, m in enumerate(items):
            r, c = divmod(i, cols)
            x, y = x0 + c * (cw + gap), top + r * (ch + row_gap)
            card = self.card(s, x, y, cw, ch, name="tile")
            iw = cw - 2 * padx
            vp = self.P(m["value"], value_style, color="red" if m.get("accent") else None,
                        weight="medium" if m.get("accent") else None)
            vh = self.measure([vp], iw)[0] + 0.0005
            lh = self.hgt(m["label"], "tb", iw) if m.get("label") else 0
            if pady + vh + 0.1 + lh + pady > ch + 1e-6:
                raise LayoutError(f"slide {s.page}: tile {m['value']!r} needs {pady * 2 + vh + 0.1 + lh:.2f} in, has {ch:.2f}")
            self.text(s, x + padx, y + pady, iw, vh, [vp], value_style, parent=card, name="tile value")
            if m.get("label"):
                self.text(s, x + padx, y + pady + vh + 0.1, iw, lh, m["label"], "tb", parent=card, name="tile label")
        return top + rows * ch + (rows - 1) * row_gap

    # ------------------------------------------------------------------ slide shells
    def header_block(self, s, eyebrow, title, lead, *, h1="h1", title_lines=2, x=MARGIN, w=CONTENT_W, align="l"):
        return self._header(s, eyebrow, title, lead, x=x, w=w, align=align, h1=h1, title_lines=title_lines,
                            lead_lines=2)

    def showcase(self, *, title, eyebrow=None, lead=None, bullets=(), status=None, notes="", footer=FOOT,
                 visual=None, text_left=True, bg="mist", layout="feature_showcase", tcols=5, valign="m"):
        """Text on 5 columns (left or right), visual(s, x, w) on the other 6.3 in."""
        s = self._new(layout, bg, notes, footer, None, False)
        tw = span(tcols)
        if text_left:
            tx, vx = col_x(1), col_x(tcols + 1) + 0.2
        else:
            tx, vx = col_x(13 - tcols), MARGIN
        vw = CONTENT_W - tw - 0.2 - G
        parts = self.head_parts(eyebrow, title, lead)
        if bullets:
            parts += self.list_parts(bullets)
        if status:
            parts.append(dict(kind="status", content=status, gap=0.28))
        self.stack(s, tx, tw, parts, valign=valign, where="text column")
        if visual:
            visual(s, vx, vw)
        return s


# =============================================================================== build
def build() -> TechDeck:
    o = sd.load_outline("technical")
    S = {sl["number"]: sl for sl in o["slides"]}
    d = TechDeck("SparkV Technical Deck", footer_default=FOOT)

    # ---------------------------------------------------------------- 1 Title
    sl = S[1]
    s = d._new("title_slide", "mist", sl["notes"], False, None, False)
    y = TOP
    e = d.text(s, MARGIN, y, CONTENT_W, None, sl["body"][1], "eyebrow", align="c", color="red", name="eyebrow")
    y = e.b + 18 / PX_PER_IN
    t = d.text(s, MARGIN, y, CONTENT_W, None, sl["header"], "display", align="c", name="headline")
    l_ = d.text(s, MARGIN, t.b + 22 / PX_PER_IN, CONTENT_W, None, sl["subtitle"], "lead", align="c", name="lead")
    st = d.text(s, MARGIN, l_.b + 10 / PX_PER_IN, CONTENT_W, None, sl["body"][0], "tb", align="c", name="stack")
    bw = d.button_width(sl["body"][2])
    b = d.button(s, (SLIDE_W - bw) / 2, st.b + 0.22, sl["body"][2], name="url pill")
    d.macbook(s, (SLIDE_W - 9.167) / 2, max(3.767, b.b + 0.35), 9.167, sl["images"][0]["file"], pad_px=16,
              clip_bottom=SLIDE_H, name="hero device")

    # ---------------------------------------------------------------- 2 Codebase (tiles, then chart)
    sl = S[2]
    s = d._new("metrics_dashboard", "white", notes_part(sl, 0, 2), sl["footnote"], None, False)
    y = d.header_block(s, "Codebase", sl["header"], sl["subtitle"], h1="h1_dash")
    d.tiles(s, sl["tiles"], MARGIN, y + 0.35, CONTENT_W, BOTTOM, 3)

    c = sl["chart"]
    hl = set(c["highlight"])
    s = d._new("chart_slide", "white", notes_part(sl, 2) + " The three highlighted modules (UIAudit, BrowserRecorder, "
               "FlowCanvas) are the developer agents shown later in the deck.",
               "Red: UIAudit, BrowserRecorder and FlowCanvas, the developer agents in this deck. " + sl["footnote"],
               None, False)
    y = d.header_block(s, "Codebase", c["title"], sl["subtitle"], h1="h1_dash")
    d.chart_card(s, MARGIN, y + 0.3, CONTENT_W, BOTTOM - y - 0.3, {
        "type": "bar", "categories": c["categories"], "number_format": "#,##0",
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "bar",
                    "point_colors": {i: "red" for i, k in enumerate(c["categories"]) if k in hl}}],
        "source": c["source"]})

    # ---------------------------------------------------------------- 3 Architecture (showcase, then diagram)
    sl = S[3]

    def hub(s, x, w):
        lid = w / (7.467 / 6.833)          # the base slab is 9% wider than the lid
        h = d.macbook_height(lid)
        d.macbook(s, x + (w - lid) / 2, TOP + (BOTTOM - TOP - h) / 2, lid, sl["images"][0]["file"], name="device")

    d.showcase(title=sl["header"], eyebrow="Architecture", lead=sl["subtitle"], bullets=sl["body"],
               notes=notes_part(sl, 0, 3), footer=RENDER, visual=hub)

    s = d._new("diagram", "mist", notes_part(sl, 3), "Object graph from NotchPanel.swift and NotchWindowController.swift. "
               "Red outline: the panel every feature lives in.", None, False)
    y = d.header_block(s, None, sl["header"], None, h1="h1_dash", title_lines=1)
    nodes = {n["id"]: n for n in sl["diagram"]["nodes"]}
    top, bot = y + 0.35, BOTTOM
    pad = 0.1

    def box_h(n, w):
        return pad + d.hgt(n["label"], "node", w - 2 * pad) + 0.05 + d.hgt(n["detail"], "node_d", w - 2 * pad) + pad

    def box(n, x, yy, w, hh, *, red=False):
        r = d.rect(s, x, yy, w, hh, fill="white", line="red" if red else "hairline", line_w=1.2 if red else 0.75,
                   radius=0.1, name=f"node {n['id']}")
        lh = d.hgt(n["label"], "node", w - 2 * pad)
        d.text(s, x + pad, yy + pad, w - 2 * pad, lh, n["label"], "node", parent=r, name="node label")
        d.text(s, x + pad, yy + pad + lh + 0.05, w - 2 * pad, d.hgt(n["detail"], "node_d", w - 2 * pad),
               n["detail"], "node_d", parent=r, name="node detail")
        return r

    def column(ids, x, w, indent=None):
        hs = [box_h(nodes[i], w - (indent or {}).get(i, 0)) for i in ids]
        gap = min(0.4, (bot - top - sum(hs)) / (len(ids) - 1))
        if gap < 0.14:
            raise LayoutError(f"diagram column {ids}: gap {gap:.2f} in")
        out, yy = {}, top
        for i, hh in zip(ids, hs):
            ind = (indent or {}).get(i, 0)
            out[i] = box(nodes[i], x + ind, yy, w - ind, hh, red=nodes[i].get("accent", False))
            yy += hh + gap
        return out

    left = column(["panel", "host", "layout", "hub"], col_x(1), span(5))
    for a, b_ in (("panel", "host"), ("host", "layout"), ("layout", "hub")):
        xa = left[a].x + 0.45
        d.arrow(s, xa, left[a].b + 0.03, xa, left[b_].y - 0.03)
    rx, rw = col_x(7), span(6)
    ind = {"ac": 0.5, "core": 0.5, "labs": 0.5, "contract": 1.0}
    right = column(["wc", "ac", "core", "labs", "contract"], rx, rw, ind)
    bus_x = rx + 0.27
    mid = lambda el: el.y + min(0.3, el.h / 2)  # noqa: E731
    d.line(s, bus_x, right["wc"].b, bus_x, mid(right["labs"]), color="ink3", width=1.25, name="bus")
    for k in ("ac", "core", "labs"):
        d.arrow(s, bus_x, mid(right[k]), right[k].x - 0.03, mid(right[k]))
    cx_ = right["labs"].x + 0.27
    d.arrow(s, cx_, right["labs"].b + 0.03, cx_, right["contract"].y - 0.03)
    ay = top + 0.3
    d.arrow(s, right["wc"].x - 0.03, ay, left["panel"].r + 0.03, ay)

    # ---------------------------------------------------------------- 4 Live activities
    sl = S[4]
    imgs = sl["images"]

    def wings_device(s, x, w):
        lid = w / (7.467 / 6.833)
        h = d.macbook_height(lid)
        d.macbook(s, x + (w - lid) / 2, TOP + (BOTTOM - TOP - h) / 2, lid, imgs[0]["file"], name="device")

    d.showcase(title=sl["header"], eyebrow="Live activities", lead=sl["subtitle"], bullets=sl["body"],
               status=sl["status"], notes=notes_part(sl, 0, 5), footer=RENDER + " Shown: compact wings.",
               visual=wings_device, tcols=6)

    # band states: 2 x 3 grid, band width solved from the free height
    s = d._new("band_grid", "mist", notes_part(sl, 5), RENDER + " Bands cropped to the island.", None, False)
    y = d.header_block(s, "Live activities · band states", sl["header"], None, h1="h1_dash", title_lines=1)
    crop = (0.15, 0, 0.15, 0)
    gap_x, gap_y = 0.4, 0.3
    lab_h = d.hgt("x", "status", 3.0)
    rows = [imgs[i:i + 2] for i in range(0, len(imgs), 2)]
    top = y + 0.35
    free = BOTTOM - top - (len(rows) - 1) * gap_y - len(rows) * (0.1 + lab_h)
    unit = sum(max(d.shot_h(im["file"], 1.0, crop) for im in r) for r in rows)   # height per inch of width
    cw = min((CONTENT_W - gap_x) / 2, free / unit)
    x0 = MARGIN + (CONTENT_W - (2 * cw + gap_x)) / 2
    yy = top
    for r in rows:
        h = max(d.shot_h(im["file"], cw, crop) for im in r)
        for j, im in enumerate(r):
            xx = x0 + j * (cw + gap_x)
            d.shot(s, im["file"], xx, yy, cw, h, crop=crop, valign="t", name=f"band {im['file']}")
            lab = im["note"].split("label:", 1)[1].strip()
            d.text(s, xx, yy + h + 0.1, cw, lab_h, f"**{lab}**" if im is imgs[0] else lab, "status",
                   name="band label")
        yy += h + 0.1 + lab_h + gap_y

    # ---------------------------------------------------------------- 5 AI stack (tiles, then chart)
    sl = S[5]
    s = d._new("metrics_dashboard", "white", notes_part(sl, 1), FOOT, None, False)
    y = d.header_block(s, "On-device AI", sl["header"], sl["subtitle"], h1="h1_dash")
    d.tiles(s, sl["tiles"], MARGIN, y + 0.35, CONTENT_W, BOTTOM, 3, value_style="tile")

    c = sl["chart"]
    hl = set(c["highlight"])
    pc = {i: ("red" if k == "FoundationModels" else "ink") for i, k in enumerate(c["categories"]) if k in hl}
    s = d._new("chart_slide", "white", notes_part(sl, 0, 1),
               "Red: FoundationModels. Ink: the other on-device AI frameworks. Grey: system frameworks.", None, False)
    y = d.header_block(s, "On-device AI", c["title"], sl["subtitle"], h1="h1_dash")
    d.chart_card(s, MARGIN, y + 0.3, CONTENT_W, BOTTOM - y - 0.3, {
        "type": "bar", "categories": c["categories"], "number_format": "0",
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "bar",
                    "point_colors": pc}], "source": c["source"]})

    # ---------------------------------------------------------------- 6 AI in the loop (dictation + meetings, then translation)
    sl = S[6]
    im = {i["file"]: i for i in sl["images"]}

    def loop_a(s, x, w):
        crop = (0.15, 0, 0.15, 0)
        bh = d.shot_h("50-dictation.png", w, crop)
        gap = 0.3
        wh = BOTTOM - TOP - bh - gap
        ww = min(w, wh * 1960 / 1320)
        wh = d.shot_h("37-meeting-live-answers.png", ww)
        total = bh + gap + wh
        y0 = TOP + (BOTTOM - TOP - total) / 2
        d.shot(s, "50-dictation.png", x, y0, w, bh, crop=crop, name="dictation band")
        d.shot(s, "37-meeting-live-answers.png", x + (w - ww) / 2, y0 + bh + gap, ww, wh, name="meeting window")

    d.showcase(title=sl["header"], eyebrow="Dictation · Meetings", lead=sl["subtitle"], bullets=sl["body"][:2],
               status=sl["status"], notes=notes_part(sl, 0, 3), footer=RENDER, visual=loop_a)

    c = sl["chart"]
    lowv, highv = c["series"][0]["values"], c["series"][1]["values"]

    def loop_b(s, x, w):
        ih = d.shot_h("38-live-translation.png", w)
        gap = 0.3
        d.shot(s, "38-live-translation.png", x, TOP, w, ih, name="translation panel")
        d.chart_card(s, x, TOP + ih + gap, w, BOTTOM - TOP - ih - gap, {
            "type": "bar", "title": c["title"], "categories": c["categories"], "number_format": "0.0#",
            "axis_max": 3.0, "legend": False, "range": True,
            "series": [{"name": "High (s)", "values": highv, "color": "bar", "point_colors": {1: "red"}},
                       {"name": "Low (s)", "values": lowv, "color": "mist"}],
            "labels": {0: [f"{lo:g}–{hi:g} s" for lo, hi in zip(lowv, highv)]},
            "source": c["source"]}, name="latency card")

    d.showcase(title=sl["header"], eyebrow="Live Translation", lead=None, bullets=sl["body"][2:],
               notes=notes_part(sl, 3), footer=RENDER + " Bars span the measured low–high range.", visual=loop_b,
               bg="white", valign="t")

    # ---------------------------------------------------------------- 7 Privacy
    sl = S[7]
    s = d._new("minimal_body", "white", sl["notes"], RENDER, None, False)
    tw = span(8)
    parts = d.head_parts(None, sl["header"], sl["subtitle"], h1="h1_large") + d.list_parts(sl["body"], gap=0.42)
    d.stack(s, col_x(1), tw, parts, where="privacy")
    d.shot(s, sl["images"][0]["file"], col_x(9) + 0.25, TOP, span(4) - 0.25, BOTTOM - TOP, name="permissions window")

    # ---------------------------------------------------------------- 8 UI Audit (showcase, then results)
    sl = S[8]
    bullets = [b.replace("P copies", "**P** copies", 1) for b in sl["body"]]

    def audit(s, x, w):
        crop = (0, 0, 0, 0)
        bw_ = 4.2
        bh = d.shot_h("21-ui-audit.png", bw_, crop)
        gap = 0.25
        wh = d.shot_h("22-ui-audit-window.png", w)
        total = bh + gap + wh
        y0 = TOP + (BOTTOM - TOP - total) / 2
        d.shot(s, "21-ui-audit.png", x, y0, bw_, bh, crop=crop, name="notch band")
        d.text(s, x + bw_ + 0.25, y0 + bh - d.hgt("x", "status", w - bw_ - 0.25), w - bw_ - 0.25,
               d.hgt("x", "status", w - bw_ - 0.25), "Started from the notch", "status", name="band caption")
        d.shot(s, "22-ui-audit-window.png", x, y0 + bh + gap, w, wh, name="audit window")

    d.showcase(title=sl["header"], eyebrow="Developer agent · UI Audit", lead=sl["subtitle"], bullets=bullets,
               notes=notes_part(sl, 0, 5) + " " + notes_part(sl, 7), footer=RENDER, visual=audit)

    c = sl["chart"]
    s = d._new("metrics_dashboard", "white", notes_part(sl, 5, 7),
               "Planted-issue test site on 127.0.0.1. Severity colours are the app's own.", None, False)
    y = d.header_block(s, "Developer agent · UI Audit", c["title"], None, h1="h1_dash")
    strip = []
    for m in sl["metric_strip"]:
        if m.startswith("self-test"):
            strip.append({"value": m.split(" ", 1)[1], "label": "self-test"})
        else:
            v, lab = m.split(" ", 1)
            strip.append({"value": v, "label": lab})
    tb = d.tiles(s, strip, MARGIN, y + 0.3, CONTENT_W, BOTTOM, 4, value_style="tile", max_h=1.35)
    d.chart_card(s, MARGIN, tb + 0.3, CONTENT_W, BOTTOM - tb - 0.3, {
        "type": "column", "categories": c["categories"], "number_format": "0",
        "series": [{"name": "Findings", "values": c["series"][0]["values"], "color": "bar",
                    "point_colors": {i: SEV[k] for i, k in enumerate(c["categories"])}}],
        "source": c["source"]})

    # ---------------------------------------------------------------- 9 Browser Flows (mirrored)
    sl = S[9]

    def flows(s, x, w):
        crop = (0, 0, 0, 0)
        bw_ = 4.2
        bh = d.shot_h("25-browser-flows.png", bw_, crop)
        gap = 0.25
        wh = d.shot_h("26-browser-flows-window.png", w)
        total = bh + gap + wh
        y0 = TOP + (BOTTOM - TOP - total) / 2
        d.shot(s, "25-browser-flows.png", x, y0, bw_, bh, crop=crop, name="notch band")
        d.shot(s, "26-browser-flows-window.png", x, y0 + bh + gap, w, wh, name="flows window")

    d.showcase(title=sl["header"], eyebrow="Developer agent · Browser Flows", lead=sl["subtitle"],
               bullets=[b.replace("{{password}}", "**{{password}}**") for b in sl["body"]], status=sl["status"],
               notes=sl["notes"], footer=RENDER, visual=flows, text_left=False, tcols=6)

    # ---------------------------------------------------------------- 10 Flow Canvas
    sl = S[10]

    def canvas(s, x, w):
        d.shot(s, sl["images"][0]["file"], x, TOP, w, BOTTOM - TOP, name="canvas window")

    d.showcase(title=sl["header"], eyebrow="Developer agent · Flow Canvas", lead=sl["subtitle"], bullets=sl["body"],
               notes=sl["notes"], footer=RENDER, visual=canvas, tcols=6)

    # ---------------------------------------------------------------- 11 Engineering (tiles, then harness chart)
    sl = S[11]
    s = d._new("metrics_dashboard", "white", notes_part(sl, 0, 4), "Build details: build.sh and NotchIsland.entitlements.",
               None, False)
    y = d.header_block(s, "Engineering", sl["header"], sl["subtitle"], h1="h1_dash")
    d.tiles(s, sl["tiles"], MARGIN, y + 0.35, CONTENT_W, BOTTOM, 3, value_style="tile")

    c = sl["chart"]
    s = d._new("chart_slide", "white", notes_part(sl, 4), FOOT, None, False)
    y = d.header_block(s, "Engineering", c["title"], sl["subtitle"], h1="h1_dash")
    top = y + 0.3
    labels = list(c["value_labels"])
    d.chart_card(s, MARGIN, top, span(8), BOTTOM - top, {
        "type": "bar", "categories": c["categories"], "number_format": "#,##0", "log": True,
        "axis_min": 1, "axis_max": 100000, "legend": False,
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "ink"}],  # STYLE.md palette: ink bars, not status green
        "labels": {0: labels}, "source": c["source"]})
    nc = c["categories"][c["series"][0]["values"].index(None)]
    d.stack(s, col_x(9), span(4), [
        dict(kind="rule", gap=0),
        dict(kind="text", content="**Log scale.** " + sentences(sl["notes"])[5].replace(
            "The log scale is there because the", "The"), style="tb", gap=0.15),
        dict(kind="rule", gap=0.2),
        dict(kind="text", content=f"**{nc}:** not clean, so no bar is drawn.", style="tb", gap=0.15),
    ], top=top, valign="t", where="side notes")

    # ---------------------------------------------------------------- 12 Distribution
    sl = S[12]
    s = d._new("two_column_comparison", "mist", sl["notes"], "Sandbox constraints: Business Plan §5.", None, False)
    y = d.header_block(s, "Distribution", sl["header"], sl["subtitle"], h1="h1", title_lines=1)
    top = y + 0.45
    for ci, colspec in enumerate(sl["columns"]):
        x, w = (col_x(1), span(6)) if ci == 0 else (col_x(7), span(6))
        lh = TYPE["label"].size * TYPE["label"].lh / 72 + 0.0005
        d.text(s, x, top, w, lh, colspec["title"], "label", color="ink" if ci else None, name="column head")
        yy = top + lh + 0.12
        d.line(s, x, yy, x + w, yy, color="ink", name="column head rule")
        key_w = 0.5
        for k, item in enumerate(colspec["items"]):
            th = d.hgt(item, "tb", w - key_w)
            rh = th + 0.24
            if ci == 0:
                d.mark(s, "cross", x + 0.04, yy + 0.12 + (TYPE["tb"].size * 1.4 / 72 - 0.13) / 2, 0.13, color="ink3",
                       name="cross")
            else:
                d.text(s, x, yy + 0.12, key_w - 0.05, d.hgt(f"{k + 1:02d}", "tb_med", key_w - 0.05), f"{k + 1:02d}",
                       "tb_med", name="step number")
            d.text(s, x + key_w, yy + 0.12, w - key_w, th, item, "tb", name="item")
            yy += rh
            d.line(s, x, yy, x + w, yy, name="row rule")
        if yy > BOTTOM + 1e-6:
            raise LayoutError("slide 12 columns overflow")

    # ---------------------------------------------------------------- 13 Pricing (matrix, then net per sale)
    sl = S[13]
    t = sl["table"]
    s = d._new("pricing_table", "mist", notes_part(sl, 0, 5),
               f"Source: {t['source']}. {sl['footnote'].replace('Business Plan', 'Business Plan')}", None, False)
    y = d.header_block(s, None, sl["header"], sl["subtitle"], h1="h1", title_lines=1)
    pricing_matrix(d, s, t, y + 0.3)

    c = sl["chart"]
    s = d._new("chart_slide", "white", notes_part(sl, 5),
               "Revenue scenario stays a placeholder until there are sales.", None, False)
    y = d.header_block(s, "Pricing", c["title"], sl["subtitle"], h1="h1_dash")
    top = y + 0.3
    d.chart_card(s, MARGIN, top, span(7), BOTTOM - top, {
        "type": "bar", "categories": c["categories"], "number_format": "$#,##0.00",
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "bar"},
                   {"name": c["series"][1]["name"], "values": c["series"][1]["values"], "color": "ink",
                    "point_colors": {c["categories"].index("Pro"): "red"}}],
        "source": c["source"]}, name="net card")
    rs = sl["revenue_scenario"]
    x, w = col_x(8), span(5)
    card = d.card(s, x, top, w, BOTTOM - top, fill="white", line="hairline", name="scenario card")
    ix, iw = x + 0.27, w - 0.54
    yy = top + 0.25
    lh = TYPE["label"].size * TYPE["label"].lh / 72 + 0.0005
    d.text(s, ix, yy, iw, lh, "Year-one revenue scenario", "label", parent=card, name="scenario head")
    yy += lh + 0.15
    fh = d.hgt(rs["formula"], "tb_ink", iw)
    d.text(s, ix, yy, iw, fh, rs["formula"], "tb_ink", parent=card, name="formula")
    yy += fh + 0.2
    for lab, val in (("Pro units", rs["pro_units"]), ("Team seats", rs["team_seats"]),
                     ("Year-one revenue", rs["year_one_revenue"])):
        d.line(s, ix, yy, ix + iw, yy, parent=card, name="scenario rule")
        rh = d.hgt(lab, "tb", iw / 2)
        d.text(s, ix, yy + 0.12, iw * 0.6, rh, lab, "tb", parent=card, name="scenario label")
        d.text(s, ix + iw * 0.6, yy + 0.12, iw * 0.4, rh, val, "tb", align="r", parent=card, name="scenario value")
        yy += rh + 0.24
    d.line(s, ix, yy, ix + iw, yy, parent=card, name="scenario rule")
    note = "Do not draw this chart with invented values: it stays a table until real sales exist."
    nh = d.hgt(note, "status", iw)
    d.text(s, ix, top + (BOTTOM - top) - 0.25 - nh, iw, nh, note, "status", parent=card, name="scenario note")

    # ---------------------------------------------------------------- 14 Market (stack cost, then installed base)
    sl = S[14]
    c = sl["chart"]
    s = d._new("comparison", "white", notes_part(sl, 0, 3), c["footnote"], None, False)
    y = d.header_block(s, "Value", sl["header"], sl["subtitle"], h1="h1", title_lines=1)
    top = y + 0.35
    d.chart_card(s, MARGIN, top, span(8), BOTTOM - top, {
        "type": "bar", "title": c["title"], "categories": c["categories"], "number_format": "$#,##0.00",
        "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"], "color": "bar",
                    "point_colors": {c["categories"].index("SparkV Pro"): "red"}}],
        "source": c["source"]})
    stack_total = f"${c['stack_total']:,.2f}"
    d.tiles(s, [{"value": stack_total, "label": "Comparable-tool stack, year one"},
                {"value": "$39", "label": "SparkV Pro, one-time", "accent": True}],
            col_x(9), top, span(4), BOTTOM, 1, value_style="kpi")

    c2 = sl["chart_2"]
    s = d._new("metrics_dashboard", "white", notes_part(sl, 3), "Apple has not published a Mac-only active base since 2018.",
               None, False)
    y = d.header_block(s, "Platform", sl["columns"][1]["title"], None, h1="h1_dash")
    top = y + 0.3
    d.chart_card(s, col_x(1), top, span(7), BOTTOM - top, {
        "type": "column", "title": c2["title"], "categories": c2["categories"], "number_format": '0.00"B"',
        "series": [{"name": c2["series"][0]["name"], "values": c2["series"][0]["values"], "color": "bar",
                    "point_colors": {2: "ink"}}], "source": c2["source"]})
    lh = TYPE["label"].size * TYPE["label"].lh / 72 + 0.0005
    parts = [dict(kind="text", content="Mac-specific figures", style="label", gap=0, name="list head"),
             dict(kind="rule", gap=0.12, color="ink")]
    for line_ in sl["columns"][1]["stat_lines"]:
        k, v = line_.split(": ", 1)
        parts.append(dict(kind="text", content=f"**{k}**\n{v}", style="tb", gap=0.14, name="stat line"))
        parts.append(dict(kind="rule", gap=0.14))
    d.stack(s, col_x(8) + 0.2, span(5) - 0.2, parts, top=top, valign="t", where="stat lines")

    # ---------------------------------------------------------------- 15 Roadmap (30 days, then after 1.0)
    sl = S[15]
    tl = sl["timeline"]
    s = d._new("timeline", "white", notes_part(sl, 0, 3), FOOT,
               None, False)
    y = d.header_block(s, None, sl["header"], sl["subtitle"], h1="h1", title_lines=1)
    st_h = d.hgt("x", "tb", CONTENT_W)
    d.text(s, MARGIN, y + 0.12, CONTENT_W, st_h, "Day 1 = " + tl["start"], "tb", name="start date")
    roadmap(d, s, tl["milestones"], y + 0.12 + st_h + 0.3)

    s = d._new("minimal_body", "white", notes_part(sl, 3), FOOT, None, False)
    y = d.header_block(s, "Roadmap", "After 1.0", None, h1="h1_large", title_lines=1)
    numbered_list(d, s, col_x(1), span(9), y + 0.5, tl["after_launch"])

    # ---------------------------------------------------------------- 16 CTA
    sl = S[16]
    s = d._new("quote_or_cta", "mist", sl["notes"], False, None, False)
    dev_b = top_device(d, s, sl["images"][0]["file"], 7.2)
    yy = d.stack(s, MARGIN, CONTENT_W, [
        dict(kind="text", content=sl["header"], style="h1_large", gap=0, align="c", name="headline"),
        dict(kind="text", content=sl["subtitle"], style="lead", gap=22 / PX_PER_IN, align="c", name="lead"),
        dict(kind="text", content=sl["body"][0], style="tb_ink", gap=0.35, align="c", name="cta line"),
        dict(kind="text", content=sl["body"][1], style="tb", gap=0.08, align="c", name="cta line"),
    ], top=dev_b + 0.45, bottom=BOTTOM - 0.85, valign="m", where="cta")
    url, rest = sl["body"][2].split(" · ", 1)
    bw = d.button_width(url)
    cw_ = d.text_width(rest, "tb") + 0.05
    x0 = (SLIDE_W - (bw + 0.25 + cw_)) / 2
    b = d.button(s, x0, yy + 0.35, url, name="url pill")
    th = d.hgt(rest, "tb", cw_)
    d.text(s, x0 + bw + 0.25, b.y + (b.h - th) / 2, cw_, th, rest, "tb", name="contact")

    # ---------------------------------------------------------------- hidden backups (data behind the charts)
    sl = S[14]
    rows = [[r["product"], r["category"], f"${r['cost']:,.2f}", r["basis"],
             re.sub(r"^https?://(www\.)?", "", r["source"]).split("/")[0] if r["source"].startswith("http") else r["source"]]
            for r in c["data_table"]]
    d.appendix_table("Comparable-tool prices behind the stack chart", columns=["Product", "Category", "First-year cost",
                                                                                 "Basis", "Source"],
                     rows=rows, widths=[1.8, 2.2, 1.3, 2.2, 3.0], highlight_row=len(rows) - 1, eyebrow="Backup",
                     lead=f"Stack total of the six tools, year one: {stack_total}",
                     notes="Backup for the stack-cost slide. Full source links: " +
                           "; ".join(f"{r['product']}: {r['source']}" for r in c["data_table"]) + ". " + c["footnote"],
                     footer="Business Plan §3 and §6a. " + c["footnote"], page="A1", hidden=True)
    sl = S[13]
    nt = sl["chart"]["data_table"]
    d.appendix_table("Net per sale after merchant-of-record fees", columns=["Item", "List price", "Fee", "Net to SparkV"],
                     rows=[[r["item"], f"${r['list']:,.2f}", f"${r['fee']:,.2f}" + (f" ({r['fee_note']})" if r.get("fee_note") else ""),
                            f"${r['net']:,.2f}"] for r in nt],
                     widths=[3.0, 1.6, 4.0, 1.6], highlight_row=2, eyebrow="Backup",
                     notes="Backup for the net-per-sale chart. " + sl["chart"]["source"],
                     footer=sl["chart"]["source"], page="A2", hidden=True)
    c2 = S[14]["chart_2"]
    d.appendix_table("Apple installed-base figures and sources", columns=["Date", "Figure", "Source", "Note"],
                     rows=[[r["date"], f"{r['value_billions']:.2f} B", r["source"].split("//", 1)[1].split("/")[0],
                            r.get("note", "")] for r in c2["data_table"]] +
                          [[e["date"] if e.get("date") else "", f"{e['label']}: {e['value']}",
                            e["source"].split("//", 1)[1].split("/")[0] if e.get("source") else "", ""] for e in c2["extra_stats"]],
                     widths=[1.3, 4.6, 2.4, 3.0], eyebrow="Backup",
                     notes="Backup for the installed-base slide. Full links: " +
                           "; ".join(f"{r['date']}: {r['source']}" for r in c2["data_table"]) +
                           f"; Mac active base: {c2['extra_stats'][0]['source']}.",
                     footer=c2["source"], page="A3", hidden=True)
    return d


# ------------------------------------------------------------------------------- slide parts
def pricing_matrix(d: TechDeck, s, t: dict, top: float) -> None:
    """Plan matrix: label column + Free / Pro / Team; the Pro column sits in a white band with a
    red outline (STYLE.md: highlighted plan = 2 px red outline). Rules are split at the band edges."""
    cols = t["columns"]
    rows = [list(r) for r in t["rows"]]
    rows[0][2] = rows[0][2].replace("$39 one-time", "**$39 one-time**")
    rows[0][3] = rows[0][3].replace("$8 per seat per month", "**$8 per seat per month**")
    widths = [1.75, 2.55, 3.7, 3.33]
    gap = 0.24
    x0 = MARGIN
    cw = [w_ * (CONTENT_W - 3 * gap) / sum(widths) for w_ in widths]
    cx = [x0 + sum(cw[:i]) + gap * i for i in range(4)]
    vpad = 0.07
    lh = TYPE["label"].size * TYPE["label"].lh / 72 + 0.0005
    hs = [max(d.hgt(v, "cell14_ink" if j == 0 else "cell14", cw[j]) for j, v in enumerate(r)) + 2 * vpad for r in rows]
    total = 0.14 + lh + 0.12 + sum(hs) + 0.08
    if top + total > BOTTOM + 1e-6:
        raise LayoutError(f"slide {s.page}: pricing matrix needs {total:.2f} in, has {BOTTOM - top:.2f}")
    bx, bw_ = cx[2] - gap / 2, cw[2] + gap
    band = d.rect(s, bx, top, bw_, total, fill="white", line="red", line_w=1.2, radius=0.1, name="Pro band")
    yy = top + 0.14
    for j, c in enumerate(cols):
        if c:
            d.text(s, cx[j], yy, cw[j], lh, c, "label", color="ink" if j == 2 else None,
                   parent=band if j == 2 else None, name="column head")
    yy += lh + 0.12

    def rule(y_, color="hairline"):
        d.line(s, x0, y_, bx, y_, color=color, name="row rule")
        d.line(s, bx, y_, bx + bw_, y_, color=color, parent=band, name="row rule")
        d.line(s, bx + bw_, y_, x0 + CONTENT_W, y_, color=color, name="row rule")

    rule(yy, "ink")
    for ri, (r, rh) in enumerate(zip(rows, hs)):
        for j, v in enumerate(r):
            st = "cell14_ink" if j == 0 else "cell14"
            d.text(s, cx[j], yy + vpad, cw[j], rh - 2 * vpad, v, st, parent=band if j == 2 else None,
                   name=f"cell r{ri + 1}c{j + 1}")
        yy += rh
        if ri != len(rows) - 1:
            rule(yy)


def roadmap(d: TechDeck, s, ms: list, top: float) -> None:
    """Vertical 30-day rail: dot, day range, milestone; the ship node is red, blockers are tagged."""
    rail_x = MARGIN + 0.08
    dx, dw = MARGIN + 0.4, 1.45
    tag_w = 0.9
    lx = dx + dw + 0.25
    lw = MARGIN + CONTENT_W - lx - tag_w - 0.2
    vpad = 0.1
    hs = [d.hgt(m["label"], "tb", lw) + 2 * vpad for m in ms]
    if top + sum(hs) > BOTTOM + 1e-6:
        raise LayoutError(f"slide {s.page}: roadmap needs {sum(hs):.2f} in, has {BOTTOM - top:.2f}")
    p = TYPE["tb"].size * TYPE["tb"].lh / 72
    first_mid = top + vpad + p / 2
    last_mid = top + sum(hs[:-1]) + vpad + p / 2
    rail = d.line(s, rail_x, first_mid, rail_x, last_mid, color="hairline", width=1.5, name="roadmap rail")
    yy = top
    for i, (m, rh) in enumerate(zip(ms, hs)):
        ship = m.get("accent", False)
        dd = 0.16 if ship else 0.11
        d.rect(s, rail_x - dd / 2, yy + vpad + p / 2 - dd / 2, dd, dd, oval=True, fill="red" if ship else "ink",
               hosts=(rail,), name="roadmap dot")
        d.text(s, dx, yy + vpad, dw, d.hgt(f"Days {m['days']}", "tb_med", dw), f"Days {m['days']}", "tb_med",
               name="days")
        d.text(s, lx, yy + vpad, lw, rh - 2 * vpad, m["label"], "tb_ink" if ship else "tb", name="milestone")
        if m.get("blocker"):
            th = TYPE["label"].size * TYPE["label"].lh / 72 + 0.0005
            d.text(s, MARGIN + CONTENT_W - tag_w, yy + vpad + (p - th) / 2, tag_w, th, "Blocker", "label",
                   align="r", name="blocker tag")
        yy += rh
        if i != len(ms) - 1:
            d.line(s, dx, yy, MARGIN + CONTENT_W, yy, name="row rule")


def top_device(d: TechDeck, s, image: str, shot_w: float) -> None:
    """The top of a MacBook display at the slide's top edge: bezel, screen in the render's own
    edge colours, render flush with the top so the island touches the slide edge, notch on top."""
    path = d.image_path(image)
    iw, ih = d.image_size(path)
    if shot_w > d.max_width_in(path):
        raise LayoutError("top_device: render upscaled too far")
    shot_h = shot_w * ih / iw
    scr_w = shot_w
    side = 12 / PX_PER_IN
    scr_h = shot_h + 0.32
    lid_w, lid_h = scr_w + 2 * side, scr_h + side
    lx = (SLIDE_W - lid_w) / 2
    lid = d.rect(s, lx, 0, lid_w, lid_h, fill="bezel", radii=(0, 26 / PX_PER_IN), bleed=True, name="device lid")
    top_c, bot_c = d.edge_colors(path)
    scr = d.rect(s, lx + side, 0, scr_w, scr_h, grad=[(0, top_c), (shot_h / scr_h, bot_c), (1, "scr_end")],
                 radii=(0, 16 / PX_PER_IN), parent=lid, bleed=True, name="device screen")
    sx = lx + side + (scr_w - shot_w) / 2
    shot = d.picture(s, path, sx, 0, shot_w, shot_h, parent=scr, bleed=True, name=f"device screenshot {image}")
    nw, nh = 0.30 * shot_w, 0.0444 * shot_w
    d.rect(s, sx + (shot_w - nw) / 2, 0, nw, nh, fill="notch", radii=(0, 14 / PX_PER_IN * nw / 2.083), parent=scr,
           hosts=(shot,), bleed=True, name="device notch")
    return lid.b


def numbered_list(d: TechDeck, s, x: float, w: float, top: float, items) -> float:
    """01..NN in a key column (14.4 pt medium ink) and the item text, hairline under each row."""
    key_w = 0.6
    d.line(s, x, top, x + w, top, name="list rule")
    yy = top
    for k, item in enumerate(items):
        th = d.hgt(item, "tb", w - key_w)
        d.text(s, x, yy + 0.13, key_w - 0.05, d.hgt(f"{k + 1:02d}", "tb_med", key_w - 0.05), f"{k + 1:02d}",
               "tb_med", name="item number")
        d.text(s, x + key_w, yy + 0.13, w - key_w, th, item, "tb", name="item")
        yy += th + 0.26
        d.line(s, x, yy, x + w, yy, name="list rule")
    if yy > BOTTOM + 1e-6:
        raise LayoutError(f"slide {s.page}: numbered list overflows")
    return yy


# ------------------------------------------------------------------------------- verification
def verify_pptx(path: str, expected: int) -> dict:
    prs = Presentation(path)
    slides = list(prs.slides)
    res = {"slides": len(slides), "expected": expected, "notes_missing": [], "charts": 0, "hidden": [],
           "chart_slides": []}
    for i, sl in enumerate(slides, 1):
        txt = sl.notes_slide.notes_text_frame.text if sl.has_notes_slide else ""
        if not txt.strip():
            res["notes_missing"].append(i)
        n = sum(1 for sh in sl.shapes if getattr(sh, "has_chart", False))
        if n:
            res["charts"] += n
            res["chart_slides"].append(i)
        if sl._element.get("show") == "0":
            res["hidden"].append(i)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome", action="store_true", help="also run the headless Chrome overflow check")
    ap.add_argument("--shots", help="write a PNG per slide into this folder (headless Chrome)")
    a = ap.parse_args()
    d = build()
    d.save(OUT_PPTX)
    probs = d.check_layout()
    idx = d.html_preview(OUT_HTML, problems=probs)
    if a.chrome:
        probs += chrome_check(idx)
    with open(OUT_REPORT, "w") as f:
        json.dump(probs, f, indent=1, ensure_ascii=False)
    if a.shots:
        os.makedirs(a.shots, exist_ok=True)
        for s in d.slides:
            chrome_screenshot(idx, s.index, os.path.join(a.shots, f"slide-{s.index:02d}.png"))
    v = verify_pptx(OUT_PPTX, len(d.slides))
    errs = [p for p in probs if p.get("severity") == "error"]
    print(f"slides: {len(d.slides)}\npptx: {OUT_PPTX}\npreview: {idx}\nverify: {json.dumps(v)}\n"
          f"problems: {len(errs)} errors, {len(probs) - len(errs)} warnings")
    for p in probs:
        print(" ", p)
    sys.exit(1 if errs or v["notes_missing"] or v["slides"] != len(d.slides) else 0)


if __name__ == "__main__":
    main()
