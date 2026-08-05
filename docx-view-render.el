;;; docx-view-render.el --- Render a pandoc AST as org text  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Nick

;; Author: Nick <nick@maderightsoftware.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Maintainer: Nick <nick@maderightsoftware.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Homepage: https://github.com/nick-maderight/docx-view

;; This file is part of docx-view.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file turns a pandoc AST into org text with the tracked changes marked
;; inline.  Two decisions here were settled by measurement rather than taste,
;; and both are worth recording because the obvious alternatives fail quietly.
;;
;; First, changes are marked with a custom org link type, not with org's
;; emphasis characters.  Writing a deletion as +removed+ looks natural and is
;; wrong: org's emphasis syntax demands particular characters either side of
;; the markers, so it does not apply mid-word, and it does not apply next to
;; CJK characters at all.  Word revisions routinely begin and end mid-word,
;; and Chinese text has no spaces, so emphasis-based marking silently fails
;; to render on exactly the documents that need it most.  A link of the form
;;
;;   [[dvchg:CHANGE-ID][the affected text]]
;;
;; parses in every position, including mid-word and CJK-adjacent, displays as
;; clean prose because org hides the bracket machinery, carries a
;; machine-readable payload for the change list and for navigation, and takes
;; its styling from the link type's face.  A further convenience: org does not
;; escape link descriptions, and the description survives a parse byte for
;; byte, including brackets, backslashes and "][", so the document's own text
;; can go straight in with no escaping layer to corrupt it.
;;
;; Second, comments are rendered as a numbered marker inline and the comment
;; text itself in a separate section, rather than inline in the prose.  Word
;; shows comments in a margin for a reason: a threaded discussion interleaved
;; into a sentence destroys the sentence.  The marker keeps the anchor visible
;; and clickable while the prose stays readable, and the discussion keeps its
;; thread structure where there is room to show it.
;;
;; One hazard needs care throughout.  Document text that happens to begin a
;; line with an org structural character is reinterpreted: a paragraph opening
;; with "* " becomes a headline, one opening with "| " becomes a table, and so
;; on.  A zero width space, which has display width zero, neutralises all of
;; these and is inert in the middle of a line, so it is prefixed to any
;; rendered line that would otherwise start with such a character.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'subr-x)
(require 'docx-view-pandoc)
(require 'docx-view-ooxml)

;;;; Options

(defcustom docx-view-render-comments 'section
  "Where the text of a comment is shown.

`section'  a numbered marker inline, with the discussion in a section at the
           end of the buffer.  Threads keep their structure.
`inline'   the comment text in the prose, immediately after the range it
           annotates.  Readable for one short comment, poor for a thread.
`none'     markers only, with the text available from the change list and
           from `docx-view-show-comment-at-point'."
  :type '(choice (const :tag "Marker inline, text in a section" section)
                 (const :tag "Text inline in the prose" inline)
                 (const :tag "Markers only" none))
  :group 'docx-view)

(defcustom docx-view-render-change-marker 'link
  "How a tracked change is marked in the rendered text.

`link'  a custom org link, whose face carries the styling.  This is the only
        form that renders reliably mid-word and next to CJK characters.
`plain' no markup at all, relying solely on the overlay face.  Choose this
        if a downstream tool must see the text with nothing added; note that
        the marking is then invisible in a plain org buffer."
  :type '(choice (const :tag "Custom org link" link)
                 (const :tag "Overlay face only" plain))
  :group 'docx-view)

(defcustom docx-view-render-author-colors
  '("#1f6feb" "#a371f7" "#d29922" "#2da44e" "#cf222e" "#0f766e" "#9a6700")
  "Colours cycled through to distinguish one reviewer from another.
The order is stable for a given document, so a reviewer keeps their colour
across a revert."
  :type '(repeat color)
  :group 'docx-view)

(defcustom docx-view-render-metadata-drawer t
  "Whether each rendered heading gets a property drawer with change counts."
  :type 'boolean
  :group 'docx-view)

;;;; Faces

(defface docx-view-insertion
  '((t :underline t :inherit success))
  "Face for text inserted by a tracked change."
  :group 'docx-view)

(defface docx-view-deletion
  '((t :strike-through t :inherit error))
  "Face for text removed by a tracked change."
  :group 'docx-view)

(defface docx-view-paragraph-change
  '((t :inherit shadow :weight bold))
  "Face for a paragraph mark that was inserted or deleted."
  :group 'docx-view)

(defface docx-view-comment-marker
  '((t :inherit warning :weight bold :height 0.9))
  "Face for the inline marker that stands in for a comment."
  :group 'docx-view)

(defface docx-view-comment-range
  '((t :inherit highlight :extend nil))
  "Face for the stretch of text a comment annotates."
  :group 'docx-view)

(defface docx-view-comment-resolved
  '((t :inherit shadow))
  "Face for a comment thread that the reviewers marked done."
  :group 'docx-view)

;;;; The change record
;;
;; One of these exists per marked span.  It is the unit that the change list,
;; the navigation commands and the echo-area help all work from.

(cl-defstruct (docx-view-change (:constructor docx-view-change-create)
                                (:copier nil))
  "A single marked-up span in the rendered buffer.

KEY is a short string, unique within the buffer, that appears in the org
link.  KIND is `insertion', `deletion', `paragraph-insertion',
`paragraph-deletion' or `comment'.  AUTHOR and DATE come from the document.
TEXT is the affected text.  BEG and END are buffer positions spanning the
whole change, filled in once the text is in place.  RANGES is the list of
buffer ranges the change actually covers, which is more than one when
another change is nested inside it.  COMMENT is the `docx-view-comment'
struct for a comment change, and nil otherwise."
  key kind author date text beg end ranges comment)

;;;; Rendering state
;;
;; Held in a struct rather than in a pile of dynamic variables so that the
;; recursive descent stays readable and so that nothing leaks between two
;; documents rendered in the same session.

(cl-defstruct (docx-view-render-state
               (:constructor docx-view-render-state-create)
               (:copier nil))
  "Mutable bookkeeping for one rendering pass."
  (counter 0)                           ; source of change keys
  (changes nil)                         ; list of docx-view-change, reversed
  (open-comments nil)                   ; ids whose range is currently open
  (comment-numbers (make-hash-table :test #'equal)) ; id -> display number
  (comment-order nil)                   ; ids in first-seen order, reversed
  (reviewers nil)                       ; author names in first-seen order
  (comments (make-hash-table :test #'equal)))  ; id -> docx-view-comment

(defun docx-view-render--next-key (state prefix)
  "Return a fresh change key in STATE beginning with PREFIX."
  (format "%s-%d" prefix (cl-incf (docx-view-render-state-counter state))))

(defun docx-view-render--note-author (state author)
  "Record AUTHOR in STATE, keeping first-seen order.  Return AUTHOR."
  (when (and author (not (member author (docx-view-render-state-reviewers state))))
    (setf (docx-view-render-state-reviewers state)
          (append (docx-view-render-state-reviewers state) (list author))))
  author)

(defun docx-view-render--comment-number (state id)
  "Return the display number for comment ID in STATE, assigning one if needed.
Numbers are normally assigned before the walk begins, from the document's own
comment order, so that an inline marker and the comment section always agree.
This assigns one on demand for the case where the body anchors a comment that
the comment part does not describe."
  (or (gethash id (docx-view-render-state-comment-numbers state))
      (let ((n (1+ (hash-table-count
                    (docx-view-render-state-comment-numbers state)))))
        (puthash id n (docx-view-render-state-comment-numbers state))
        (push id (docx-view-render-state-comment-order state))
        n)))

;;;; Link and escaping helpers

(defconst docx-view-render-link-type "dvchg"
  "Org link type under which docx-view registers its change links.")

(defconst docx-view-render--zwsp "​"
  "Zero width space, used to stop org reinterpreting a line's first character.
It has display width zero, so it is invisible, and it is inert mid-line.")

(defconst docx-view-render--structural-rx
  (rx bos (* blank)
      (or (: (+ "*") (or blank eos))    ; headline
          (: (or "-" "+") (or blank eos)) ; bullet
          (: (+ digit) (or "." ")") (or blank eos)) ; ordered item
          "|"                          ; table row
          "#"                          ; keyword or comment
          (: ":" (or blank eos))        ; fixed-width
          (: ":" (+ (any alnum "_-")) ":" (* blank) eos))) ; drawer
  "Match a line whose first characters org would read as structure.")

(defun docx-view-render-guard-line (text)
  "Return TEXT, prefixed with a zero width space when org would misread it.
Document text is not org source, so a paragraph that happens to start with
\"* \" or \"| \" must not become a headline or a table."
  (if (string-match-p docx-view-render--structural-rx text)
      (concat docx-view-render--zwsp text)
    text))

(defconst docx-view-render--link-rx
  (rx "[[" (literal docx-view-render-link-type) ":"
      (group (+ (not (any "]")))) "]["
      (group (*? anychar)) "]]")
  "Match a docx-view change link, capturing its key and its description.")

(defun docx-view-render--link-1 (key text)
  "Return TEXT wrapped in one docx-view change link identified by KEY."
  (org-link-make-string (concat docx-view-render-link-type ":" key) text))

(defun docx-view-render--link (key text)
  "Return TEXT marked as the change identified by KEY.

Org links cannot nest, so when TEXT already contains change links -- which
happens whenever a comment is anchored inside an insertion, or one reviewer
edits another's edit -- the marking is split into a run of sibling links
around the inner ones.  Every link in the result carries KEY, so the change
is still one change; it simply occupies more than one range.

The description is inserted unescaped, which is safe: org does not escape
link descriptions, and a description survives a parse unchanged, brackets and
backslashes included."
  (if (not (string-match-p docx-view-render--link-rx text))
      (docx-view-render--link-1 key text)
    (let ((pos 0) (out ""))
      (while (string-match docx-view-render--link-rx text pos)
        (let ((before (substring text pos (match-beginning 0))))
          (unless (string-empty-p before)
            (setq out (concat out (docx-view-render--link-1 key before))))
          (setq out (concat out (match-string 0 text))
                pos (match-end 0))))
      (let ((tail (substring text pos)))
        (unless (string-empty-p tail)
          (setq out (concat out (docx-view-render--link-1 key tail)))))
      out)))

;;;; Author colours

(defun docx-view-render-author-color (author authors)
  "Return the colour assigned to AUTHOR given the AUTHORS list, or nil."
  (when (and author authors docx-view-render-author-colors)
    (let ((i (cl-position author authors :test #'equal)))
      (when i
        (nth (mod i (length docx-view-render-author-colors))
             docx-view-render-author-colors)))))

;;;; Inline rendering
;;
;; The walker returns a string and mutates STATE.  Change records get their
;; text and metadata here; their buffer positions are attached in a second
;; pass, once the text is actually in a buffer, because the offsets are not
;; known until then.

(defun docx-view-render--mark (state kind attr inner)
  "Return INNER marked as a change of KIND, recording it in STATE.
ATTR is the pandoc attribute triple carrying author and date."
  (let* ((author (docx-view-render--note-author
                  state (docx-view-pandoc-attr-get attr "author")))
         (date (docx-view-pandoc-attr-get attr "date"))
         (key (docx-view-render--next-key
               state (pcase kind
                       ('insertion "ins") ('deletion "del")
                       ('paragraph-insertion "pins")
                       ('paragraph-deletion "pdel")
                       (_ "chg")))))
    (push (docx-view-change-create :key key :kind kind :author author
                                   :date date :text inner)
          (docx-view-render-state-changes state))
    (cond
     ;; A paragraph mark has no text of its own, so it needs a visible glyph
     ;; or the reader cannot tell that anything happened.
     ((memq kind '(paragraph-insertion paragraph-deletion))
      (let ((glyph (if (eq kind 'paragraph-insertion) "¶+" "¶-")))
        (if (eq docx-view-render-change-marker 'link)
            (docx-view-render--link key glyph)
          glyph)))
     ((string-empty-p inner) "")
     ((eq docx-view-render-change-marker 'link)
      (docx-view-render--link key inner))
     (t inner))))

(defun docx-view-render--comment-marker (state id attr)
  "Return the inline marker for comment ID, recording it in STATE.
ATTR is the pandoc attribute triple of the `comment-start' span."
  (let* ((n (docx-view-render--comment-number state id))
         (struct (gethash id (docx-view-render-state-comments state)))
         (author (docx-view-render--note-author
                  state (or (and struct (docx-view-comment-author struct))
                            (docx-view-pandoc-attr-get attr "author"))))
         (key (format "c%s" id))
         (resolved (and struct (docx-view-comment-resolved struct)))
         ;; Parentheses, not square brackets: a bracketed description ending
         ;; in "]" runs into the link's own closing "]]", which org resolves
         ;; by ending the description early and leaving a stray bracket in
         ;; the prose.
         (label (format "(%d%s)" n (if resolved "✓" ""))))
    (push (docx-view-change-create
           :key key :kind 'comment :author author
           :date (or (and struct (docx-view-comment-date struct))
                     (docx-view-pandoc-attr-get attr "date"))
           :text (if struct
                     (string-join (docx-view-comment-paragraphs struct) "\n")
                   (docx-view-pandoc-stringify attr t))
           :comment struct)
          (docx-view-render-state-changes state))
    (if (eq docx-view-render-change-marker 'link)
        (docx-view-render--link key label)
      label)))

(defun docx-view-render-inlines (nodes state)
  "Render the inline NODES as a string, updating STATE.
Comment ranges are tracked in STATE across calls, because a range may open in
one paragraph and close in another."
  (mapconcat
   (lambda (node)
     (cond
      ((stringp node) node)
      ((not (docx-view-pandoc-node-p node))
       (if (and (consp node) (proper-list-p node))
           (docx-view-render-inlines node state)
         ""))
      (t
       (let* ((tag (docx-view-pandoc-tag node))
              (payload (docx-view-pandoc-payload node))
              (kids (docx-view-pandoc-children node))
              (kind (docx-view-pandoc-span-kind node)))
         (cond
          ;; -- tracked changes ------------------------------------------
          ((memq kind '(insertion deletion))
           (docx-view-render--mark
            state kind (docx-view-pandoc-span-attr node)
            (docx-view-render-inlines (docx-view-pandoc-span-inlines node) state)))
          ((memq kind '(paragraph-insertion paragraph-deletion))
           (docx-view-render--mark
            state kind (docx-view-pandoc-span-attr node) ""))
          ;; -- comments -------------------------------------------------
          ((eq kind 'comment-start)
           (let* ((attr (docx-view-pandoc-span-attr node))
                  (id (docx-view-pandoc-attr-get attr "id")))
             (push id (docx-view-render-state-open-comments state))
             (docx-view-render--comment-marker state id attr)))
          ((eq kind 'comment-end)
           (let* ((attr (docx-view-pandoc-span-attr node))
                  (id (docx-view-pandoc-attr-get attr "id")))
             (setf (docx-view-render-state-open-comments state)
                   (delete id (docx-view-render-state-open-comments state)))
             ;; Ends nest when several comments finish at the same point, so
             ;; the children must still be walked or the inner ends are lost.
             (concat
              (docx-view-render-inlines (docx-view-pandoc-span-inlines node) state)
              (if (eq docx-view-render-comments 'inline)
                  (docx-view-render--inline-comment-text state id)
                ""))))
          ;; -- ordinary inline content ----------------------------------
          ((equal tag "Str") (if (stringp payload) payload ""))
          ((member tag '("Space" "SoftBreak")) " ")
          ((equal tag "LineBreak") "\n")
          ((equal tag "Strong")
           (docx-view-render--emphasise (docx-view-render-inlines kids state) "*"))
          ((equal tag "Emph")
           (docx-view-render--emphasise (docx-view-render-inlines kids state) "/"))
          ((equal tag "Underline")
           (docx-view-render--emphasise (docx-view-render-inlines kids state) "_"))
          ((member tag '("Strikeout" "Subscript" "Superscript" "SmallCaps"))
           ;; Rendered plainly: org's markup for these either collides with
           ;; the deletion styling or does not exist.
           (docx-view-render-inlines kids state))
          ((equal tag "Code")
           (let ((text (if (stringp payload) payload (or (cadr kids) ""))))
             (docx-view-render--emphasise text "~")))
          ((equal tag "Math")
           (or (car (last (and (proper-list-p payload) payload))) ""))
          ((equal tag "Quoted")
           (let ((inner (docx-view-render-inlines (cadr kids) state)))
             (if (equal (docx-view-pandoc-tag (car kids)) "SingleQuote")
                 (concat "'" inner "'")
               (concat "\"" inner "\""))))
          ((equal tag "Cite") (docx-view-render-inlines (cadr kids) state))
          ((equal tag "Span") (docx-view-render-inlines (cadr kids) state))
          ((equal tag "Link")
           (let* ((desc (docx-view-render-inlines (nth 1 kids) state))
                  (target (car (nth 2 kids))))
             (if (or (null target) (string-empty-p target))
                 desc
               ;; A change marker inside a link description would nest one
               ;; org link in another, which org cannot represent.  Keep the
               ;; marker and drop the outer link in that case.
               (if (string-match-p (regexp-quote
                                    (concat "[[" docx-view-render-link-type ":"))
                                   desc)
                   desc
                 (org-link-make-string target desc)))))
          ((equal tag "Image")
           (let* ((desc (docx-view-render-inlines (nth 1 kids) state))
                  (target (car (nth 2 kids))))
             (format "[image: %s]" (if (string-empty-p desc)
                                      (or target "embedded") desc))))
          ((equal tag "Note") (docx-view-render--footnote kids state))
          ((equal tag "RawInline")
           ;; Raw output for some other format has no meaning in an org view.
           "")
          ((member tag '("LineBlock")) (docx-view-render-inlines kids state))
          (t (docx-view-render-inlines kids state)))))))
   nodes ""))

(defun docx-view-render--emphasise (text marker)
  "Return TEXT wrapped in org emphasis MARKER, when org would honour it.
Org's emphasis syntax requires particular characters either side of the
markers, and refuses to apply mid-word or next to a CJK character.  When it
would not apply, TEXT is returned plain rather than with literal markers
showing, since visible \"*stars*\" in prose is worse than lost emphasis."
  (if (or (string-empty-p text)
          (string-match-p "\\`[[:space:]]" text)
          (string-match-p "[[:space:]]\\'" text)
          (string-match-p "\n" text))
      text
    (concat marker text marker)))

(defvar docx-view-render--footnotes nil
  "Footnote bodies collected during a rendering pass, as a reversed list.")

(defun docx-view-render--footnote (kids state)
  "Render a pandoc Note whose blocks are KIDS, updating STATE.
The body is collected for a footnote section and an org footnote reference is
returned in its place.

KIDS is the Note's child list, and its payload is a list of exactly one
element: the list of body blocks.  Rendering `(car kids)' therefore renders
the block list, not the first block -- taking the first block instead yields
an empty body, silently losing the whole footnote."
  (let* ((n (1+ (length docx-view-render--footnotes)))
         (label (format "fn:%d" n))
         (body (string-trim (docx-view-render-blocks kids state))))
    (push (cons label body) docx-view-render--footnotes)
    (format "[%s]" label)))

;;;; Block rendering

(defun docx-view-render--para (nodes state &optional prefix)
  "Render inline NODES as a paragraph, updating STATE.
PREFIX is prepended to the first line, for list items and the like."
  (let* ((text (string-trim-right (docx-view-render-inlines nodes state)))
         (lines (split-string text "\n")))
    (concat (or prefix "")
            (mapconcat #'docx-view-render-guard-line lines "\n")
            "\n")))

(defun docx-view-render--table (kids state)
  "Render a pandoc Table whose payload is KIDS, updating STATE.
Cells are rendered as single-line org table cells.  A newline inside a cell
would break the table, and a literal bar would start a new column, so both
are replaced."
  (let* ((head (nth 3 kids))
         (bodies (nth 4 kids))
         (foot (nth 5 kids))
         (rows (append (docx-view-render--table-rows (cadr head) state)
                       (mapcan (lambda (b)
                                 (docx-view-render--table-rows
                                  (nth 3 b) state))
                               (copy-sequence bodies))
                       (docx-view-render--table-rows (cadr foot) state)))
         (header (car rows)))
    (if (null rows)
        ""
      (concat (docx-view-render--table-row header)
              ;; A rule under the first row is what makes org treat it as a
              ;; header; only add it when there is a body to separate.  The
              ;; dashes need not be the column width: `org-table-align' fixes
              ;; the width, and a link's displayed width is not its length
              ;; anyway, so guessing here would only ever be wrong.
              (if (cdr rows)
                  (concat "|" (mapconcat (lambda (_) "---") header "+") "|\n")
                "")
              (mapconcat #'docx-view-render--table-row (cdr rows) "")))))

(defun docx-view-render--table-row (cells)
  "Return CELLS as one org table row."
  (concat "| " (mapconcat #'identity cells " | ") " |\n"))

(defun docx-view-render--table-rows (rows state)
  "Render pandoc table ROWS to a list of lists of cell strings.
STATE is the `docx-view-render-state' of the pass in progress."
  (mapcar
   (lambda (row)
     (mapcar
      (lambda (cell)
        ;; Cell = (ATTR ALIGN ROWSPAN COLSPAN BLOCKS)
        (let ((text (string-trim
                     (docx-view-render-blocks (nth 4 cell) state))))
          (setq text (replace-regexp-in-string "[ \t]*\n[ \t]*" " " text))
          (replace-regexp-in-string "|" "\\\\vert{}" text)))
      (cadr row)))
   (and (proper-list-p rows) rows)))

(defun docx-view-render--list (items state bullet)
  "Render pandoc list ITEMS with BULLET, updating STATE.
BULLET is either a string, used for every item, or a function of the item
index returning a string."
  (let ((i 0))
    (mapconcat
     (lambda (item)
       (setq i (1+ i))
       (let* ((mark (if (functionp bullet) (funcall bullet i) bullet))
              (pad (make-string (length mark) ?\s))
              (body (string-trim-right (docx-view-render-blocks item state)))
              (lines (split-string body "\n")))
         ;; Continuation lines are indented to the item's text column, which
         ;; is what keeps them inside the item rather than ending the list.
         (concat mark (car lines) "\n"
                 (mapconcat (lambda (l)
                              (if (string-empty-p l) "\n" (concat pad l "\n")))
                            (cdr lines) ""))))
     items "")))

(defun docx-view-render-blocks (blocks state &optional level)
  "Render BLOCKS as org text, updating STATE.
LEVEL is the org heading level at which document headings are emitted; it
defaults to 2, leaving level 1 for the document's own title."
  (let ((level (or level 2)))
    (mapconcat
     (lambda (block)
       (if (not (docx-view-pandoc-node-p block))
           (if (and (consp block) (proper-list-p block))
               (docx-view-render-blocks block state level)
             "")
         (let* ((tag (docx-view-pandoc-tag block))
                (kids (docx-view-pandoc-children block)))
           (pcase tag
             ("Para" (concat (docx-view-render--para kids state) "\n"))
             ("Plain" (docx-view-render--para kids state))
             ("LineBlock"
              (concat (mapconcat (lambda (l)
                                   (docx-view-render-guard-line
                                    (docx-view-render-inlines l state)))
                                 kids "\n")
                      "\n\n"))
             ("Header"
              (let* ((depth (max 1 (or (nth 0 kids) 1)))
                     (text (string-trim (docx-view-render-inlines (nth 2 kids)
                                                                  state))))
                (format "%s %s\n"
                        (make-string (+ level depth -1) ?*)
                        (if (string-empty-p text) "(untitled)" text))))
             ("BlockQuote"
              (concat "#+begin_quote\n"
                      (string-trim-right (docx-view-render-blocks kids state level))
                      "\n#+end_quote\n\n"))
             ("CodeBlock"
              (let ((code (or (car (last kids)) "")))
                (concat "#+begin_example\n" code
                        (if (string-suffix-p "\n" code) "" "\n")
                        "#+end_example\n\n")))
             ("RawBlock" "")
             ("BulletList"
              (concat (docx-view-render--list kids state "- ") "\n"))
             ("OrderedList"
              (let* ((attrs (car kids))
                     (start (or (car attrs) 1)))
                (concat (docx-view-render--list
                         (cadr kids) state
                         (lambda (i) (format "%d. " (+ start i -1))))
                        "\n")))
             ("DefinitionList"
              (concat
               (mapconcat
                (lambda (entry)
                  (let ((term (string-trim
                               (docx-view-render-inlines (car entry) state)))
                        (defs (string-trim-right
                               (docx-view-render-blocks (cadr entry) state level))))
                    (format "- %s :: %s\n" term
                            (replace-regexp-in-string "\n+" " " defs))))
                kids "")
               "\n"))
             ("Table" (concat (docx-view-render--table kids state) "\n"))
             ("Figure"
              (concat (string-trim-right
                       (docx-view-render-blocks (nth 2 kids) state level))
                      "\n\n"))
             ("Div" (docx-view-render-blocks (cadr kids) state level))
             ("HorizontalRule" "-----\n\n")
             (_ (docx-view-render-blocks kids state level))))))
     blocks "")))

;;;; Comment text

(defun docx-view-render--inline-comment-text (state id)
  "Return the text of comment ID for inline display, from STATE."
  (let ((struct (gethash id (docx-view-render-state-comments state))))
    (if (not struct)
        ""
      (format " {%s: %s}"
              (or (docx-view-comment-author struct) "comment")
              (string-join (docx-view-comment-paragraphs struct) " ")))))

(defun docx-view-render--comment-body (struct state indent)
  "Return the org text of comment STRUCT at INDENT, using STATE for numbers."
  (let* ((id (docx-view-comment-id struct))
         (n (gethash id (docx-view-render-state-comment-numbers state)))
         (pad (make-string indent ?\s))
         (author (or (docx-view-comment-author struct) "Unknown"))
         (email (docx-view-comment-email struct))
         (date (docx-view-comment-date struct)))
    (concat
     (format "%s- [%s] %s%s%s%s\n"
             pad (or n id) author
             (if email (format " <%s>" email) "")
             (if date (format ", %s" (docx-view-render-format-date date)) "")
             (cond ((docx-view-comment-resolved struct) " (resolved)")
                   ((not (docx-view-comment-anchored struct)) " (unanchored)")
                   (t "")))
     (mapconcat (lambda (para)
                  (format "%s  %s\n" pad
                          (docx-view-render-guard-line (string-trim para))))
                (or (docx-view-comment-paragraphs struct) '(""))
                ""))))

(defun docx-view-render-format-date (date)
  "Return the ISO 8601 DATE formatted for display, or DATE when unparsable.
Parsing is delegated to `parse-time-string' rather than done by hand."
  (or (ignore-errors
        (let ((parsed (parse-time-string date)))
          (when (and (nth 4 parsed) (nth 5 parsed))
            (format-time-string "%Y-%m-%d %H:%M"
                                (encode-time (decoded-time-set-defaults parsed))))))
      date))

(defun docx-view-render--comment-section (state level)
  "Return the comment section for STATE as org text at heading LEVEL.
Threads are rendered as nested lists, and any comment that the document
anchors nowhere is listed too, since pandoc drops those from the body."
  (let* ((all (let (acc)
                (maphash (lambda (_ v) (push v acc))
                         (docx-view-render-state-comments state))
                (sort acc (lambda (a b)
                            (< (string-to-number (docx-view-comment-id a))
                               (string-to-number (docx-view-comment-id b)))))))
         (threads (docx-view-ooxml-comment-threads all)))
    (if (null all)
        ""
      (concat
       (format "\n%s Comments (%d)\n" (make-string level ?*) (length all))
       (mapconcat
        (lambda (thread)
          (concat (docx-view-render--comment-body (car thread) state 0)
                  (mapconcat (lambda (reply)
                               (docx-view-render--comment-body reply state 2))
                             (cdr thread) "")))
        threads "")))))

;;;; Extra revisions

(defconst docx-view-render--kind-labels
  '((move-from . "moved away from here")
    (move-to . "moved to here")
    (run-format . "character formatting changed")
    (paragraph-format . "paragraph formatting changed")
    (cell-insert . "table cell inserted")
    (cell-delete . "table cell deleted")
    (row-insert . "table row inserted")
    (row-delete . "table row deleted")
    (section-format . "section formatting changed")
    (numbering . "list numbering changed"))
  "Plain-language labels for the revision kinds pandoc does not report.")

(defun docx-view-render--extra-section (revisions level)
  "Return the org text listing REVISIONS at heading LEVEL.
These are the revisions pandoc discards, so they can only be reported as a
list; the viewer cannot place them inline without reimplementing the reader."
  (if (null revisions)
      ""
    (concat
     (format "\n%s Other revisions (%d)\n" (make-string level ?*) (length revisions))
     "Pandoc does not report these, so they are listed rather than marked inline.\n\n"
     (mapconcat
      (lambda (rev)
        (let ((kind (docx-view-extra-revision-kind rev)))
          (format "- %s, %s%s%s\n"
                  (or (cdr (assq kind docx-view-render--kind-labels))
                      (symbol-name kind))
                  (or (docx-view-extra-revision-author rev) "unknown author")
                  (let ((d (docx-view-extra-revision-date rev)))
                    (if d (format ", %s" (docx-view-render-format-date d)) ""))
                  (let ((name (docx-view-extra-revision-name rev))
                        (text (docx-view-extra-revision-text rev)))
                    (concat (if name (format " (move %s)" name) "")
                            (if text
                                (format ": %s"
                                        (truncate-string-to-width text 70 nil nil t))
                              ""))))))
      revisions ""))))

;;;; Whole-document rendering

(cl-defstruct (docx-view-document (:constructor docx-view-document-create)
                                  (:copier nil))
  "The result of rendering one .docx file.
TEXT is the org source.  CHANGES is a list of `docx-view-change' in document
order, with BEG and END filled in.  COMMENTS and EXTRA are what the OOXML
layer recovered.  AUTHORS is every reviewer named, in first-seen order.
WARNINGS is a list of strings worth telling the user about."
  text changes comments extra authors warnings)

(defun docx-view-render-document (file &optional mode)
  "Render FILE and return a `docx-view-document'.
MODE is `all', `accept' or `reject', defaulting to `all'.

The OOXML layer is consulted as well as pandoc, because pandoc's docx reader
discards comment threading, resolved state, author e-mail, move identity,
formatting-only revisions, table row and cell revisions, and point comments."
  (let* ((mode (or mode 'all))
         (ast (docx-view-pandoc-ast file))
         (blocks (docx-view-pandoc-filter-changes
                  (docx-view-pandoc-blocks ast) mode))
         (state (docx-view-render-state-create))
         (docx-view-render--footnotes nil)
         warnings
         ;; Pandoc has already read the file by this point, so the OOXML
         ;; layer failing here means the parts it wants are unreadable rather
         ;; than that the document is bad.  That costs threading and point
         ;; comments, not the document, so it is reported and not raised: a
         ;; viewer that refuses to show anything is worse than one that shows
         ;; the prose and says what it could not recover.
         (comments (condition-case err (docx-view-ooxml-comments file)
                     (error
                      (push (format "comments could not be read: %s"
                                    (error-message-string err))
                            warnings)
                      nil)))
         (extra (condition-case nil (docx-view-ooxml-extra-revisions file)
                  (error nil))))
    (dolist (c comments)
      (puthash (docx-view-comment-id c) c
               (docx-view-render-state-comments state)))
    ;; Number the comments up front, in the document's own w:id order, so
    ;; that the inline markers and the comment section agree and so that the
    ;; numbering does not shift when a range happens to open late.  A thread
    ;; reply keeps its own number, which is what lets a marker point at the
    ;; exact reply rather than only at the thread.
    (dolist (c comments)
      (docx-view-render--comment-number state (docx-view-comment-id c)))
    (let* ((body (docx-view-render-blocks blocks state 2))
           (unanchored (seq-remove #'docx-view-comment-anchored comments))
           (footnotes (nreverse docx-view-render--footnotes))
           (text (concat
                  body
                  (if footnotes
                      (concat "\n" (mapconcat (lambda (fn)
                                                (format "[%s] %s\n" (car fn) (cdr fn)))
                                              footnotes "")
                              "\n")
                    "")
                  (if (memq docx-view-render-comments '(section none))
                      (docx-view-render--comment-section state 2)
                    "")
                  (docx-view-render--extra-section extra 2))))
      (when unanchored
        (push (format "%d comment(s) are anchored nowhere in the text and appear only in the comment section"
                      (length unanchored))
              warnings))
      (when (docx-view-render-state-open-comments state)
        (push (format "%d comment range(s) were left unterminated by the document"
                      (length (docx-view-render-state-open-comments state)))
              warnings))
      (docx-view-document-create
       :text text
       :changes (nreverse (docx-view-render-state-changes state))
       :comments comments
       :extra extra
       :authors (docx-view-render-state-reviewers state)
       :warnings (nreverse warnings)))))

;;;; Locating changes in the rendered buffer
;;
;; Positions cannot be recorded while building the string, because the string
;; is assembled from the inside out.  Instead each change is found afterwards
;; by its link, which is unique by construction.

(defun docx-view-render-locate-changes (changes)
  "Fill in the BEG and END of every change in CHANGES, in the current buffer.
Return the list of changes that could not be located, which is empty unless
`docx-view-render-change-marker' is `plain'."
  (let (missing)
    (dolist (change changes (nreverse missing))
      (let ((needle (format "[[%s:%s]" docx-view-render-link-type
                            (docx-view-change-key change))))
        (save-excursion
          (goto-char (point-min))
          (if (search-forward needle nil t)
              (let* ((link-start (- (point) (length needle)))
                     (desc-start (point))
                     (desc-end (progn (goto-char desc-start)
                                      (if (search-forward "]]" nil t)
                                          (- (point) 2)
                                        desc-start))))
                ;; Prefer the description bounds, which is the text the
                ;; reader actually sees; fall back to the whole link.
                (setf (docx-view-change-beg change)
                      (if (> desc-end desc-start) (1+ desc-start) link-start))
                (setf (docx-view-change-end change) desc-end))
            (push change missing)))))))

(provide 'docx-view-render)

;;; docx-view-render.el ends here
