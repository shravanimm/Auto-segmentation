from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.chart.data import CategoryChartData
from pptx.enum.chart import XL_CHART_TYPE, XL_LEGEND_POSITION, XL_LABEL_POSITION

SRC = r"C:\Users\ad51324\Downloads\Model Performance RCA (4).pptx"
OUT = r"C:\Users\ad51324\Downloads\RM-CRD Integration v4.pptx"

BLUE = RGBColor(0x07, 0x66, 0xD1)
NAVY = RGBColor(0x03, 0x29, 0x54)
TINT = RGBColor(0xEE, 0xF5, 0xFE)
LBLUE = RGBColor(0xC4, 0xDE, 0xFD)
GREY = RGBColor(0x7E, 0x88, 0x9A)
TEXT = RGBColor(0x1F, 0x2A, 0x37)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
TITLEGREY = RGBColor(0x59, 0x59, 0x59)

prs = Presentation(SRC)
lst = prs.slides._sldIdLst
for s in list(lst):
    prs.part.drop_rel(s.rId)
    lst.remove(s)

L = {l.name: l for l in prs.slide_layouts}
X0, W = 1.38, 17.25


def rr(sl, x, y, w, h, fill=TINT, adj=0.08, line=None, shape=MSO_SHAPE.ROUNDED_RECTANGLE):
    s = sl.shapes.add_shape(shape, Inches(x), Inches(y), Inches(w), Inches(h))
    if shape == MSO_SHAPE.ROUNDED_RECTANGLE:
        s.adjustments[0] = adj
    if fill is None:
        s.fill.background()
    else:
        s.fill.solid()
        s.fill.fore_color.rgb = fill
    if line is None:
        s.line.fill.background()
    else:
        s.line.color.rgb = line
        s.line.width = Pt(1)
    s.shadow.inherit = False
    return s


def tb(sl, x, y, w, h, paras, size=15, color=TEXT, bold=False, italic=False, align=PP_ALIGN.LEFT,
       anchor=MSO_ANCHOR.TOP, space=0):
    """paras: str or list of str / (str, dict) ; dict may override size,color,bold,italic"""
    t = sl.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = t.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    tf.vertical_anchor = anchor
    if isinstance(paras, str):
        paras = [paras]
    for i, p in enumerate(paras):
        o = {}
        if isinstance(p, tuple):
            p, o = p
        para = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        para.alignment = o.get("align", align)
        if space:
            para.space_after = Pt(space)
        r = para.add_run()
        r.text = p
        f = r.font
        f.size = Pt(o.get("size", size))
        f.bold = o.get("bold", bold)
        f.italic = o.get("italic", italic)
        f.color.rgb = o.get("color", color)
    return t


def new_slide(title, subtitle=None, chip=None, notes=None):
    sl = prs.slides.add_slide(L["SAS - Title Only"])
    sl.shapes.title.text = title
    for r in sl.shapes.title.text_frame.paragraphs[0].runs:
        r.font.size = Pt(48)
        r.font.color.rgb = TITLEGREY
    if subtitle:
        tb(sl, X0, 1.7, 15.5, 0.4, subtitle, size=19, bold=True, color=RGBColor(0, 0, 0))
    if chip:
        rr(sl, 16.3, 0.3, 2.33, 0.42, fill=TINT, adj=0.5)
        tb(sl, 16.3, 0.3, 2.33, 0.42, chip, size=12, bold=True, color=BLUE, align=PP_ALIGN.CENTER,
           anchor=MSO_ANCHOR.MIDDLE)
    if notes:
        sl.notes_slide.notes_text_frame.text = notes
    return sl


def pill(sl, x, y, w, h, text, fill=BLUE, color=WHITE, size=14, bold=True):
    rr(sl, x, y, w, h, fill=fill, adj=0.5)
    tb(sl, x, y, w, h, text, size=size, bold=bold, color=color, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)


def circle(sl, x, y, d, label, fill=BLUE, size=20):
    s = rr(sl, x, y, d, d, fill=fill, shape=MSO_SHAPE.OVAL)
    tb(sl, x, y, d, d, label, size=size, bold=True, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)


def arrow(sl, x, y, w=0.3, h=0.3, color=BLUE):
    rr(sl, x, y, w, h, fill=color, shape=MSO_SHAPE.RIGHT_ARROW)


def status(sl, x, y, w, kind):
    if kind == "done":
        pill(sl, x, y, w, 0.42, "DONE", fill=BLUE, size=12)
    elif kind == "prog":
        pill(sl, x, y, w, 0.42, "IN PROGRESS", fill=LBLUE, color=NAVY, size=12)
    else:
        pill(sl, x, y, w, 0.42, "OPEN", fill=GREY, size=12)


# ------------------------------------------------------------------ 1 title
sl = prs.slides.add_slide(L["SAS - Title"])
sl.shapes.title.text = "RM-CRD Integration"
for ph in sl.placeholders:
    i = ph.placeholder_format.idx
    if i == 10:
        ph.text = "From a Risk Modeling scorecard to a CRD decision, and back to monitoring"
    if i == 11:
        ph.text = "Shravani Madiwale"
sl.notes_slide.notes_text_frame.text = (
    "Short intro, one picture of the journey, then straight into the demo.")

# ------------------------------------------------------------------ 2 journey
sl = new_slide("The Integration Journey",
               "One scorecard, built in Risk Modeling, deciding applications in CRD, with every decision returned to RM",
               "OVERVIEW",
               "Walk left to right, then go straight to the demo. Steps 1 to 5 work; step 6 is being built.")
rr(sl, X0, 2.45, W, 0.9, fill=NAVY, adj=0.2)
tb(sl, X0, 2.45, W, 0.9, "Build in RM   ·   Decide in CRD   ·   Learn back in RM", size=20, color=WHITE,
   align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
cards = [
    ("Data prep", "Retail loan applications",
     ["Flexible: works with the bank's own application data", "Applications and outcomes kept together"], "done"),
    ("Model", "RM user-defined scorecard",
     ["Simple point-and-click interface", "Points per answer, one total score", "No coding needed"], "done"),
    ("Publish", "Registered in Model Manager",
     ["Register the scorecard once", "Available to any decision flow", "No code copied across"], "done"),
    ("Decide", "CRD decision flow",
     ["Model-based scoring, not static policy rules", "One switch: RM model or standard rules", "Approve, refer or reject, with score and offer"], "done"),
    ("Record", "Decision records",
     ["Every decision is saved", "With the time and the score", "Can be read back for analysis"], "done"),
    ("Model Monitoring", "Back into RM",
     ["Decisions become data in RM", "KPIs and a monitoring plan", "Being built now"], "prog"),
]
cw, gap = 2.6, 0.33
for i, (t, sub, bl, st) in enumerate(cards):
    x = X0 + i * (cw + gap)
    rr(sl, x, 3.65, cw, 6.0, fill=TINT, adj=0.06)
    circle(sl, x + 0.3, 3.95, 0.85, str(i + 1), size=22)
    tb(sl, x + 0.3, 5.1, cw - 0.5, 0.4, t, size=19, bold=True, color=NAVY)
    tb(sl, x + 0.3, 5.65, cw - 0.5, 0.7, sub, size=14, italic=True, color=BLUE)
    tb(sl, x + 0.3, 6.6, cw - 0.5, 2.3, ["›  " + b for b in bl], size=14, color=TEXT, space=6)
    status(sl, x + 0.3, 8.9, cw - 0.6, st)
    if i < 5:
        arrow(sl, x + cw + 0.03, 6.45, 0.27, 0.27)
rr(sl, X0, 9.85, W, 0.65, fill=GREY, adj=0.25)
tb(sl, X0, 9.85, W, 0.65, "Built on synthetic data in a SAS Viya test environment   ·   Nothing is production", size=16,
   color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

# ------------------------------------------------------------------ 12 closing
sl = prs.slides.add_slide(L["SAS - Closing"])
sl.shapes.title.text = "Questions and discussion"

prs.save(OUT)
print("saved", OUT, len(prs.slides))
