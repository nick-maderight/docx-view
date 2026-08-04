#!/usr/bin/env python3
"""Generate Word-faithful .docx fixtures exercising every OOXML revision + comment feature."""
import zipfile, os

NS = ('xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" '
      'xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
      'mc:Ignorable="w14 w15"')

def ct(parts):
    o = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
         '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
         '<Default Extension="xml" ContentType="application/xml"/>',
         '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>']
    m = {'comments':'comments+xml','commentsExtended':'commentsExtended+xml','commentsIds':'commentsIds+xml',
         'people':'people+xml','footnotes':'footnotes+xml','styles':'styles+xml','numbering':'numbering+xml'}
    for p in parts:
        if p in m:
            o.append(f'<Override PartName="/word/{p}.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.{m[p]}"/>')
    o.append('</Types>')
    return '\n'.join(o)

ROOT_RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'''

REL_T = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
def drels(parts, extra=''):
    o = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
         '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">']
    for i, p in enumerate(parts, start=1):
        o.append(f'<Relationship Id="rIdP{i}" Type="{REL_T}{p}" Target="{p}.xml"/>')
    o.append(extra)
    o.append('</Relationships>')
    return '\n'.join(o)

STYLES = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles {NS}>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
</w:styles>'''

def build(name, body, comments=None, cex=None, cids=None, people=None, footnotes=None, extra_rels=''):
    parts, files = [], {}
    if comments is not None: parts.append('comments'); files['word/comments.xml']=comments
    if cex is not None: parts.append('commentsExtended'); files['word/commentsExtended.xml']=cex
    if cids is not None: parts.append('commentsIds'); files['word/commentsIds.xml']=cids
    if people is not None: parts.append('people'); files['word/people.xml']=people
    if footnotes is not None: parts.append('footnotes'); files['word/footnotes.xml']=footnotes
    parts.append('styles'); files['word/styles.xml']=STYLES
    doc = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:document {NS}><w:body>{body}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>'
    with zipfile.ZipFile(name,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', ct(parts))
        z.writestr('_rels/.rels', ROOT_RELS)
        z.writestr('word/document.xml', doc)
        z.writestr('word/_rels/document.xml.rels', drels(parts, extra_rels))
        for k,v in files.items(): z.writestr(k,v)
    return name

def p(inner, pr=''): return f'<w:p>{pr}{inner}</w:p>'
def r(t, rpr=''): return f'<w:r>{rpr}<w:t xml:space="preserve">{t}</w:t></w:r>'
def dr(t): return f'<w:r><w:delText xml:space="preserve">{t}</w:delText></w:r>'
def ins(i,a,d,inner): return f'<w:ins w:id="{i}" w:author="{a}" w:date="{d}">{inner}</w:ins>'
def dele(i,a,d,inner): return f'<w:del w:id="{i}" w:author="{a}" w:date="{d}">{inner}</w:del>'

A,B,C = "Alice Smith","Bob Jones","Carol White"
D1,D2,D3 = "2026-08-01T10:00:00Z","2026-08-02T11:30:00Z","2026-08-03T09:15:00Z"

# ---------- FIXTURE 1: kitchen sink of revisions ----------
body1 = ''.join([
  p(f'<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>{r("Revision Kitchen Sink")}'),
  p(r("An untouched baseline paragraph with no revisions at all.")),
  # insertion + deletion in one para
  p(r("The quick ") + ins(101,A,D1,r("very ")) + dele(102,B,D2,dr("brown ")) + r("fox jumps over the lazy dog.")),
  # substitution: adjacent del+ins (the common Word "replace" idiom)
  p(r("We should ") + dele(103,A,D1,dr("utilise")) + ins(104,A,D1,r("use")) + r(" plain words.")),
  # move
  p(f'<w:moveFromRangeStart w:id="110" w:name="move1" w:author="{A}" w:date="{D3}"/>'
    + f'<w:moveFrom w:id="111" w:author="{A}" w:date="{D3}">{dr("This sentence was moved elsewhere.")}</w:moveFrom>'
    + '<w:moveFromRangeEnd w:id="110"/>'),
  p(r("An intervening paragraph.")),
  p(f'<w:moveToRangeStart w:id="112" w:name="move1" w:author="{A}" w:date="{D3}"/>'
    + f'<w:moveTo w:id="113" w:author="{A}" w:date="{D3}">{r("This sentence was moved elsewhere.")}</w:moveTo>'
    + '<w:moveToRangeEnd w:id="112"/>'),
  # rPrChange: run made bold, was not bold
  p(f'<w:r><w:rPr><w:b/><w:rPrChange w:id="120" w:author="{B}" w:date="{D2}"><w:rPr/></w:rPrChange></w:rPr><w:t>This run was made bold.</w:t></w:r>'),
  # pPrChange: paragraph restyled from Normal to Heading2
  p(f'<w:pPr><w:pStyle w:val="Heading2"/><w:pPrChange w:id="121" w:author="{B}" w:date="{D2}"><w:pPr/></w:pPrChange></w:pPr>{r("This paragraph became a heading")}'),
  # deleted paragraph mark (paragraph merged into next)
  p(r("First half of a merged paragraph."), pr=f'<w:pPr><w:rPr><w:del w:id="130" w:author="{C}" w:date="{D3}"/></w:rPr></w:pPr>'),
  p(r("Second half of a merged paragraph.")),
  # inserted paragraph mark (paragraph split)
  p(r("A paragraph that was split here."), pr=f'<w:pPr><w:rPr><w:ins w:id="131" w:author="{C}" w:date="{D3}"/></w:rPr></w:pPr>'),
  # wholly inserted paragraph
  p(ins(140,C,D3,r("This entire paragraph is new.")), pr=f'<w:pPr><w:rPr><w:ins w:id="141" w:author="{C}" w:date="{D3}"/></w:rPr></w:pPr>'),
  # wholly deleted paragraph
  p(dele(150,B,D2,dr("This entire paragraph was removed.")), pr=f'<w:pPr><w:rPr><w:del w:id="151" w:author="{B}" w:date="{D2}"/></w:rPr></w:pPr>'),
  # list with revisions
  p(r("Bullet one unchanged."), pr='<w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>'),
  p(ins(160,A,D1,r("Bullet two inserted.")), pr='<w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>'),
  # table with cell insert/delete + revised content
  # NOTE: w:tblGrid is REQUIRED - pandoc yields an empty table without it (verified).
  '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>'
  + '<w:tblGrid><w:gridCol w:w="4675"/><w:gridCol w:w="4675"/></w:tblGrid>'
  + '<w:tr><w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/></w:tcPr>' + p(r("Header A")) + '</w:tc><w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/></w:tcPr>' + p(r("Header B")) + '</w:tc></w:tr>'
  + '<w:tr><w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/></w:tcPr>' + p(r("plain cell")) + '</w:tc><w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/></w:tcPr>' + p(ins(170,A,D1,r("inserted cell text"))) + '</w:tc></w:tr>'
  + f'<w:tr><w:trPr><w:ins w:id="171" w:author="{A}" w:date="{D1}"/></w:trPr>'
  + f'<w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/><w:cellIns w:id="172" w:author="{A}" w:date="{D1}"/></w:tcPr>' + p(ins(173,A,D1,r("new row c1"))) + '</w:tc>'
  + f'<w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/><w:cellIns w:id="174" w:author="{A}" w:date="{D1}"/></w:tcPr>' + p(ins(175,A,D1,r("new row c2"))) + '</w:tc></w:tr>'
  + f'<w:tr><w:trPr><w:del w:id="176" w:author="{B}" w:date="{D2}"/></w:trPr>'
  + f'<w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/><w:cellDel w:id="177" w:author="{B}" w:date="{D2}"/></w:tcPr>' + p(dele(178,B,D2,dr("deleted row c1"))) + '</w:tc>'
  + f'<w:tc><w:tcPr><w:tcW w:w="4675" w:type="dxa"/><w:cellDel w:id="179" w:author="{B}" w:date="{D2}"/></w:tcPr>' + p(dele(180,B,D2,dr("deleted row c2"))) + '</w:tc></w:tr>'
  + '</w:tbl>',
  # revision inside a hyperlink
  p('<w:hyperlink r:id="rIdLink">' + ins(190,C,D3,r("inserted link label")) + '</w:hyperlink>'),
  # revision inside a footnote reference paragraph
  p(r("Sentence with a footnote") + '<w:r><w:footnoteReference w:id="2"/></w:r>' + r(".")),
])

FN = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:footnotes {NS}>
<w:footnote w:id="0" w:type="separator"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
<w:footnote w:id="1" w:type="continuationSeparator"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
<w:footnote w:id="2"><w:p>{r("Footnote body with ")}{ins(200,A,D1,r("an inserted phrase"))}{dele(201,B,D2,dr(" and a removed one"))}{r(".")}</w:p></w:footnote>
</w:footnotes>'''

LINK_REL = f'<Relationship Id="rIdLink" Type="{REL_T}hyperlink" Target="https://example.com/spec" TargetMode="External"/>'

build('revisions.docx', body1, footnotes=FN, extra_rels=LINK_REL)

# ---------- FIXTURE 2: comments incl. threads, resolved, point comments ----------
def cra(i, inner): return f'<w:commentRangeStart w:id="{i}"/>{inner}<w:commentRangeEnd w:id="{i}"/><w:r><w:commentReference w:id="{i}"/></w:r>'

body2 = ''.join([
  p(f'<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>{r("Comment Scenarios")}'),
  p(cra(1, r("A ranged comment on this whole sentence."))),
  # Word-faithful thread: parent AND each reply carry their own range over the same text
  p('<w:commentRangeStart w:id="2"/><w:commentRangeStart w:id="3"/><w:commentRangeStart w:id="4"/>'
    + r("A threaded comment lives on this sentence.")
    + '<w:commentRangeEnd w:id="2"/><w:commentRangeEnd w:id="3"/><w:commentRangeEnd w:id="4"/>'
    + '<w:r><w:commentReference w:id="2"/></w:r><w:r><w:commentReference w:id="3"/></w:r><w:r><w:commentReference w:id="4"/></w:r>'),
  p(cra(5, r("This discussion was resolved."))),
  p(r("A point comment with no range sits right here") + '<w:r><w:commentReference w:id="6"/></w:r>' + r(".")),
  # comment range spanning multiple paragraphs
  f'<w:p><w:commentRangeStart w:id="7"/>{r("This comment spans from here,")}</w:p>'
  + p(r("across a middle paragraph,"))
  + f'<w:p>{r("all the way to here.")}<w:commentRangeEnd w:id="7"/><w:r><w:commentReference w:id="7"/></w:r></w:p>',
  # comment on a word inside a sentence (sub-sentence range)
  p(r("Only the word ") + cra(8, r("polysemy")) + r(" is annotated here.")),
  # overlapping comment ranges
  p('<w:commentRangeStart w:id="9"/>' + r("Outer range starts. ") + '<w:commentRangeStart w:id="10"/>'
    + r("Inner range here. ") + '<w:commentRangeEnd w:id="9"/><w:r><w:commentReference w:id="9"/></w:r>'
    + r("Outer ended, inner continues.") + '<w:commentRangeEnd w:id="10"/><w:r><w:commentReference w:id="10"/></w:r>'),
  # comment on text that is itself an insertion
  p(r("Baseline ") + ins(300,A,D1, f'<w:commentRangeStart w:id="11"/>{r("inserted and commented")}<w:commentRangeEnd w:id="11"/>') + '<w:r><w:commentReference w:id="11"/></w:r>' + r(" tail.")),
])

def cm(i, a, ini, d, paras, paraid):
    ps=''.join(f'<w:p w14:paraId="{paraid if k==len(paras)-1 else "%08X"%(0xAAAA0000+i*16+k)}"><w:r><w:t xml:space="preserve">{t}</w:t></w:r></w:p>' for k,t in enumerate(paras))
    return f'<w:comment w:id="{i}" w:author="{a}" w:initials="{ini}" w:date="{d}">{ps}</w:comment>'

# paraId of the LAST paragraph of each comment body is the threading key
PID = {1:'0A000001',2:'0A000002',3:'0A000003',4:'0A000004',5:'0A000005',6:'0A000006',
       7:'0A000007',8:'0A000008',9:'0A000009',10:'0A00000A',11:'0A00000B'}

COMMENTS = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:comments {NS}>
{cm(1,A,"AS",D1,["Can we tighten this sentence? It reads long."],PID[1])}
{cm(2,B,"BJ",D1,["I disagree with the framing here.","We should cite the 2025 review instead."],PID[2])}
{cm(3,A,"AS",D2,["Fair point - I will rework the paragraph."],PID[3])}
{cm(4,C,"CW",D2,["Agreed with both of you. Merging the two ideas."],PID[4])}
{cm(5,C,"CW",D1,["Typo fixed, closing this out."],PID[5])}
{cm(6,B,"BJ",D2,["Point comment: add a footnote here.","Second paragraph of the point comment."],PID[6])}
{cm(7,A,"AS",D3,["This whole passage needs a topic sentence."],PID[7])}
{cm(8,B,"BJ",D3,["Define this term on first use."],PID[8])}
{cm(9,C,"CW",D3,["Outer scope note."],PID[9])}
{cm(10,A,"AS",D3,["Inner scope note."],PID[10])}
{cm(11,B,"BJ",D3,["Commenting on newly inserted text."],PID[11])}
</w:comments>'''

# w15:done="1" marks resolved; w15:paraIdParent marks a reply
CEX = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w15:commentsEx xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml">
<w15:commentEx w15:paraId="{PID[1]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[2]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[3]}" w15:paraIdParent="{PID[2]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[4]}" w15:paraIdParent="{PID[2]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[5]}" w15:done="1"/>
<w15:commentEx w15:paraId="{PID[6]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[7]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[8]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[9]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[10]}" w15:done="0"/>
<w15:commentEx w15:paraId="{PID[11]}" w15:done="0"/>
</w15:commentsEx>'''

CIDS = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w16cid:commentsIds xmlns:w16cid="http://schemas.microsoft.com/office/word/2016/wordml/cid" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml">' + ''.join(f'<w16cid:commentId w16cid:paraId="{PID[i]}" w16cid:durableId="{0xB0000000+i:08X}"/>' for i in sorted(PID)) + '</w16cid:commentsIds>'

PEOPLE = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
<w15:person w15:author="{A}"><w15:presenceInfo w15:providerId="AD" w15:userId="alice@example.com"/></w15:person>
<w15:person w15:author="{B}"><w15:presenceInfo w15:providerId="AD" w15:userId="bob@example.com"/></w15:person>
<w15:person w15:author="{C}"><w15:presenceInfo w15:providerId="None" w15:userId="Carol White"/></w15:person>
</w15:people>'''

build('comments.docx', body2, comments=COMMENTS, cex=CEX, cids=CIDS, people=PEOPLE)

# ---------- FIXTURE 3: combined, plus CJK and special chars ----------
body3 = ''.join([
  p(f'<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>{r("Combined and Unicode")}'),
  p(cra(1, r("The report ") + ins(400,A,D1,r("clearly ")) + dele(401,B,D2,dr("somewhat ")) + r("shows a trend."))),
  p(r("中文段落：") + ins(402,C,D3,r("这是插入的内容。")) + dele(403,A,D1,dr("这是删除的内容。"))),
  p(r("Special chars: ") + ins(404,A,D1,r("a &amp; b &lt;tag&gt; \"quoted\" 100% *stars* /slashes/ _under_ =eq= ~tilde~ [brackets]"))),
  p(r("Emoji and math: ") + ins(405,B,D2,r("✓ αβγ \U0001F600"))),
])
_c3 = cm(1, A, "AS", D1, ['Comment with special chars: &amp; &lt; &gt; &quot; 100% *bold?* [link]'], PID[1])
COMMENTS3 = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:comments {NS}>
{_c3}
</w:comments>'''
CEX3 = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w15:commentsEx xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml"><w15:commentEx w15:paraId="{PID[1]}" w15:done="0"/></w15:commentsEx>'''
build('combined.docx', body3, comments=COMMENTS3, cex=CEX3)

# ---------- FIXTURE 4: clean doc, zero revisions, zero comments ----------
body4 = p(f'<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>{r("Clean Document")}') + p(r("Nothing to review here."))
build('clean.docx', body4)

# ---------- FIXTURE 5: revisions but NO commentsExtended (LibreOffice / Google Docs style) ----------
body5 = p(cra(1, r("Commented without extended part."))) + p(r("Body ") + ins(500,A,D1,r("inserted"))+ r("."))
COMMENTS5 = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:comments {NS}>
<w:comment w:id="1" w:author="{A}" w:initials="AS" w:date="{D1}"><w:p><w:r><w:t>No commentsExtended.xml exists in this file.</w:t></w:r></w:p></w:comment>
</w:comments>'''
build('no-extended.docx', body5, comments=COMMENTS5)

for f in sorted(os.listdir('.')):
    if f.endswith('.docx'): print(f"{f:22s} {os.path.getsize(f):7d} bytes")
