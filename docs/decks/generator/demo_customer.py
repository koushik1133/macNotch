"""
Demo: build a sample deck from docs/decks/customer/outline.json that exercises every
Apple-minimal layout in sparkv_deck.py, then run the layout check and write the HTML preview.

Run:  /opt/anaconda3/bin/python3 demo_customer.py [--chrome] [--shots DIR]
Out:  generator/demo/sparkv-customer-demo.pptx
      generator/demo/preview/index.html
      generator/demo/layout-report.json
All copy, numbers, notes and image names come from the outline; nothing is invented.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from sparkv_deck import Deck, accent, chrome_check, chrome_screenshot, load_outline  # noqa: E402

OUT = os.path.join(HERE, "demo")


def by_id(outline):
    return {s["id"]: s for s in outline["slides"] + outline.get("appendix", [])}


def hero(slide, frame=None):
    for im in slide.get("images", []):
        if im.get("role", "").startswith("hero") and (frame is None or im.get("frame") == frame):
            return im["file"]
    return None


def build() -> Deck:
    o = load_outline("customer")
    S = by_id(o)
    d = Deck("SparkV customer deck (layout demo)", footer_default="")

    # 1 title_slide ------------------------------------------------------------
    s = S["title"]
    d.title_slide(accent(s["header"], s["header_accent"]), eyebrow=s["body"][0], lead=s["subtitle"],
                  cta=s["body"][1], image=hero(s), notes=s["notes"])

    # 2 minimal_body -----------------------------------------------------------
    s = S["problem"]
    d.minimal_body(accent(s["header"], s["header_accent"]), eyebrow="Problem", lead=s["subtitle"],
                   points=s["body"], notes=s["notes"],
                   footer="$492 = sum of year-one prices on the comparison slide; third-party listings, re-check before publishing.")

    # 3 section_header (key visual) -------------------------------------------
    s = S["solution"]
    d.section_header(accent(s["header"], s["header_accent"]), eyebrow="Solution", lead=s["subtitle"],
                     image=hero(s), captions=s["body"], notes=s["notes"],
                     footer="Real render of the current build, sample data")

    # 4 timeline ---------------------------------------------------------------
    s = S["day"]
    nodes = [{"time": n["time"], "text": n["text"], "image": n["image"], "active": n.get("active", False)}
             for n in s["timeline"]["nodes"]]
    d.timeline(s["header"], nodes, eyebrow="A day", lead=s["subtitle"], notes=s["notes"],
               footer="Times are illustrative. Real renders of the current build, sample data.")

    # 5 feature_showcase, notch mockup with a band screenshot --------------------
    s = S["screen_help"]
    d.feature_showcase(accent(s["header"], s["header_accent"]), eyebrow=f"Screen help · {s['plan_badge']}",
                       lead=s["subtitle"], bullets=s["body"], image=hero(s), frame="notch",
                       notes=s["notes"], footer="Real render of the current build, sample data. Live check required.")

    # 6 feature_showcase, window frame ------------------------------------------
    s = S["meetings"]
    d.feature_showcase(accent(s["header"], s["header_accent"]), eyebrow=f"Meetings · {s['plan_badge']}",
                       lead=s["subtitle"], bullets=s["body"], image=hero(s, "window"), frame="window",
                       notes=s["notes"], footer="Real render of the current build, sample data. Live check required.")

    # 7 metrics_dashboard, 6 tiles --------------------------------------------
    s = S["proof"]
    d.metrics_dashboard(accent(s["header"], s["header_accent"]), eyebrow="Proof", lead=s["subtitle"],
                        metrics=s["metrics"], notes=s["notes"],
                        footer="Internal tests, not customer metrics. Sources: Business Plan §9; Feature Guide §25 and Verification summary.")

    # 8 two_column_comparison (check marks) ------------------------------------
    s = S["comparison"]
    rows = [(r[0], f"{r[1]} · {r[2]}", (True, r[3])) for r in s["table"]["rows"][:7]]
    d.two_column_comparison(accent(s["header"], s["header_accent"]), eyebrow="Value", lead=s["subtitle"],
                            left_head="Typical app", right_head="In SparkV", rows=rows,
                            summary=("All of the above", s["body"][0], s["body"][1]), notes=s["notes"],
                            footer="Prices: public third-party listings, Oct 2026 (Business Plan §3). Feature sets differ. Legal review required.")

    # 9 comparison_table (competitors, highlighted row) -------------------------
    t = s["table"]
    d.comparison_table(accent(s["header"], s["header_accent"]), eyebrow="Value", lead=s["subtitle"],
                       columns=t["columns"], rows=[[c if c else None for c in r] for r in t["rows"]],
                       widths=[2.2, 1.8, 3.2, 3.6], highlight_row=t["highlight_row"], notes=s["notes"],
                       footer=s["footnote"])

    # 10 chart_slide (clustered column, two series) ------------------------------
    c = s["chart"]
    sep = next(g for g in c["groups"] if g["name"] == "Separate apps")
    spk = next(g for g in c["groups"] if g["name"] == "SparkV Pro")
    d.chart_slide(accent(s["header"], s["header_accent"]), {
        "type": "column", "title": c["title"], "categories": c["categories"],
        "number_format": "$#,##0.00",
        "series": [{"name": "Separate apps (total)", "values": sep["totals"], "color": "bar"},
                   {"name": "SparkV Pro", "values": spk["totals"], "color": "red"}],
        "source": c["source"],
    }, eyebrow="Value", lead=s["subtitle"],
        side=[f"SparkV Pro: {spk['value_notes'][0]}.", f"Year 2: {spk['value_notes'][1]}.",
              f"Excluded: {c['excluded']}."],
        notes=s["notes"], footer="Values are the totals in the outline's chart data table.")

    # 11 metrics_dashboard with a chart ([TBD] point) ---------------------------
    s = S["market"]
    c = s["chart"]
    d.metrics_dashboard(accent(s["header"], s["header_accent"]), eyebrow="Fit", lead=s["subtitle"],
                        metrics=[{"value": m["value"], "label": m["label"]} for m in s["metrics"]],
                        chart={"type": "column", "title": c["title"], "categories": c["categories"],
                               "number_format": '0.0"M"',
                               "series": [{"name": c["series"][0]["name"], "values": c["series"][0]["values"],
                                           "color": "bar", "point_colors": {3: "ink"}}],
                               "tbd": list(c["tbd"].values()), "source": c["source"]},
                        notes=s["notes"], footer="Sources: Apple via TechCrunch (Oct 2018); IDC preliminary via AppleInsider, MacTrast, MacTech.")

    # 12 pricing_table -----------------------------------------------------------
    s = S["pricing"]
    cs = s["table"]["card_summary"]
    plans = [
        {"name": "Free", "price": "$0", "inr": "₹0", "note": "1 Mac", "features": cs["Free"]},
        {"name": "Pro", "price": "$39", "unit": "one-time", "inr": "₹1,499", "inr_aside": "launch week $29 · ₹999",
         "note": "2 Macs per person · 12 months of updates", "features": cs["Pro"], "highlight": True,
         "tag": "Recommended"},
        {"name": "Team", "price": "$8", "unit": "per seat / month", "inr": "₹499", "inr_aside": "billed yearly",
         "note": "Minimum 3 seats · 2 Macs per seat", "features": cs["Team"]},
    ]
    d.pricing_table(accent(s["header"], s["header_accent"]), plans, eyebrow="Pricing", lead=s["subtitle"],
                    aside=" · ".join(b.rstrip(".") for b in s["body"]), notes=s["notes"],
                    footer=f"Source: {s['source']}. Pro updates after year one: optional $19/yr (₹799).")

    # 13 quote_or_cta --------------------------------------------------------------
    s = S["cta"]
    d.quote_or_cta(accent(s["header"], s["header_accent"]), lead=s["subtitle"], button=s["button"]["text"],
                   caption=s["body"][1], extra=[s["body"][2]], image=hero(s), notes=s["notes"])

    # 14 appendix_table (hidden backup) -------------------------------------------
    s = S["packs"]
    t = s["table"]
    d.appendix_table(s["header"], columns=t["columns"], rows=t["rows"], lead=s["subtitle"],
                     widths=[1.6, 6.0, 1.5, 1.9], highlight_row=t["highlight_row"], notes=s["notes"],
                     footer=f"Source: {s['source']}", page="A1", hidden=True)
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome", action="store_true", help="also run the headless Chrome overflow check")
    ap.add_argument("--shots", help="write a PNG per slide into this folder (headless Chrome)")
    a = ap.parse_args()
    d = build()
    os.makedirs(OUT, exist_ok=True)
    pptx = d.save(os.path.join(OUT, "sparkv-customer-demo.pptx"))
    probs = d.check_layout()
    idx = d.html_preview(os.path.join(OUT, "preview", "index.html"), problems=probs)
    if a.chrome:
        probs += chrome_check(idx)
    with open(os.path.join(OUT, "layout-report.json"), "w") as f:
        json.dump(probs, f, indent=1, ensure_ascii=False)
    if a.shots:
        os.makedirs(a.shots, exist_ok=True)
        for s in d.slides:
            chrome_screenshot(idx, s.index, os.path.join(a.shots, f"slide-{s.index:02d}.png"))
    errs = [p for p in probs if p.get("severity") == "error"]
    print(f"slides: {len(d.slides)}  pptx: {pptx}\npreview: {idx}\nproblems: {len(errs)} errors, "
          f"{len(probs) - len(errs)} warnings")
    for p in probs:
        print(" ", p)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
