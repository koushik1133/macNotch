"""
Build the SparkV CUSTOMER deck (Apple-minimal style) from customer/outline.json.

Run:  /opt/anaconda3/bin/python3 build_customer.py [--chrome] [--shots DIR]
Out:  customer/SparkV-Customer-Deck.pptx
      customer/preview/index.html        (one 1600 x 900 frame per slide; ?slide=N shows one)
      customer/layout-report.json        (layout check + optional headless Chrome check)

Rules followed:
  * All headlines, body copy, numbers, notes, chart data and [TBD] text come from the outline.
    The only text added here: short eyebrow labels and footer source lines (summaries of the
    outline's own sources and notes).
  * [TBD: ...] stays visible (grey italic, done by the library markup).
  * Dense outline slides are split, not shrunk: slide 13 becomes a price table (13a) and a
    spend chart (13b). The full plan table behind slide 15 is a hidden backup (A3).
  * Text is never shrunk below its STYLE.md size: any box the library had to scale down is
    reported as an error by extra_checks().
  * Exit code 1 if any check reports an error.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DECKS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(DECKS, "generator"))

from pptx import Presentation  # noqa: E402
import sparkv_deck as sd  # noqa: E402
from sparkv_deck import Deck as _BaseDeck, accent, chrome_check, chrome_screenshot, load_outline  # noqa: E402

PPTX = os.path.join(HERE, "SparkV-Customer-Deck.pptx")
PREVIEW = os.path.join(HERE, "preview", "index.html")
REPORT = os.path.join(HERE, "layout-report.json")


# --------------------------------------------------------------------------- outline helpers
class Outline:
    def __init__(self):
        self.o = load_outline("customer")
        self.deck = self.o["deck"]
        self.by_id = {s["id"]: s for s in self.o["slides"] + self.o.get("appendix", [])}
        self.names = self.deck.get("feature_names", {})
        self.media_root = self.deck.get("media_root")

    def __getitem__(self, sid):
        return self.by_id[sid]

    def t(self, text):
        """Apply product-name swaps (feature_names.clicky) to a copy string."""
        if text is None:
            return None
        if isinstance(text, (list, tuple)):
            return [self.t(x) for x in text]
        clicky = self.names.get("clicky")
        if clicky and clicky != "Clicky":
            text = text.replace("Clicky", clicky)
        return text

    def head(self, s):
        return self.t(accent(s["header"], s.get("header_accent")))

    def image(self, s, role_prefix="hero", frame=None):
        """File for the slide's hero image. Prefers the recorded 4K 'final' still when it exists."""
        for im in s.get("images", []):
            if im.get("role", "").startswith(role_prefix) and (frame is None or im.get("frame") == frame):
                fin = im.get("final")
                if fin and self.media_root:
                    fp = os.path.join(self.media_root, fin)
                    if os.path.exists(fp):
                        return fp
                return im["file"]
        return None


class Deck(_BaseDeck):
    """Library deck with one local fix (the library itself is not edited)."""

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


    def _metric_tiles(self, s, metrics, boxes, value_style="kpi"):
        """Same as the library, but the number's room keeps 0.002 in of slack so the caption
        box is never a hair shorter than its measured text (which made the library shrink the
        caption to 97.5%)."""
        PX = sd.PX_PER_IN
        padx, pady = 32 / PX, 28 / PX
        if min(bx[3] for bx in boxes) < 1.6:
            pady = 20 / PX
        gap = 14 / PX
        ts = sd.TYPE[value_style]
        k = 1.0
        for m, (x, y, w, h) in zip(metrics, boxes):
            p = self._metric_value_para(m, value_style)
            _, _, kk = self.fit_text([p], w - 2 * padx, ts.size * ts.lh / 72 + 0.001, ts.min_scale,
                                     f"slide {s.page} metric {m.get('value')}")
            k = min(k, kk)
            lab = self.measure([self.P(m.get("label") or "", "small")], w - 2 * padx)[0] if m.get("label") else 0
            room = h - 2 * pady - (gap + lab if lab else 0) - 0.002
            k = min(k, room / (ts.size * ts.lh / 72))
        if k < ts.min_scale - 1e-9:
            raise sd.TextFitError(f"slide {s.page}: metric tiles too small for their numbers and captions "
                                  f"(scale {k:.2f} < {ts.min_scale})")
        for m, (x, y, w, h) in zip(metrics, boxes):
            cardel = self.card(s, x, y, w, h, name="metric card")
            p = self._metric_value_para(m, value_style).scaled(k)
            vh = p.pitch / 72 + 0.0005
            self.text(s, x + padx, y + pady, w - 2 * padx, vh, [p], value_style, parent=cardel, name="metric value")
            cap_y = y + pady + vh + gap
            if m.get("label"):
                self.text(s, x + padx, cap_y, w - 2 * padx, y + h - pady - cap_y, m["label"], "small",
                          parent=cardel, name="metric label")

    def feature_showcase(self, title, *, eyebrow=None, lead=None, bullets=(), image=None, frame="notch",
                         notes="", footer=None, page=None, hidden=False, shot_frac=1.0):
        """Library feature_showcase with one change: every list row gets the same height (the
        tallest row) and its text is centred in the row, so the hairlines are evenly spaced even
        where PIL (with its 4% width safety margin) expects a wrap the renderer does not make."""
        PX = sd.PX_PER_IN
        s = self._new("feature_showcase", "mist", notes, footer, page, hidden)
        x, w = sd.col_x(1), sd.span(4)
        parts = []
        if eyebrow:
            parts.append(("eyebrow", eyebrow, 0))
        parts.append(("h1_side", title, 20 / PX if eyebrow else 0))
        if lead:
            parts.append(("body", lead, 24 / PX))
        row_pad = 14 / PX
        text_hs = [self.measure([self.P(b, "small")], w)[0] for b in bullets]
        row = (max(text_hs) if text_hs else 0) + 2 * row_pad

        def lim_h(st, t):
            ts = sd.TYPE[st]
            lim = 3 if st == "h1_side" else 4
            return min(self.measure([self.P(t, st)], w)[0], lim * ts.size * ts.lh / 72)

        total = sum(g + lim_h(st, t) for st, t, g in parts)
        if bullets:
            total += 36 / PX + row * len(bullets)
        avail = sd.BOTTOM - sd.TOP
        if total > avail:
            raise sd.LayoutError(f"feature_showcase slide {s.page}: text block {total:.2f} in > {avail:.2f} in")
        y = sd.TOP + (avail - total) / 2
        for st, t, gap in parts:
            y += gap
            ts = sd.TYPE[st]
            lim = 3 if st == "h1_side" else 4
            el = self.text(s, x, y, w, None, t, st, max_h=lim * ts.size * ts.lh / 72 + 0.001, name=st)
            y = el.b
        if bullets:
            y += 36 / PX
            self.line(s, x, y, x + w, y, name="list rule")
            for b in bullets:
                self.text(s, x, y + row_pad, w, row - 2 * row_pad, b, "small", anchor="m", name="bullet")
                y += row
                self.line(s, x, y, x + w, y, name="list rule")
        if image:
            dx, dw = sd.col_x(5), sd.span(8)
            if frame == "notch":
                lid = 6.833
                h = self.macbook_height(lid)
                self.macbook(s, dx + (dw - lid) / 2, sd.TOP + (avail - h) / 2, lid, image, shot_frac=shot_frac,
                             name="device")
            elif frame == "window":
                self.window_shot(s, image, dx, sd.TOP + 0.1, dw, avail - 0.2)
            else:
                raise sd.LayoutError(f"unknown frame {frame!r}")
        return s


LIVE = "Real render of the current build, sample data."


# --------------------------------------------------------------------------- build
def build() -> Deck:
    O = Outline()
    d = Deck(O.deck["title"], footer_default="")

    # 01 Title ------------------------------------------------------------------
    s = O["title"]
    d.title_slide(O.head(s), eyebrow=O.t(s["body"][0]), lead=O.t(s["subtitle"]), cta=O.t(s["body"][1]),
                  image=O.image(s), notes=O.t(s["notes"]), page="01")

    # 02 Problem ----------------------------------------------------------------
    s = O["problem"]
    d.minimal_body(O.head(s), eyebrow="Problem", lead=O.t(s["subtitle"]), points=O.t(s["body"]),
                   notes=O.t(s["notes"]), page="02",
                   footer="$492 = sum of the year-one prices on slide 13; third-party listings, re-check before publishing.")

    # 03 Solution ---------------------------------------------------------------
    s = O["solution"]
    d.section_header(O.head(s), eyebrow="Solution", lead=O.t(s["subtitle"]), image=O.image(s),
                     captions=O.t(s["body"]), notes=O.t(s["notes"]), page="03", footer=LIVE)

    # 04 A day ------------------------------------------------------------------
    s = O["day"]
    nodes = [{"time": n["time"], "text": O.t(n["text"]), "image": n["image"], "active": n.get("active", False)}
             for n in s["timeline"]["nodes"]]
    d.timeline(O.head(s), nodes, eyebrow="Timeline", lead=O.t(s["subtitle"]), notes=O.t(s["notes"]), page="04",
               footer=("Times are illustrative. " if s["timeline"].get("times_are_illustrative") else "") + LIVE)

    # 05-11 Feature showcases ------------------------------------------------------
    feats = [
        ("notch_essentials", "Notch essentials", "notch", None,
         LIVE + " Live check required: media, Tray drag, AirDrop, calendar, live activities."),
        ("talk", "Talk", "notch", None,
         LIVE + " Live check required: fn key, speech, Reply Drafter."),
        ("screen_help", "Screen help", "notch", None,
         LIVE + " Without an optional Groq key, " + O.t("Clicky") + " reads screen text on device. Live check required."),
        ("meetings", "Meetings", "window", None,
         LIVE + " Live check required: audio capture, translation."),
        ("files_search", "Search", "window", None,
         LIVE + " Search verified on sample data. Downloads and drag need a live check."),
        ("focus", "Focus", "notch", None,
         LIVE + " Live check required: Do Not Disturb, glow, Modes, camera."),
        ("builders", "Builders", "window", None,
         LIVE + " " + O["builders"].get("requirements_note", "") + "; only on sites you own or may test. Browser Flows is beta."),
    ]
    for i, (sid, label, frame, _, foot) in enumerate(feats):
        s = O[sid]
        d.feature_showcase(O.head(s), eyebrow=f"{label} · {s['plan_badge']}", lead=O.t(s["subtitle"]),
                           bullets=O.t(s["body"]), image=O.image(s), frame=frame, notes=O.t(s["notes"]),
                           page=f"{5 + i:02d}", footer=foot)

    # 12 Proof ------------------------------------------------------------------
    s = O["proof"]
    d.metrics_dashboard(O.head(s), eyebrow="Proof", lead=O.t(s["subtitle"]),
                        metrics=[{"value": m["value"], "label": O.t(m["label"]), "accent": m.get("accent", False)}
                                 for m in s["metrics"]],
                        notes=O.t(s["notes"]), page="12",
                        footer="Internal tests, not customer metrics. Sources: Business Plan §9; Feature Guide §25 and Verification summary.")

    # 13a One app instead of six: price table ---------------------------------------
    s = O["comparison"]
    t = s["table"]
    d.comparison_table(O.head(s), eyebrow="Value", lead=O.t(s["subtitle"]), columns=t["columns"],
                       rows=[[c if c else None for c in r] for r in t["rows"]], widths=[2.2, 1.8, 3.2, 3.6],
                       highlight_row=t["highlight_row"], notes=O.t(s["notes"]), page="13a",
                       footer=s["footnote"])

    # 13b One app instead of six: spend chart (data_table, years 1 and 2) -------------
    c = s["chart"]
    rows = c["data_table"]
    cats = [r["item"] for r in rows]
    i_tot = cats.index("Separate apps total")
    i_spk = cats.index("SparkV Pro")
    spk = next(g for g in c["groups"] if g["name"] == "SparkV Pro")
    d.chart_slide(O.head(s), {
        "type": "bar", "title": c["title"], "categories": cats, "number_format": "$#,##0.00",
        "series": [
            {"name": c["categories"][0], "values": [r["year1"] for r in rows], "color": "bar",
             "point_colors": {i_tot: "ink", i_spk: "red"}},
            {"name": c["categories"][1], "values": [r["year2"] for r in rows], "color": "hairline",
             "point_colors": {i_tot: "ink3"}},
        ],
        "source": c["source"],
    }, eyebrow="Value", lead=O.t(s["subtitle"]),
        side=[O.t(s["body"][0]), O.t(s["body"][1]),
              f"SparkV Pro: {spk['value_notes'][0]}; year 2: {spk['value_notes'][1]}.",
              f"Excluded from the sum: {c['excluded']}."],
        notes=O.t(s["notes"]), page="13b",
        footer="Values are the outline's chart data table. Feature sets differ. Legal review required before naming competitors.")

    # 14 Market -----------------------------------------------------------------
    s = O["market"]
    c = s["chart"]
    i_tbd = [i for i, v in enumerate(c["series"][0]["values"]) if v is None]
    i_last = len(c["categories"]) - 1
    d.metrics_dashboard(O.head(s), eyebrow="Fit", lead=O.t(s["subtitle"]),
                        metrics=[{"value": m["value"], "label": O.t(m["label"])} for m in s["metrics"]],
                        chart={"type": "column", "title": c["title"], "categories": c["categories"],
                               "number_format": '0.0"M"',
                               "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"],
                                           "color": "bar", "point_colors": {i_last: "ink"}}],
                               "tbd": list(c["tbd"].values()), "source": c["source"]},
                        notes=O.t(s["notes"]), page="14",
                        footer=O.t(s["body"][2]) + " Sources: Apple via TechCrunch (Oct 2018); IDC preliminary via AppleInsider, MacTrast, MacTech.")
    assert i_tbd, "market chart: expected a [TBD] quarter"

    # 15 Pricing ----------------------------------------------------------------
    s = O["pricing"]
    cs = s["table"]["card_summary"]
    plans = [
        {"name": "Free", "price": "$0", "inr": "₹0", "note": "1 Mac", "features": cs["Free"]},
        {"name": "Pro", "price": "$39", "unit": "one-time", "inr": "₹1,499", "inr_aside": "launch week $29 · ₹999",
         "note": "2 Macs per person · 12 months of updates", "features": cs["Pro"], "highlight": True,
         "tag": "Recommended"},
        {"name": "Team", "price": "$8", "unit": "per seat / month", "inr": "₹499", "inr_aside": "billed yearly",
         "note": "Minimum 3 seats · 2 Macs per seat", "features": cs["Team"]},
    ]
    d.pricing_table(O.head(s), plans, eyebrow="Pricing", lead=O.t(s["subtitle"]),
                    aside=" · ".join(b.rstrip(".") for b in s["body"]), notes=O.t(s["notes"]), page="15",
                    footer=f"Source: {s['source']}. Pro updates after year one: optional $19/yr (₹799). The app keeps working.")

    # 16 CTA --------------------------------------------------------------------
    s = O["cta"]
    d.quote_or_cta(O.head(s), lead=O.t(s["subtitle"]), button=s["button"]["text"], caption=O.t(s["body"][1]),
                   extra=[O.t(s["body"][2])], image=O.image(s), notes=O.t(s["notes"]), page="16")

    # A1 Feature packs (hidden) ---------------------------------------------------
    s = O["packs"]
    t = s["table"]
    d.appendix_table(O.head(s), columns=t["columns"], rows=t["rows"], lead=O.t(s["subtitle"]),
                     widths=[1.6, 6.0, 1.5, 1.9], highlight_row=t["highlight_row"], notes=O.t(s["notes"]),
                     footer=f"Source: {s['source']}", page="A1", hidden=True)

    # A2 Why we can charge once (hidden; the waterfall is drawn as a column chart, negative fee below zero) ---------
    s = O["why_once"]
    c = s["chart"]
    vals = c["series"][0]["values"]
    d.chart_slide(O.head(s), {
        "type": "column", "title": c["title"], "categories": c["categories"], "number_format": "$#,##0.00",
        "series": [{"name": c["series"][0]["name"], "values": vals, "color": "bar",
                    "point_colors": {0: "ink", len(vals) - 1: "red"}}],
        "source": c["source"],
    }, eyebrow="Appendix", lead=O.t(s["subtitle"]), side=O.t(s["body"]), notes=O.t(s["notes"]),
        page="A2", hidden=True,
        footer="Merchant-of-record fee: Lemon Squeezy, Business Plan §4 (about +1.5% more on non-US orders).")

    # A3-A4 Full plan table (hidden backup for slide 15), split in two so cells keep 9 pt --------
    s = O["pricing"]
    t = s["table"]
    halves = [t["rows"][:6], t["rows"][6:]]
    for k, part in enumerate(halves):
        d.appendix_table(O.head(s), eyebrow=f"Appendix · plan details {k + 1} of {len(halves)}",
                         columns=["", "Free", "Pro", "Team"], rows=part,
                         lead=O.t(s["subtitle"]), widths=[1.5, 3.0, 3.9, 3.2], notes=(
                             f"Backup for detailed plan questions: the full plan table behind slide 15 "
                             f"(part {k + 1} of {len(halves)}). " + O.t(s["notes"])),
                         footer=f"Source: {s['source']}. Team shared Spaces are file packages, not live sync.",
                         page=f"A{3 + k}", hidden=True)
    return d


# --------------------------------------------------------------------------- extra checks
def extra_checks(d: Deck) -> list:
    """Checks on top of Deck.check_layout(): no text box was shrunk below its style size."""
    probs = []
    for s in d.slides:
        for e in s.els:
            if e.kind == "text" and e.props.get("scale", 1.0) < 0.999:
                probs.append({"slide": s.page, "severity": "error", "check": "shrunk", "element": e.name,
                              "message": f"text scaled to {e.props['scale']:.0%}; split the slide instead"})
    return probs


def verify_pptx(path: str, d: Deck) -> dict:
    """Re-open the saved file and confirm slide count, notes, hidden flags and charts."""
    prs = Presentation(path)
    slides = list(prs.slides)
    info = {"slides": len(slides), "hidden": [], "charts": [], "missing_notes": [], "pictures": 0}
    for i, sl in enumerate(slides, 1):
        page = d.slides[i - 1].page
        if sl._element.get("show") == "0":
            info["hidden"].append(page)
        if not (sl.has_notes_slide and sl.notes_slide.notes_text_frame.text.strip()):
            info["missing_notes"].append(page)
        for sh in sl.shapes:
            if sh.has_chart:
                ch = sh.chart
                info["charts"].append({"slide": page, "type": str(ch.chart_type).split(".")[-1].split(" ")[0],
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
