from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.chart.data import CategoryChartData
from pptx.enum.chart import XL_CHART_TYPE, XL_LEGEND_POSITION, XL_LABEL_POSITION

SRC = r"C:\Users\ad51324\Downloads\Model Performance RCA (4).pptx"
OUT = r"C:\Users\ad51324\Downloads\RM-CRD Integration v2.pptx"

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
    "Demo for the principal and senior product managers. Story: where the data came from (RLA), the scorecard we built "
    "in Risk Modeling, how CRD calls it as a scoring node, and how we are closing the loop so decisions flow back to RM.")

# ------------------------------------------------------------------ 2 journey
sl = new_slide("The Integration Journey",
               "One scorecard, built in Risk Modeling, deciding applications in CRD, with every decision returned to RM",
               "OVERVIEW",
               "Walk left to right. Steps 1 to 4 are built and tested end to end. Step 5 works on a published flow. "
               "Step 6 is what we are building now.")
rr(sl, X0, 2.45, W, 0.9, fill=NAVY, adj=0.2)
tb(sl, X0, 2.45, W, 0.9, "Build in RM   ·   Decide in CRD   ·   Learn back in RM", size=20, color=WHITE,
   align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
cards = [
    ("Data", "Retail loan applications",
     ["50,000 synthetic applications", "RM data source and data set", "Real customer and application keys"], "done"),
    ("Model", "RM user-defined scorecard",
     ["AGE, bureau score, dependants", "Bins and points, one total score", "Built in Risk Modeling"], "done"),
    ("Deploy", "Registered in Model Manager",
     ["Scorecard NewUDCRD--13", "Available to decision flows", "No code copied across"], "done"),
    ("Decide", "CRD 4.1 decision flow",
     ["Model node runs the scorecard", "useUDModel switch: RM or rules", "Tested on 300 applications"], "done"),
    ("Record", "Decision records",
     ["Record contacts node", "Saved per decision, with time", "Read back through REST"], "done"),
    ("Monitor", "Back into RM",
     ["Decision history as RM data", "KPIs and a monitoring plan", "Being built now"], "prog"),
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

# ------------------------------------------------------------------ 3 data
sl = new_slide("The Data in Risk Modeling",
               "Synthetic retail loan applications (RLA), made visible to RM through its shared application table",
               "DATA",
               "RLA is synthetic. RM builds its population from the shared ALL_APPLICATION_DIM table, which only had 2010 to 2013 data, so we appended our 50,000 applications to it. "
               "The full applicant detail stays in RLA and is linked by application key. We added customer and applicant keys so decisions can be joined back later.")
stats = [("50,000", "synthetic applications in RLA"), ("111", "columns per application in RLA"),
         ("77,887", "rows in ALL_APPLICATION_DIM: 27,887 old plus our 50,000"), ("4,717", "records in the RM build (Dec 31, 2024)")]
for i, (n, lab) in enumerate(stats):
    y = 2.45 + i * 1.9
    rr(sl, X0, y, 5.2, 1.7, fill=TINT, adj=0.1)
    tb(sl, X0 + 0.35, y + 0.15, 4.6, 0.9, n, size=48, bold=True, color=BLUE)
    tb(sl, X0 + 0.35, y + 1.05, 4.6, 0.5, lab, size=15, color=TEXT)
steps = [
    ("Load", "Generated CSV loaded into CAS as BANKCRFM.RETAIL_LOAN_APPLICATIONS. Date text converted to SAS datetimes; RM-style keys (*_RK) and valid-from date added."),
    ("Make it visible to RM", "RM reads its application population from the shared table ALL_APPLICATION_DIM, which held only 2010 to 2013. We appended all 50,000 applications in its layout (keys, dates, outcome, amount, channel)."),
    ("Data source and variables", "Point-in-time data source on APPLICATION_DT with a valid-from date. About 100 variables created from Excel uploads, plus generated age, gender and a REJECT_FLG target."),
    ("Data set and keys", "RLA_APPLICATION, Dec 31, 2024 full build. Later added customer_rk, applicant_rk and an application timestamp so a CRD decision can be joined back."),
]
for i, (t, d) in enumerate(steps):
    y = 2.45 + i * 1.9
    rr(sl, 7.0, y, 11.63, 1.7, fill=WHITE, adj=0.1, line=LBLUE)
    circle(sl, 7.3, y + 0.4, 0.85, str(i + 1), size=22)
    tb(sl, 8.5, y + 0.2, 9.8, 0.4, t, size=19, bold=True, color=NAVY)
    tb(sl, 8.5, y + 0.7, 9.8, 0.9, d, size=15, color=TEXT)

# ------------------------------------------------------------------ 4 scorecard
sl = new_slide("The Scorecard in Risk Modeling",
               "A user-defined scorecard, registered in Model Manager, using three inputs CRD already supplies",
               "MODEL",
               "We kept the model deliberately small so every input exists as a flat variable in the CRD flow. "
               "Higher points mean lower risk. The scorecard returns the total plus points and bin group per variable.")
cols = [
    ("AGE", "Age of primary applicant", [("up to 18", "10"), ("18 – 30", "20"), ("30 – 40", "30"), ("40 – 50", "45"),
                                         ("50 – 60", "40"), ("over 60", "10"), ("missing", "0")]),
    ("BUREAU_SCORE", "Primary bureau score", [("300 – 600", "50"), ("600 – 630", "93"), ("630 – 650", "135"),
                                              ("650 – 720", "199"), ("720 – 850", "220"), ("other / missing", "0")]),
    ("DEPENDANTS", "Number of dependants", [("0 – 1", "10"), ("2", "25"), ("3 – 4", "20"), ("other / missing", "5")]),
]
cw = 5.55
for i, (nm, sub, rows) in enumerate(cols):
    x = X0 + i * (cw + 0.3)
    rr(sl, x, 2.45, cw, 5.9, fill=TINT, adj=0.05)
    tb(sl, x + 0.35, 2.7, cw - 0.7, 0.4, nm, size=19, bold=True, color=NAVY)
    tb(sl, x + 0.35, 3.2, cw - 0.7, 0.4, sub, size=14, italic=True, color=BLUE)
    tb(sl, x + 0.35, 3.85, 2.5, 0.3, "BIN", size=12, bold=True, color=GREY)
    tb(sl, x + cw - 2.35, 3.85, 2.0, 0.3, "POINTS", size=12, bold=True, color=GREY, align=PP_ALIGN.RIGHT)
    for j, (b, p) in enumerate(rows):
        y = 4.3 + j * 0.57
        tb(sl, x + 0.35, y, 3.2, 0.4, b, size=15, color=TEXT)
        tb(sl, x + cw - 2.35, y, 2.0, 0.4, p, size=15, bold=True, color=NAVY, align=PP_ALIGN.RIGHT)
rr(sl, X0, 8.65, W, 0.95, fill=NAVY, adj=0.2)
tb(sl, X0, 8.65, W, 0.95, "Output: SCORECARD_POINTS (total score)   ·   plus points and bin group per variable",
   size=19, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
tb(sl, X0, 9.9, W, 0.4,
   "This 3-input version (NewUDCRD--13) is the one CRD calls. The full 11-variable scorecard, RLA_UD_MODEL2 (scores 265 to 850), was built and taken through the lifecycle in RM.",
   size=14, italic=True, color=GREY)

# ------------------------------------------------------------------ 5 CRD flow
sl = new_slide("Calling the Scorecard from CRD",
               "The CRD 4.1 application scorecard step now runs the RM model through a Model node",
               "DECISION FLOW",
               "The branch lets us run the RM model or the original CRD rule sets from the same flow, controlled by one variable, "
               "useUDModel. The model output feeds the same variable the rest of CRD already uses, so nothing downstream changed.")
stages = ["Intake", "Data quality", "Eligibility", "Credit policy", "Application scorecard", "Risk segment",
          "Affordability", "Pricing"]
sw, sg = 1.98, 0.2
for i, s in enumerate(stages):
    x = X0 + i * (sw + sg)
    hi = (i == 4)
    rr(sl, x, 2.45, sw, 1.0, fill=BLUE if hi else TINT, adj=0.2)
    tb(sl, x + 0.08, 2.45, sw - 0.16, 1.0, s, size=14, bold=True, color=WHITE if hi else NAVY,
       align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
tb(sl, X0, 3.65, W, 0.35, "CRD stages, in order. The RM model sits at the application scorecard step (CRD 4.1).",
   size=14, italic=True, color=GREY)
# left: branch
rr(sl, X0, 4.25, 8.4, 5.9, fill=TINT, adj=0.04)
tb(sl, X0 + 0.35, 4.45, 7.7, 0.4, "Inside CRD 4.1", size=19, bold=True, color=NAVY)
rr(sl, X0 + 2.5, 5.1, 3.4, 0.85, fill=NAVY, adj=0.2)
tb(sl, X0 + 2.5, 5.1, 3.4, 0.85, "UseModel branch\nuseUDModel = ?", size=15, bold=True, color=WHITE,
   align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
rr(sl, X0 + 0.35, 6.75, 3.55, 1.6, fill=BLUE, adj=0.12)
tb(sl, X0 + 0.5, 6.75, 3.25, 1.6, ["YES  (default)", ("Model node runs RM scorecard NewUDCRD--13", {"size": 14, "bold": False})],
   size=16, bold=True, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, space=4)
rr(sl, X0 + 4.5, 6.75, 3.55, 1.6, fill=WHITE, adj=0.12, line=LBLUE)
tb(sl, X0 + 4.65, 6.75, 3.25, 1.6, ["NO", ("Original rule sets 4.2.1 to 4.2.9 and the sum code, unchanged", {"size": 14, "bold": False})],
   size=16, bold=True, color=NAVY, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, space=4)
rr(sl, X0 + 1.9, 6.1, 0.3, 0.45, fill=BLUE, shape=MSO_SHAPE.DOWN_ARROW)
rr(sl, X0 + 6.2, 6.1, 0.3, 0.45, fill=BLUE, shape=MSO_SHAPE.DOWN_ARROW)
rr(sl, X0 + 1.9, 8.45, 0.3, 0.45, fill=BLUE, shape=MSO_SHAPE.DOWN_ARROW)
rr(sl, X0 + 6.2, 8.45, 0.3, 0.45, fill=BLUE, shape=MSO_SHAPE.DOWN_ARROW)
rr(sl, X0 + 0.35, 9.05, 7.7, 0.8, fill=WHITE, adj=0.2, line=LBLUE)
tb(sl, X0 + 0.35, 9.05, 7.7, 0.8, "Either way the score lands in AppScoreCard_Score", size=15, bold=True, color=NAVY,
   align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
# right: mapping
rr(sl, 10.0, 4.25, 8.63, 5.9, fill=WHITE, adj=0.04, line=LBLUE)
tb(sl, 10.35, 4.45, 7.9, 0.4, "How the model is wired in", size=19, bold=True, color=NAVY)
tb(sl, 10.35, 5.05, 3.5, 0.3, "MODEL INPUT", size=12, bold=True, color=GREY)
tb(sl, 14.3, 5.05, 3.9, 0.3, "CRD DECISION VARIABLE", size=12, bold=True, color=GREY)
maps = [("AGE", "_AgePrimaryApplicant"), ("BUREAU_SCORE", "_primary_bureau_score"), ("DEPENDANTS", "_primary_dependents")]
for i, (a, b) in enumerate(maps):
    y = 5.5 + i * 0.7
    pill(sl, 10.35, y, 3.2, 0.5, a, fill=TINT, color=NAVY, size=14)
    arrow(sl, 13.75, y + 0.1, 0.35, 0.3)
    tb(sl, 14.3, y, 4.1, 0.5, b, size=14, color=TEXT, anchor=MSO_ANCHOR.MIDDLE)
tb(sl, 10.35, 7.75, 3.5, 0.3, "MODEL OUTPUT", size=12, bold=True, color=GREY)
pill(sl, 10.35, 8.15, 3.2, 0.5, "SCORECARD_POINTS", fill=TINT, color=NAVY, size=14)
arrow(sl, 13.75, 8.25, 0.35, 0.3)
tb(sl, 14.3, 8.15, 4.1, 0.5, "AppScoreCard_Score", size=14, color=TEXT, anchor=MSO_ANCHOR.MIDDLE)
tb(sl, 10.35, 8.95, 7.9, 1.0,
   "Six side outputs (points and bin group per variable) are kept as internal variables for explanation and later monitoring.",
   size=14, italic=True, color=GREY)

# ------------------------------------------------------------------ 6 test results
sl = new_slide("Running It End to End",
               "300 RLA applications through the full CRD flow: every application that reached the scorecard was scored",
               "TEST RESULTS",
               "Rows reaching the scorecard got a score. 54 stopped earlier at data-quality checks, which is expected: "
               "38 had a monthly payment above monthly income, 16 had worst delinquency over policy, both real in the data. "
               "RLA outcomes are synthetic, so agreement with history is a sanity check, not a measure of accuracy.")
rr(sl, X0, 2.45, 8.9, 7.7, fill=WHITE, adj=0.03, line=LBLUE)
tb(sl, X0 + 0.35, 2.65, 8.2, 0.4, "CRD decision (share of applications), by outcome in RLA history", size=17, bold=True, color=NAVY)
cd = CategoryChartData()
cd.categories = ["Rejected (45)", "Referred (29)", "Cond. approved (45)", "Approved (181)"]
cd.add_series("CRD approve", (4, 3, 6, 33))
cd.add_series("CRD refer", (0, 3, 0, 13))
cd.add_series("CRD reject", (41, 23, 39, 135))
gf = sl.shapes.add_chart(XL_CHART_TYPE.BAR_STACKED_100, Inches(X0 + 0.25), Inches(3.2), Inches(8.4), Inches(6.7), cd)
ch = gf.chart
ch.has_legend = True
ch.legend.position = XL_LEGEND_POSITION.BOTTOM
ch.legend.include_in_layout = False
ch.legend.font.size = Pt(14)
ch.legend.font.color.rgb = TEXT
for ser, col in zip(ch.plots[0].series, (BLUE, LBLUE, NAVY)):
    ser.format.fill.solid()
    ser.format.fill.fore_color.rgb = col
pl = ch.plots[0]
pl.gap_width = 55
pl.overlap = 100
pl.has_data_labels = True
dl = pl.data_labels
dl.font.size = Pt(14)
dl.font.color.rgb = WHITE
dl.position = XL_LABEL_POSITION.CENTER
dl.show_value = True
vals = {0: (4, 3, 6, 33), 1: (0, 3, 0, 13), 2: (41, 23, 39, 135)}
tot = (45, 29, 45, 181)
for si, ser in enumerate(ch.plots[0].series):
    for pi in range(4):
        v = vals[si][pi]
        dlb = ser.points[pi].data_label
        tf = dlb.text_frame
        if v / tot[pi] >= 0.12:
            tf.text = str(v)
            r = tf.paragraphs[0].runs[0]
            r.font.size = Pt(14)
            r.font.color.rgb = NAVY if si == 1 else WHITE
        else:
            tf.text = ""
        dlb.position = XL_LABEL_POSITION.CENTER
ch.category_axis.tick_labels.font.size = Pt(14)
ch.category_axis.tick_labels.font.color.rgb = TEXT
ch.category_axis.format.line.fill.background()
ch.value_axis.visible = False
ch.value_axis.has_major_gridlines = False
tiles = [("300", "applications run through the flow"), ("246", "reached the scorecard and got a score"),
         ("46 / 16 / 238", "approve / refer / reject"), ("300 of 300", "join back to RLA on application, applicant and customer keys")]
for i, (n, lab) in enumerate(tiles):
    y = 2.45 + i * 1.95
    rr(sl, 10.5, y, 8.13, 1.75, fill=TINT, adj=0.1)
    tb(sl, 10.85, y + 0.15, 7.5, 0.8, n, size=36, bold=True, color=BLUE)
    tb(sl, 10.85, y + 1.0, 7.5, 0.6, lab, size=15, color=TEXT)
tb(sl, X0, 10.3, W, 0.4,
   "54 applications stopped earlier at data-quality checks, so they have no score. RLA outcomes are synthetic: agreement with history is a sanity check, not accuracy.",
   size=14, italic=True, color=GREY)

# ------------------------------------------------------------------ 7 closing the loop: capture
sl = new_slide("Closing the Loop: Capturing Decisions",
               "CRD decides one application at a time and keeps no decision history, so we have to capture it",
               "FEEDBACK LOOP",
               "This is the part the team asked about: how do decisions get back to RM when CRD processes one application at a time. "
               "Answer: publish the flow to the real-time engine (MAS); the Record contacts node then writes each decision to the "
               "subject contact database, which can be read through REST and flattened into a table for RM.")
tb(sl, X0, 2.4, W, 0.35, "THE CHALLENGE", size=16, bold=True, color=NAVY)
ch3 = [("One at a time", "Each request is scored on its own. RM needs many decisions together."),
       ("No decision store", "CRD itself has no database. The response is returned and not kept."),
       ("Tests are not enough", "Scoring tests only leave output tables in CAS. They do not write decision records.")]
cw = 5.55
for i, (t, d) in enumerate(ch3):
    x = X0 + i * (cw + 0.3)
    rr(sl, x, 2.9, cw, 2.2, fill=WHITE, adj=0.08, line=LBLUE)
    tb(sl, x + 0.35, 3.1, cw - 0.7, 0.4, t, size=19, bold=True, color=NAVY)
    tb(sl, x + 0.35, 3.75, cw - 0.7, 1.2, d, size=15, color=TEXT)
tb(sl, X0, 5.45, W, 0.35, "HOW WE CAPTURE IT", size=16, bold=True, color=NAVY)
flow = [("Publish flow", "Decision flow published to the real-time engine (MAS)"),
        ("Record contacts", "Node writes one record per decision"),
        ("Subject contacts", "Records held in the subject contact database"),
        ("Read via REST", "Subject contacts REST service"),
        ("Flatten", "One row per decision, one column per field"),
        ("Decision history", "One table in CAS that RM can use")]
fw, fg = 2.5, 0.45
for i, (t, d) in enumerate(flow):
    x = X0 + i * (fw + fg)
    last = (i == 5)
    rr(sl, x, 5.95, fw, 2.9, fill=BLUE if last else TINT, adj=0.08)
    tb(sl, x + 0.25, 6.15, fw - 0.5, 0.8, t, size=17, bold=True, color=WHITE if last else NAVY)
    tb(sl, x + 0.25, 7.05, fw - 0.5, 1.7, d, size=15, color=WHITE if last else TEXT)
    if i < 5:
        arrow(sl, x + fw + 0.07, 7.25, 0.31, 0.3)
rr(sl, X0, 9.2, W, 0.95, fill=NAVY, adj=0.2)
tb(sl, X0, 9.2, W, 0.95,
   "Each decision becomes a row keyed by application ID, with the decision time stamped by the service",
   size=17, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

# ------------------------------------------------------------------ 8 record contents
sl = new_slide("What a Decision Record Contains",
               "Each record carries the decision, the score and the offer, which is what RM needs to join back to the application",
               "THE DATA",
               "The subject id is the application id, so it joins straight to application_rk in RLA. We confirmed on the published flow "
               "that decisions match the batch test for the applications we tried (120506 stopped at a data-quality check, 124788 rejected).")
rr(sl, X0, 2.45, 10.6, 7.7, fill=TINT, adj=0.03)
tb(sl, X0 + 0.35, 2.65, 5, 0.3, "FIELD", size=12, bold=True, color=GREY)
tb(sl, X0 + 4.35, 2.65, 5.5, 0.3, "WHAT IT TELLS US", size=12, bold=True, color=GREY)
rec = [("subjectId", "Application ID, joins to RLA application_rk"),
       ("creationTimeStamp", "When the decision was made (UTC)"),
       ("ApplicationCurrentStatus", "Approve, refer or reject"),
       ("ApplicationScore", "RM scorecard points"),
       ("_RiskSegment", "Risk segment from the score"),
       ("_ApprovedAmount / Rate / Term", "The offer from pricing"),
       ("ErrorCode", "Why an application stopped early"),
       ("ApplicationDate", "Application month, for monthly analysis"),
       ("channel, flow revision", "Source channel and flow version")]
for i, (f, d) in enumerate(rec):
    y = 3.15 + i * 0.77
    tb(sl, X0 + 0.35, y, 3.9, 0.6, f, size=14, bold=True, color=NAVY, anchor=MSO_ANCHOR.MIDDLE)
    tb(sl, X0 + 4.35, y, 5.9, 0.6, d, size=14, color=TEXT, anchor=MSO_ANCHOR.MIDDLE)
rr(sl, 12.3, 2.45, 6.33, 3.6, fill=NAVY, adj=0.05)
tb(sl, 12.65, 2.65, 5.6, 0.4, "WORKING", size=14, bold=True, color=LBLUE)
tb(sl, 12.65, 3.2, 5.6, 2.7,
   ["Published flow gives the same decision as the batch test (checked on two applications)",
    "Records readable through REST and flattened to a table"], size=17, color=WHITE, space=14)
rr(sl, 12.3, 6.3, 6.33, 3.85, fill=WHITE, adj=0.05, line=LBLUE)
tb(sl, 12.65, 6.5, 5.6, 0.4, "NOT IN THE RECORD YET", size=14, bold=True, color=GREY)
tb(sl, 12.65, 7.05, 5.6, 3.0,
   ["›  Model name and version, needed to monitor by model",
    "›  Loan performance (default or delinquency), needed for outcome-based monitoring"], size=17, color=TEXT, space=14)

# ------------------------------------------------------------------ 9 using in RM
sl = new_slide("Using the Decisions in Risk Modeling",
               "The decision history becomes another RM data source, so scorecard behaviour can be monitored on real decisions",
               "MONITORING",
               "This is the step we are building now. The plan: register the decision history as an RM data source, create variables from it "
               "in a new data set, then define KPIs and a monitoring plan. KPI definitions are still to be agreed.")
cols = [
    ("1", "Register the data", "Decision history as an RM data source",
     ["Keys: application and customer", "Valid-from = decision time", "Linked to RLA by application key"]),
    ("2", "Create variables", "In a new data set, not RLA",
     ["CRD_STATUS, CRD_SCORE", "CRD_RISK_SEGMENT", "CRD_APPROVED_AMT, CRD_ERROR_CODE"]),
    ("3", "Analyse and monitor", "KPIs and a monitoring plan",
     ["Approved and rejected per application month", "Score distribution in decisions vs development", "KPI definitions to be agreed"]),
]
cw = 5.55
for i, (n, t, sub, bl) in enumerate(cols):
    x = X0 + i * (cw + 0.3)
    rr(sl, x, 2.45, cw, 5.7, fill=TINT, adj=0.05)
    circle(sl, x + 0.35, 2.75, 0.9, n, size=24)
    tb(sl, x + 0.35, 3.9, cw - 0.7, 0.4, t, size=19, bold=True, color=NAVY)
    tb(sl, x + 0.35, 4.5, cw - 0.7, 0.4, sub, size=15, italic=True, color=BLUE)
    tb(sl, x + 0.35, 5.2, cw - 0.7, 2.2, ["›  " + b for b in bl], size=17, color=TEXT, space=10)
    status(sl, x + 0.35, 7.45, 2.0, "prog")
rr(sl, X0, 8.4, W, 0.9, fill=NAVY, adj=0.2)
tb(sl, X0, 8.4, W, 0.9, "First showcase: how many applications were approved and rejected in each month",
   size=19, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
rr(sl, X0, 9.55, W, 0.8, fill=WHITE, adj=0.2, line=LBLUE)
tb(sl, X0 + 0.35, 9.55, W - 0.7, 0.8,
   "Current limit: RLA holds application outcomes but no loan performance, so default-based KPIs need a performance feed.",
   size=15, italic=True, color=NAVY, anchor=MSO_ANCHOR.MIDDLE)

# ------------------------------------------------------------------ 10 status
sl = new_slide("Where We Are",
               "The path from data to decision works end to end; the return path is being built",
               "STATUS",
               "Left column is complete. Middle is this week's work. Right are the open points we would like help shaping.")
colsd = [
    ("Done", "done", ["RLA data and keys in RM", "RM scorecard built and registered", "CRD 4.1 calls the scorecard, switchable",
                      "300-application end-to-end test", "Decisions captured through the published flow"]),
    ("In progress", "prog", ["Decision history table", "RM data source and variables on it", "KPIs and monitoring plan",
                             "Run many applications through the published flow"]),
    ("Open points", "open", ["Model name and version missing from records", "Offer amount rounded to the thousand in the published flow",
                             "Cirrus object posting needs a Cirrus URL", "Mapping RLA products to CRD products",
                             "No loan performance in RLA"]),
]
cw = 5.55
for i, (t, k, items) in enumerate(colsd):
    x = X0 + i * (cw + 0.3)
    rr(sl, x, 2.45, cw, 6.1, fill=TINT if k != "open" else WHITE, adj=0.04, line=None if k != "open" else LBLUE)
    status(sl, x + 0.35, 2.75, 2.0, k)
    tb(sl, x + 0.35, 3.45, cw - 0.7, 0.4, t, size=22, bold=True, color=NAVY)
    tb(sl, x + 0.35, 4.3, cw - 0.7, 4.2, ["›  " + s for s in items], size=16, color=TEXT, space=12)
rr(sl, X0, 8.85, W, 1.1, fill=NAVY, adj=0.2)
tb(sl, X0, 8.85, W, 1.1, "Data to decision: working end to end   ·   Decision back to RM: captured, monitoring being built", size=19, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

# ------------------------------------------------------------------ 11 feedback
sl = new_slide("Where We Would Like Your Input",
               "How should this effort be shaped: demo asset, product feature, or both?",
               "DISCUSSION",
               "Four questions. The first is the main one: whether to package this as a demo asset or surface it as a product capability "
               "(a built-in decision feedback feed from CRD into RM).")
qs = [("Demo asset or product feature?", "A packaged RM-CRD demo, or a built-in way to feed CRD decisions into RM."),
      ("What should be captured?", "Should the decision record include model name and version as standard, so RM can monitor by model?"),
      ("What should RM monitor?", "Decision mix, score stability, overrides, and outcomes once performance data exists."),
      ("Where does performance data come from?", "Outcome-based monitoring needs defaults or delinquency tied back to the application.")]
for i, (t, d) in enumerate(qs):
    y = 2.45 + i * 1.95
    rr(sl, X0, y, 10.8, 1.75, fill=TINT, adj=0.1)
    circle(sl, X0 + 0.3, y + 0.45, 0.85, str(i + 1), size=22)
    tb(sl, X0 + 1.5, y + 0.2, 9.0, 0.4, t, size=19, bold=True, color=NAVY)
    tb(sl, X0 + 1.5, y + 0.75, 9.0, 0.9, d, size=16, color=TEXT)
rr(sl, 12.5, 2.45, 6.13, 7.55, fill=NAVY, adj=0.05)
tb(sl, 12.85, 2.7, 5.4, 0.4, "NEXT STEPS", size=14, bold=True, color=LBLUE)
tb(sl, 12.85, 3.3, 5.4, 6.5,
   ["›  Finish the decision history and register it in RM", "›  Agree KPIs and the monitoring plan",
    "›  Run the full set of applications through the published flow",
    "›  Reuse the decision history as input to root cause analysis for decisions (second topic today)"],
   size=18, color=WHITE, space=18)

# ------------------------------------------------------------------ 12 closing
sl = prs.slides.add_slide(L["SAS - Closing"])
sl.shapes.title.text = "Questions and discussion"

prs.save(OUT)
print("saved", OUT, len(prs.slides))
