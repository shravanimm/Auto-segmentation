import sys,re
from pptx import Presentation
p=Presentation(sys.argv[1])
for l in p.slide_layouts:
    print("LAYOUT",l.name,[ (ph.placeholder_format.idx,ph.placeholder_format.type,ph.name,round(ph.left/914400,2),round(ph.top/914400,2),round(ph.width/914400,2),round(ph.height/914400,2)) for ph in l.placeholders])
s=p.slides[3]
from lxml import etree
x=etree.tostring(s._element,pretty_print=True).decode()
print(set(re.findall(r'srgbClr val="(\w+)"',x)), set(re.findall(r'typeface="([^"]+)"',x)), set(re.findall(r'schemeClr val="(\w+)"',x)))
for sh in list(s.shapes)[:12]:
    print(etree.tostring(sh._element,pretty_print=True).decode()[:1800]); print('-----')
th=[r for r in p.part.package.iter_parts() if 'theme' in str(r.partname)]
import zipfile
z=zipfile.ZipFile(sys.argv[1]); t=z.read('ppt/theme/theme1.xml').decode()
print(re.findall(r'<a:(dk1|lt1|dk2|lt2|accent\d)>.*?val="(\w+)"',t)); print(re.findall(r'<a:(?:major|minor)Font><a:latin typeface="([^"]+)"',t))
