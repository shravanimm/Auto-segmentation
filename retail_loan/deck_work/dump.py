import sys
from pptx import Presentation
from pptx.util import Emu
p=Presentation(sys.argv[1])
print("size",p.slide_width/914400,p.slide_height/914400,"slides",len(p.slides))
for i,s in enumerate(p.slides,1):
    print("=== slide",i,s.slide_layout.name)
    for sh in s.shapes:
        t=sh.text_frame.text[:90].replace("\n"," | ") if sh.has_text_frame else ""
        f=""
        if sh.has_text_frame and sh.text_frame.paragraphs and sh.text_frame.paragraphs[0].runs:
            r=sh.text_frame.paragraphs[0].runs[0]; f=f"{r.font.name},{r.font.size.pt if r.font.size else None}"
        print(" ",sh.shape_type,sh.name,round(sh.left/914400,2) if sh.left is not None else None,round(sh.top/914400,2) if sh.top is not None else None,round(sh.width/914400,2) if sh.width else None,round(sh.height/914400,2) if sh.height else None,f,t)
