"""COCO JSON → PAGE XML converter.

Generates PAGE XML (PRImA format, 2019-07-15 schema) from COCO-format
annotations produced by the manuscript layout analysis pipeline.
"""

import datetime
import xml.etree.ElementTree as ET
from typing import Dict, Tuple

PAGE_NS = "http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
SCHEMA_LOC = (
    f"{PAGE_NS} "
    "http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15/pagecontent.xsd"
)

# Map the 22 manuscript classes → (PAGE region element, optional @type)
_REGION_MAP: Dict[str, Tuple[str, str | None]] = {
    "Border":                      ("SeparatorRegion", None),
    "Table":                       ("TableRegion", None),
    "Diagram":                     ("GraphicRegion", None),
    "Main script black":           ("TextRegion", "paragraph"),
    "Main script coloured":        ("TextRegion", "paragraph"),
    "Variant script black":        ("TextRegion", "other"),
    "Variant script coloured":     ("TextRegion", "other"),
    "Historiated":                  ("ImageRegion", None),
    "Inhabited":                   ("ImageRegion", None),
    "Zoo - Anthropomorphic":       ("ImageRegion", None),
    "Embellished":                 ("ImageRegion", None),
    "Plain initial- coloured":     ("TextRegion", "drop-capital"),
    "Plain initial - Highlighted": ("TextRegion", "drop-capital"),
    "Plain initial - Black":       ("TextRegion", "drop-capital"),
    "Page Number":                 ("TextRegion", "page-number"),
    "Quire Mark":                  ("TextRegion", "signature-mark"),
    "Running header":              ("TextRegion", "header"),
    "Catchword":                   ("TextRegion", "catch-word"),
    "Gloss":                       ("TextRegion", "marginalia"),
    "Illustrations":               ("ImageRegion", None),
    "Column":                      ("TextRegion", "paragraph"),
    "Music":                       ("MusicRegion", None),
}


def _seg_to_points(seg: list) -> str:
    """Convert flat segmentation [x1,y1,x2,y2,...] → 'x1,y1 x2,y2 ...'."""
    parts: list[str] = []
    for i in range(0, len(seg) - 1, 2):
        parts.append(f"{int(round(seg[i]))},{int(round(seg[i + 1]))}")
    return " ".join(parts)


def _bbox_to_points(bbox: list) -> str:
    """Convert COCO bbox [x,y,w,h] → rectangle 'x,y x+w,y x+w,y+h x,y+h'."""
    x, y, w, h = (int(round(v)) for v in bbox)
    return f"{x},{y} {x + w},{y} {x + w},{y + h} {x},{y + h}"


def coco_to_page_xml(coco_json: dict, image_id: int | None = None) -> str:
    """Convert COCO annotations for one image to a PAGE XML string.

    Args:
        coco_json: Full COCO JSON dict.
        image_id: Which image to convert.  ``None`` → first image.

    Returns:
        Well-formed PAGE XML string (UTF-8).
    """
    ET.register_namespace("", PAGE_NS)
    ET.register_namespace("xsi", XSI_NS)

    id_to_name: Dict[int, str] = {
        c["id"]: c["name"] for c in coco_json.get("categories", [])
    }
    images = {img["id"]: img for img in coco_json.get("images", [])}

    if image_id is None and images:
        image_id = next(iter(images))
    image = images.get(
        image_id, {"id": image_id or 0, "file_name": "unknown", "width": 0, "height": 0}
    )

    anns = [
        a for a in coco_json.get("annotations", [])
        if a["image_id"] == image["id"]
    ]

    # ── Root ──────────────────────────────────────────────────────────
    root = ET.Element(f"{{{PAGE_NS}}}PcGts")
    root.set(f"{{{XSI_NS}}}schemaLocation", SCHEMA_LOC)

    # Metadata
    meta = ET.SubElement(root, f"{{{PAGE_NS}}}Metadata")
    ET.SubElement(meta, f"{{{PAGE_NS}}}Creator").text = "Manuscript Layout Analysis"
    ET.SubElement(meta, f"{{{PAGE_NS}}}Created").text = (
        datetime.datetime.now(datetime.timezone.utc).isoformat()
    )

    # Page
    page_el = ET.SubElement(root, f"{{{PAGE_NS}}}Page")
    page_el.set("imageFilename", str(image.get("file_name", "unknown")))
    page_el.set("imageWidth", str(image.get("width", 0)))
    page_el.set("imageHeight", str(image.get("height", 0)))

    # Regions
    for idx, ann in enumerate(anns, 1):
        cat_name = id_to_name.get(ann["category_id"], "Unknown")
        tag, rtype = _REGION_MAP.get(cat_name, ("CustomRegion", None))

        region = ET.SubElement(page_el, f"{{{PAGE_NS}}}{tag}")
        region.set("id", f"r_{idx}")
        if rtype:
            region.set("type", rtype)
        region.set("custom", f"structure {{type:{cat_name};}}")

        coords = ET.SubElement(region, f"{{{PAGE_NS}}}Coords")
        seg = ann.get("segmentation", [])
        if seg and isinstance(seg[0], list) and len(seg[0]) >= 4:
            coords.set("points", _seg_to_points(seg[0]))
        elif ann.get("bbox"):
            coords.set("points", _bbox_to_points(ann["bbox"]))

    # Pretty-print
    ET.indent(root, space="  ")

    xml_body = ET.tostring(root, encoding="unicode")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + xml_body
