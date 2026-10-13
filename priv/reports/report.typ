// Both reports, A4, in the printed-specification register (PRD §13.2).
//
// AiInPractice.Reports.PDF renders this with the report as `content.json`,
// an in-memory file: no report text is ever spliced into this markup, so
// nothing a person typed can be read as Typst. The assessor report also
// gets `signed.json`, the signed envelope, attached to the PDF.
//
// Rules in place of boxes: a 3px (2.25pt) ink rule for structure, a 2px
// (1.5pt) hairline for separators. Flush left on a 9pt vertical unit (the
// screen's 12px). Source Serif 4 for language, IBM Plex Mono for data, and
// mono is never capitals. No fills, corners, images or charts. A URL too
// long for the line (about 100 mono characters) may break anywhere
// (zero-width spaces), so it never runs off the page; its link still points
// at the URL itself.

#let data = json(read("content.json", encoding: none))

#let ink = rgb("#111111")
#let quiet = rgb("#555555")
#let hair = rgb("#c4c4c4")
#let u = 9pt
#let serif = "Source Serif 4"
#let mono = "IBM Plex Mono"

#let rule = line(length: 100%, stroke: 2.25pt + ink)
#let hairline = line(length: 100%, stroke: 1.5pt + hair)
#let mono-text(size: 7.5pt, fill: quiet, body) = text(font: mono, size: size, fill: fill, body)

#set document(title: data.document_title, author: "DSC")
#set text(font: serif, size: 10.5pt, fill: ink, lang: "en", hyphenate: false)
#set par(leading: 0.62em, spacing: u * 1.25, justify: false)

#set page(
  paper: "a4",
  margin: (left: 25mm, right: 25mm, top: 30mm, bottom: if data.statement == none { 26mm } else { 40mm }),
  header: [
    #text(weight: "semibold")[DSC]#h(0.75em)AI in Practice#h(1fr)#mono-text[#data.title_short]
    #v(-0.45em)
    #rule
  ],
  header-ascent: 30%,
  footer: context [
    #hairline
    #v(-0.3em)
    #if data.statement != none [
      #text(size: 8.5pt)[#data.statement]
      #v(-0.2em)
    ]
    #mono-text[#data.foot#h(1fr)page #counter(page).display() of #counter(page).final().first()]
  ],
  footer-descent: 30%,
)

// Title and the header facts.
#text(size: 22pt, weight: "semibold")[#data.title]
#v(u * 0.5)
#grid(
  columns: (32mm, 1fr),
  row-gutter: u * 0.6,
  ..data.facts.map(f => (mono-text(size: 8pt)[#f.at(0)], mono-text(size: 8pt, fill: ink)[#f.at(1)])).flatten()
)
#v(u)

#let mono-label(body) = block(above: u * 0.9, below: u * 0.5, sticky: true, mono-text(size: 7.5pt)[#body])

#for b in data.blocks {
  if b.kind == "statement" {
    block(above: u, below: u * 1.5, width: 100%, stroke: (left: 2.25pt + ink), inset: (left: u))[
      #text(weight: "semibold")[#b.text]
    ]
  } else if b.kind == "h2" {
    block(above: u * 2.5, below: u, breakable: false, sticky: true, width: 100%)[
      #rule
      #v(u * 0.2)
      #text(size: 14pt, weight: "semibold")[#b.text]
    ]
  } else if b.kind == "h3" {
    block(above: u * 2, below: u * 0.8, breakable: false, sticky: true, width: 100%)[
      #hairline
      #v(u * 0.2)
      #text(size: 11.5pt, weight: "semibold")[#b.text]
    ]
  } else if b.kind == "p" {
    par[#b.text]
  } else if b.kind == "strong" {
    block(above: u * 1.25, below: u * 0.5)[#text(weight: "semibold")[#b.text]]
  } else if b.kind == "quote" {
    block(above: u * 0.8, below: u * 0.8, inset: (left: u), stroke: (left: 1.5pt + hair))[
      #text(style: "italic")[#b.text]
    ]
  } else if b.kind == "labelled" {
    mono-label(b.label)
    par[#b.text]
  } else if b.kind == "list" {
    list(marker: [–], indent: 0pt, body-indent: 0.6em, spacing: u * 0.8, ..b.items.map(i => [#i]))
  } else if b.kind == "reading" {
    block(above: u * 1.25, below: u)[
      #text(weight: "semibold")[#b.title]
      #if b.url != none [
        \ #mono-text(size: 7.5pt)[#link(b.url)[#if b.url.len() > 90 { b.url.clusters().join(sym.zws) } else { b.url }]]
      ]
      #if b.note != none [
        \ #b.note
      ]
    ]
  }
}

#if data.signed {
  pdf.attach(
    data.attachment,
    read("signed.json", encoding: none),
    mime-type: "application/json",
    relationship: "source",
    description: "The signed content of this report (Ed25519). Check it at " + data.check_at,
  )
}
