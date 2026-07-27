#!/usr/bin/env python3
"""Flatten the 21 artist-revised SVGs into the on-chain composable form.

The artist delivered raw Illustrator exports that carry a `<defs><style>.cls-N{}`
stylesheet and generic ids (`Ebene_12`, `Unbenannter_Verlauf_17`). The on-chain
renderer concatenates every layer's INNER content under ONE shared `<svg>` root,
so class selectors and ids MUST be layer-local or they collide across layers and
corrupt the composite. Every existing onchain-data/svg/*.svg is therefore already
flattened: no `class`/`<style>`, styles inline on each element, and every id
namespaced `<slug>_svg_<origId>`.

This script reproduces that exact flattening for the revisions, producing
onchain-data/svg/<cat>/<slug>-v2.svg (a clean single-root document that
script/SvgStrip.sol strips exactly like the originals) and writing
onchain-data/revisions-index.json (the definitive from->to mapping).

  - inlines every matched CSS declaration onto its element (grouped selectors and
    multi-class elements honoured, document order = override order, inline style
    wins last);
  - namespaces every id and every `url(#..)` / `href="#.."` reference with the
    per-trait prefix `<slug>-v2_svg_` (globally unique, never collides with a v1
    layer nor another revision);
  - preserves gradient <defs> (only the <style> child is removed);
  - strips the `<?xml?>` declaration.

Run from repo root:  python3 script/normalize_revisions.py
Requires: tinycss2 (already present in the toolchain).
"""
import json
import os
import re
import xml.etree.ElementTree as ET

import tinycss2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = "/private/tmp/claude-501/-Users-adrian/c17f0312-f7a6-4226-95a8-c2656bb77321/scratchpad/traits_new/Traits New"

SVG_NS = "http://www.w3.org/2000/svg"
XLINK_NS = "http://www.w3.org/1999/xlink"
ET.register_namespace("", SVG_NS)
ET.register_namespace("xlink", XLINK_NS)

# (artist_dir, artist_file, cat, slug, name, from_id, to_id)
REVISIONS = [
    ("Art Background", "Star Blue.svg",          0, "star-blue",           "Star Blue",          4,   15),
    ("Art Background", "Star Neon.svg",           0, "star-neon",           "Star Neon",          8,   16),
    ("Art Background", "Star Pink.svg",           0, "star-pink",           "Star Pink",          10,  17),
    ("Art Background", "Star Red.svg",            0, "star-red",            "Star Red",           12,  18),
    ("Base",           "Glow Stone.svg",          1, "glow-stone",          "Glow Stone",         262, 276),
    ("Base",           "Heatwave.svg",            1, "heatwave",            "Heatwave",           264, 277),
    ("Base",           "Impression Sunrise.svg",  1, "impression-sunrise",  "Impression Sunrise", 265, 278),
    ("Base",           "Soft Cloud.svg",          1, "soft-cloud",          "Soft Cloud",         269, 279),
    ("Base",           "Time Leap.svg",           1, "time-leap",           "Time Leap",          275, 280),
    ("Clothes",        "Greek Gods.svg",          2, "greek-gods",          "Greek Gods",         516, 527),
    ("Clothes",        "Painter Work.svg",        2, "painter-work",        "Painter Work",       518, 528),
    ("Clothes",        "White Hoodie.svg",        2, "white-hoodie",        "White Hoodie",       526, 529),
    ("Head",           "Greek Gods.svg",          3, "greek-gods",          "Greek Gods",         773, 783),
    ("Head",           "Trucker Cap.svg",         3, "trucker-cap",         "Trucker Cap",        782, 784),
    ("Mouth",          "Artistic.svg",            4, "artistic",            "Artistic",           1025, 1044),
    ("Mouth",          "Gentleman.svg",           4, "gentleman",           "Gentleman",          1031, 1045),
    ("Left Eye",       "Colony.svg",              5, "colony",              "Colony",             1285, 1300),
    ("Left Eye",       "So Lame.svg",             5, "so-lame",             "So Lame",            1293, 1301),
    ("Right Eye",      "Color Picker.svg",        7, "color-picker",        "Color Picker",       1795, 1812),
    ("Right Eye",      "Cynical.svg",             7, "cynical",             "Cynical",            1796, 1813),
    ("Right Eye",      "Mad Man.svg",             7, "mad-man",             "Mad Man",            1802, 1814),
]

CAT_DIR = {
    0: "art-background", 1: "base", 2: "clothes", 3: "head",
    4: "mouth", 5: "left-eye", 6: "nose", 7: "right-eye",
}


def parse_stylesheet(css_text):
    """Return an ordered list of (set(class_names), [(prop, value), ...])."""
    rules = []
    for rule in tinycss2.parse_stylesheet(css_text, skip_whitespace=True,
                                          skip_comments=True):
        if rule.type != "qualified-rule":
            continue
        prelude = tinycss2.serialize(rule.prelude)
        classes = set()
        for sel in prelude.split(","):
            sel = sel.strip()
            if sel.startswith("."):
                classes.add(sel[1:])
        decls = []
        for d in tinycss2.parse_declaration_list(
            rule.content, skip_whitespace=True, skip_comments=True
        ):
            if d.type == "declaration":
                decls.append((d.lower_name, tinycss2.serialize(d.value).strip()))
        rules.append((classes, decls))
    return rules


def merge_style(existing_inline, class_list, rules):
    """Compute an ordered inline style dict: class rules in document order,
    then any pre-existing inline style overriding last."""
    out = {}  # dict preserves insertion order (py3.7+)
    cls = set(class_list)
    for classes, decls in rules:
        if classes & cls:
            for prop, val in decls:
                out[prop] = val
    if existing_inline:
        for chunk in existing_inline.split(";"):
            if ":" in chunk:
                k, v = chunk.split(":", 1)
                out[k.strip()] = v.strip()
    return out


def style_to_str(d):
    return ";".join(f"{k}:{v}" for k, v in d.items())


def localname(tag):
    return tag.split("}", 1)[1] if "}" in tag else tag


def normalize(path, slug):
    raw = open(path, "r", encoding="utf-8").read()
    raw = re.sub(r"<\?xml[^>]*\?>", "", raw).strip()
    root = ET.fromstring(raw)

    # 1) collect + strip stylesheet
    css_text = ""
    for defs in root.iter("{%s}defs" % SVG_NS):
        for style in list(defs.findall("{%s}style" % SVG_NS)):
            css_text += style.text or ""
            defs.remove(style)
    rules = parse_stylesheet(css_text) if css_text else []

    prefix = f"{slug}-v2_svg_"

    # 2) walk: inline styles, drop class, namespace ids
    for el in root.iter():
        cls = el.attrib.pop("class", None)
        if cls is not None:
            merged = merge_style(el.attrib.get("style"), cls.split(), rules)
            if merged:
                el.set("style", style_to_str(merged))
        # namespace this element's own id
        if "id" in el.attrib:
            el.set("id", prefix + el.attrib["id"])

    # root id too (matches original convention, harmless)
    if "id" in root.attrib:
        pass  # already prefixed in the walk above

    # 3) rewrite ALL references to ids across every attribute value
    def rewrite_val(v):
        v = re.sub(r"url\(#([^)]+)\)", lambda m: f"url(#{prefix}{m.group(1)})", v)
        return v

    for el in root.iter():
        for k, v in list(el.attrib.items()):
            if isinstance(v, str):
                if "url(#" in v:
                    el.set(k, rewrite_val(v))
                if localname(k) == "href" and v.startswith("#"):
                    el.set(k, "#" + prefix + v[1:])

    # 4) force a clean root (drop root id/class so SvgStrip sees a plain wrapper;
    #    keep xmlns + viewBox). Rebuild attribs deterministically.
    keep = {}
    for k, v in root.attrib.items():
        ln = localname(k)
        if ln in ("viewBox",):
            keep[k] = v
    root.attrib.clear()
    root.attrib.update(keep)

    out = ET.tostring(root, encoding="unicode")
    # ET emits ns0: if registration is bypassed in some envs; guard anyway.
    out = out.replace("ns0:", "").replace(":ns0", "")
    # ensure the standard opening (xmlns present via register_namespace)
    if "xmlns=" not in out.split(">", 1)[0]:
        out = out.replace("<svg", '<svg xmlns="%s"' % SVG_NS, 1)
    return out


def main():
    index = {"note": "Definitive from->to override mapping for the 21 artist "
                     "revisions. to_id = (cat<<8)|nextOption(cat) captured against "
                     "the LIVE store 0x6702016627141350792Dd366885a2Fc794eE46C6.",
             "revisions": []}
    for (adir, afile, cat, slug, name, from_id, to_id) in REVISIONS:
        src = os.path.join(ART, adir, afile)
        assert os.path.exists(src), "missing artist file: " + src
        assert (from_id >> 8) == cat and (to_id >> 8) == cat, "cat mismatch " + slug
        flat = normalize(src, slug)
        outdir = os.path.join(ROOT, "onchain-data", "svg", CAT_DIR[cat])
        outrel = f"onchain-data/svg/{CAT_DIR[cat]}/{slug}-v2.svg"
        outpath = os.path.join(ROOT, outrel)
        os.makedirs(outdir, exist_ok=True)
        with open(outpath, "w", encoding="utf-8") as f:
            f.write(flat)
        index["revisions"].append({
            "cat": cat, "slug": slug, "name": name,
            "from": from_id, "to": to_id,
            "v2_svg": outrel,
            "artist_raw": src,
        })
        print(f"{name:20s} cat{cat} {from_id:5d} -> {to_id:5d}  {outrel}  ({len(flat)}B)")
    with open(os.path.join(ROOT, "onchain-data", "revisions-index.json"), "w") as f:
        json.dump(index, f, indent=1)
    print(f"\nWrote {len(REVISIONS)} v2 svgs + onchain-data/revisions-index.json")


if __name__ == "__main__":
    main()
