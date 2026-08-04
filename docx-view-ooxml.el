;;; docx-view-ooxml.el --- Read revision metadata straight from OOXML parts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Nick

;; Author: Nick <nick@maderightsoftware.com>
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

;; Pandoc reads the body of a .docx well, but its docx reader discards a great
;; deal of the revision metadata that a reviewer actually needs.  Measured
;; against pandoc 3.7.0.2, the following is lost:
;;
;;   * comment threading (which comment replies to which)
;;   * comment resolved/done state
;;   * author identity beyond the display name
;;   * the distinction between a move and an unrelated delete plus insert
;;   * formatting-only revisions (w:rPrChange, w:pPrChange)
;;   * table row and cell revisions (w:cellIns, w:cellDel, w:trPr)
;;   * "point" comments, i.e. a w:commentReference with no surrounding
;;     w:commentRangeStart, which pandoc drops entirely, body text and all
;;
;; This file recovers that information by reading the OOXML parts directly.  A
;; .docx is a zip archive of XML, so we shell out to `unzip -p' for a single
;; member and parse it with the built-in `xml-parse-buffer'.  No third-party
;; library is required.
;;
;; Namespace handling deserves a note.  `xml.el' does not resolve namespaces;
;; it hands back element and attribute names as literal prefixed symbols such
;; as `w:comment' and `w15:paraId'.  Prefixes are however only conventionally
;; "w" and "w15" -- a producer may bind any prefix to a namespace URI.  We
;; therefore read the xmlns declarations off the root element and resolve
;; prefixes by URI, falling back to the conventional prefix when a document
;; declares nothing useful.

;;; Code:

(require 'xml)
(require 'cl-lib)
(require 'subr-x)

;;;; Namespace URIs

(defconst docx-view-ooxml-ns-w
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  "Namespace URI for the main WordprocessingML vocabulary.")

(defconst docx-view-ooxml-ns-w14
  "http://schemas.microsoft.com/office/word/2010/wordml"
  "Namespace URI for the Word 2010 extensions, source of w14:paraId.")

(defconst docx-view-ooxml-ns-w15
  "http://schemas.microsoft.com/office/word/2012/wordml"
  "Namespace URI for the Word 2012 extensions, source of commentsEx and people.")

(defconst docx-view-ooxml-ns-w16cid
  "http://schemas.microsoft.com/office/word/2016/wordml/cid"
  "Namespace URI for the Word 2016 durable comment identifiers.")

;;;; Reading parts out of the archive

(defcustom docx-view-unzip-program "unzip"
  "Program used to extract a single member from a .docx archive.
It must accept the `-p' option, meaning \"write member to stdout\"."
  :type 'string
  :group 'docx-view)

(define-error 'docx-view-bad-archive "Not a readable .docx archive")

(defun docx-view-ooxml--part-names (file)
  "Return the list of archive member names inside FILE.
Signal `docx-view-bad-archive' when FILE cannot be listed."
  (with-temp-buffer
    (let ((rc (call-process docx-view-unzip-program nil (list t nil) nil
                            "-Z" "-1" file)))
      (unless (eq rc 0)
        (signal 'docx-view-bad-archive (list file)))
      (split-string (buffer-string) "\n" t))))

(defun docx-view-ooxml-part-exists-p (file part)
  "Return non-nil when PART is a member of the archive FILE."
  (member part (docx-view-ooxml--part-names file)))

(defun docx-view-ooxml-parse-part (file part)
  "Parse archive member PART of FILE and return its XML tree.
Return nil when PART is absent or is not well-formed XML.  Absence is a
normal condition: many producers omit the optional comment parts."
  (with-temp-buffer
    (let ((rc (call-process docx-view-unzip-program nil (list t nil) nil
                            "-p" file part)))
      (when (and (eq rc 0) (> (buffer-size) 0))
        (condition-case nil
            (xml-parse-region (point-min) (point-max))
          (error nil))))))

;;;; Namespace-aware accessors
;;
;; `xml.el' gives us prefixed symbols.  We build a prefix map from the root
;; element's xmlns declarations so that a document using unconventional
;; prefixes still parses.

(defun docx-view-ooxml--prefix-map (root)
  "Return an alist of (URI . PREFIX) declared on ROOT.
PREFIX is a string without the trailing colon.  A default xmlns declaration
maps to an empty prefix."
  (let (map)
    (dolist (attr (xml-node-attributes root) map)
      (let ((name (symbol-name (car attr))))
        (cond
         ((string-prefix-p "xmlns:" name)
          (push (cons (cdr attr) (substring name 6)) map))
         ((string= name "xmlns")
          (push (cons (cdr attr) "") map)))))))

(defun docx-view-ooxml--prefix-for (root uri fallback)
  "Return the prefix bound to URI on ROOT, or FALLBACK when unbound."
  (or (cdr (assoc uri (docx-view-ooxml--prefix-map root))) fallback))

(defun docx-view-ooxml--sym (prefix local)
  "Return the symbol that `xml.el' gives LOCAL in the namespace PREFIX."
  (intern (if (string-empty-p prefix) local (concat prefix ":" local))))

(defun docx-view-ooxml--attr (node sym)
  "Return the value of attribute SYM on NODE, or nil."
  (cdr (assq sym (xml-node-attributes node))))

(defun docx-view-ooxml--descendants (node tag)
  "Return every descendant of NODE whose element name is TAG."
  (let (acc)
    (dolist (child (xml-node-children node))
      (when (consp child)
        (when (eq (xml-node-name child) tag)
          (push child acc))
        (setq acc (nconc (docx-view-ooxml--descendants child tag) acc))))
    (nreverse acc)))

(defun docx-view-ooxml--text (node)
  "Return the concatenated character data beneath NODE."
  (mapconcat (lambda (child)
               (cond ((stringp child) child)
                     ((consp child) (docx-view-ooxml--text child))
                     (t "")))
             (xml-node-children node)
             ""))

;;;; Comments

(cl-defstruct (docx-view-comment (:constructor docx-view-comment-create)
                                 (:copier nil))
  "A single Word comment, as recovered from the OOXML parts.

ID is the w:id string used by w:commentRangeStart and w:commentReference.
AUTHOR and INITIALS come from w:comment.  DATE is the raw ISO 8601 string.
PARAGRAPHS is a list of strings, one per paragraph of the comment body.
PARA-ID is the w14:paraId of the body's last paragraph; it is the key that
commentsExtended.xml uses to describe this comment.  PARENT-ID is the ID of
the comment this one replies to, or nil for a thread root.  RESOLVED is
non-nil when Word marks the thread done.  ANCHORED is nil for a point
comment, that is one with no w:commentRangeStart, which pandoc discards.
EMAIL is filled in from people.xml when available."
  id author initials date paragraphs para-id parent-id resolved anchored email)

(defun docx-view-ooxml--comment-bodies (file)
  "Return an alist of (ID . COMMENT-STRUCT) from word/comments.xml of FILE.
The structs are partially filled: threading and resolution are added later
by `docx-view-ooxml--apply-extended'."
  (let* ((tree (docx-view-ooxml-parse-part file "word/comments.xml"))
         (root (car tree)))
    (when root
      (let* ((wp (docx-view-ooxml--prefix-for root docx-view-ooxml-ns-w "w"))
             (w14p (docx-view-ooxml--prefix-for root docx-view-ooxml-ns-w14 "w14"))
             (s-comment (docx-view-ooxml--sym wp "comment"))
             (s-p (docx-view-ooxml--sym wp "p"))
             (s-t (docx-view-ooxml--sym wp "t"))
             (a-id (docx-view-ooxml--sym wp "id"))
             (a-author (docx-view-ooxml--sym wp "author"))
             (a-initials (docx-view-ooxml--sym wp "initials"))
             (a-date (docx-view-ooxml--sym wp "date"))
             (a-paraid (docx-view-ooxml--sym w14p "paraId"))
             acc)
        (dolist (node (docx-view-ooxml--descendants root s-comment) (nreverse acc))
          (let* ((paras (docx-view-ooxml--descendants node s-p))
                 (texts (mapcar (lambda (p)
                                  (mapconcat #'docx-view-ooxml--text
                                             (docx-view-ooxml--descendants p s-t)
                                             ""))
                                paras))
                 (last-para (car (last paras)))
                 (id (docx-view-ooxml--attr node a-id)))
            (push (cons id
                        (docx-view-comment-create
                         :id id
                         :author (docx-view-ooxml--attr node a-author)
                         :initials (docx-view-ooxml--attr node a-initials)
                         :date (docx-view-ooxml--attr node a-date)
                         :paragraphs texts
                         :para-id (and last-para
                                       (docx-view-ooxml--attr last-para a-paraid))))
                  acc)))))))

(defun docx-view-ooxml--apply-extended (file comments)
  "Add threading and resolved state from FILE's commentsExtended.xml part.
COMMENTS is an alist of (ID . STRUCT) as returned by
`docx-view-ooxml--comment-bodies', and is both modified and returned.

The join is subtle and worth stating plainly: the w15:paraId of a
w15:commentEx entry is the w14:paraId of the LAST PARAGRAPH of a comment's
body, not the comment's own w:id.  A w15:paraIdParent therefore identifies
the parent comment indirectly, via that parent's last body paragraph.

When the part is absent -- LibreOffice and some Google Docs exports omit it
-- every comment stays a resolved-unknown thread root, which is the correct
degradation."
  (let* ((tree (docx-view-ooxml-parse-part file "word/commentsExtended.xml"))
         (root (car tree)))
    (when root
      (let* ((w15p (docx-view-ooxml--prefix-for root docx-view-ooxml-ns-w15 "w15"))
             (s-ex (docx-view-ooxml--sym w15p "commentEx"))
             (a-paraid (docx-view-ooxml--sym w15p "paraId"))
             (a-parent (docx-view-ooxml--sym w15p "paraIdParent"))
             (a-done (docx-view-ooxml--sym w15p "done"))
             ;; paraId -> comment id, so a paraIdParent can be mapped back.
             (by-para (let (m)
                        (dolist (cell comments m)
                          (let ((pid (docx-view-comment-para-id (cdr cell))))
                            (when pid (push (cons pid (car cell)) m)))))))
        (dolist (node (docx-view-ooxml--descendants root s-ex))
          (let* ((pid (docx-view-ooxml--attr node a-paraid))
                 (cid (cdr (assoc pid by-para)))
                 (struct (cdr (assoc cid comments))))
            (when struct
              (let ((parent-pid (docx-view-ooxml--attr node a-parent))
                    (done (docx-view-ooxml--attr node a-done)))
                (setf (docx-view-comment-parent-id struct)
                      (and parent-pid (cdr (assoc parent-pid by-para))))
                (setf (docx-view-comment-resolved struct)
                      (member done '("1" "true"))))))))))
  comments)

(defun docx-view-ooxml--apply-people (file comments)
  "Add author e-mail addresses from FILE's people.xml part to COMMENTS.
COMMENTS is modified in place and returned."
  (let* ((tree (docx-view-ooxml-parse-part file "word/people.xml"))
         (root (car tree)))
    (when root
      (let* ((w15p (docx-view-ooxml--prefix-for root docx-view-ooxml-ns-w15 "w15"))
             (s-person (docx-view-ooxml--sym w15p "person"))
             (s-presence (docx-view-ooxml--sym w15p "presenceInfo"))
             (a-author (docx-view-ooxml--sym w15p "author"))
             (a-userid (docx-view-ooxml--sym w15p "userId"))
             (emails (let (m)
                       (dolist (node (docx-view-ooxml--descendants root s-person) m)
                         (let* ((name (docx-view-ooxml--attr node a-author))
                                (info (car (docx-view-ooxml--descendants node s-presence)))
                                (uid (and info (docx-view-ooxml--attr info a-userid))))
                           (when (and name uid (string-match-p "@" uid))
                             (push (cons name uid) m)))))))
        (dolist (cell comments)
          (let ((struct (cdr cell)))
            (setf (docx-view-comment-email struct)
                  (cdr (assoc (docx-view-comment-author struct) emails))))))))
  comments)

(defun docx-view-ooxml--anchored-ids (file)
  "Return the list of comment ID strings that have a range in FILE.
A comment whose ID is absent from this list is a point comment: Word shows
it attached to a single position rather than a span of text.  Pandoc drops
such comments entirely, so we must render them from this data."
  (let* ((tree (docx-view-ooxml-parse-part file "word/document.xml"))
         (root (car tree)))
    (when root
      (let* ((wp (docx-view-ooxml--prefix-for root docx-view-ooxml-ns-w "w"))
             (s-start (docx-view-ooxml--sym wp "commentRangeStart"))
             (a-id (docx-view-ooxml--sym wp "id")))
        (delq nil
              (mapcar (lambda (n) (docx-view-ooxml--attr n a-id))
                      (docx-view-ooxml--descendants root s-start)))))))

(defun docx-view-ooxml-comments (file)
  "Return the list of `docx-view-comment' structs in FILE.
Comments are returned in document order of their w:id, fully populated with
threading, resolved state, author e-mail and anchoring.

Signal `docx-view-bad-archive' when FILE is not a readable archive.  A
document with no comments returns nil, so the two cases must be told apart
here rather than both arriving as an empty list: word/comments.xml is
legitimately absent from most documents, and so its absence cannot itself be
the signal.  Listing the archive is the one probe that distinguishes them
without parsing a part, and it costs a single `unzip -Z'."
  (unless (docx-view-ooxml--part-names file)
    (signal 'docx-view-bad-archive (list file)))
  (let ((comments (docx-view-ooxml--comment-bodies file)))
    (when comments
      (docx-view-ooxml--apply-extended file comments)
      (docx-view-ooxml--apply-people file comments)
      (let ((anchored (docx-view-ooxml--anchored-ids file)))
        (dolist (cell comments)
          (setf (docx-view-comment-anchored (cdr cell))
                (and (member (car cell) anchored) t))))
      (mapcar #'cdr comments))))

(defun docx-view-ooxml-comment-threads (comments)
  "Group COMMENTS into threads.
Return a list of lists.  Each inner list starts with a thread root and is
followed by its replies in the order they appear in COMMENTS.  A comment
whose parent is missing is promoted to a root so that nothing is dropped."
  (let* ((ids (mapcar #'docx-view-comment-id comments))
         (roots (seq-filter
                 (lambda (c)
                   (let ((p (docx-view-comment-parent-id c)))
                     (or (null p) (not (member p ids)))))
                 comments)))
    (mapcar
     (lambda (root)
       (cons root
             (seq-filter
              (lambda (c)
                (equal (docx-view-comment-parent-id c)
                       (docx-view-comment-id root)))
              comments)))
     roots)))

;;;; Revisions that pandoc does not report
;;
;; Pandoc surfaces run-level insertions and deletions, and the deletion or
;; insertion of a paragraph mark.  Everything below is invisible to it.  We
;; collect these as a document-level list so the viewer can at least report
;; them faithfully rather than pretend the document is cleaner than it is.

(cl-defstruct (docx-view-extra-revision
               (:constructor docx-view-extra-revision-create)
               (:copier nil))
  "A revision that pandoc's docx reader does not expose.
KIND is one of the symbols `move-from', `move-to', `run-format',
`paragraph-format', `cell-insert', `cell-delete', `row-insert',
`row-delete', `numbering' or `section-format'.  AUTHOR and DATE are the
raw attribute values.  NAME is the move name for a paired move, letting a
move-from be matched to its move-to.  TEXT is the affected text where the
element encloses any."
  kind author date name text)

(defconst docx-view-ooxml--extra-revision-elements
  '(("moveFrom"    . move-from)
    ("moveTo"      . move-to)
    ("rPrChange"   . run-format)
    ("pPrChange"   . paragraph-format)
    ("cellIns"     . cell-insert)
    ("cellDel"     . cell-delete)
    ("sectPrChange" . section-format)
    ("numberingChange" . numbering))
  "Map of WordprocessingML element local names to revision kind symbols.")

(defun docx-view-ooxml--move-names (root wp)
  "Return an alist of (KIND . NAME) for the move ranges under ROOT.
WP is the prefix bound to the main WordprocessingML namespace.  The move
name lives on w:moveFromRangeStart and w:moveToRangeStart rather than on the
w:moveFrom and w:moveTo elements that enclose the text, so it has to be
collected separately and paired up afterwards.  Names are returned in
document order per kind."
  (let ((a-name (docx-view-ooxml--sym wp "name"))
        acc)
    (pcase-dolist (`(,local . ,kind) '(("moveFromRangeStart" . move-from)
                                       ("moveToRangeStart" . move-to)))
      (dolist (node (docx-view-ooxml--descendants
                     root (docx-view-ooxml--sym wp local)))
        (push (cons kind (docx-view-ooxml--attr node a-name)) acc)))
    (nreverse acc)))

(defun docx-view-ooxml-extra-revisions (file)
  "Return the revisions in FILE that pandoc does not report.
See `docx-view-extra-revision'.
Signal `docx-view-bad-archive' when FILE is not a readable archive."
  (unless (docx-view-ooxml--part-names file)
    (signal 'docx-view-bad-archive (list file)))
  (let* ((tree (docx-view-ooxml-parse-part file "word/document.xml"))
         (root (car tree)))
    (when root
      (let* ((wp (docx-view-ooxml--prefix-for root docx-view-ooxml-ns-w "w"))
             (a-author (docx-view-ooxml--sym wp "author"))
             (a-date (docx-view-ooxml--sym wp "date"))
             (a-name (docx-view-ooxml--sym wp "name"))
             (move-names (docx-view-ooxml--move-names root wp))
             acc)
        (pcase-dolist (`(,local . ,kind) docx-view-ooxml--extra-revision-elements)
          (dolist (node (docx-view-ooxml--descendants
                         root (docx-view-ooxml--sym wp local)))
            (push (docx-view-extra-revision-create
                   :kind kind
                   :author (docx-view-ooxml--attr node a-author)
                   :date (docx-view-ooxml--attr node a-date)
                   :name (or (docx-view-ooxml--attr node a-name)
                             ;; Consume the next unused name of this kind.
                             (let ((cell (assq kind move-names)))
                               (when cell
                                 (setq move-names (delq cell move-names))
                                 (cdr cell))))
                   :text (let ((s (string-trim (docx-view-ooxml--text node))))
                           (and (not (string-empty-p s)) s)))
                  acc)))
        ;; Row-level revisions live inside w:trPr, so they need a nested walk.
        (let ((s-trpr (docx-view-ooxml--sym wp "trPr"))
              (s-ins (docx-view-ooxml--sym wp "ins"))
              (s-del (docx-view-ooxml--sym wp "del")))
          (dolist (trpr (docx-view-ooxml--descendants root s-trpr))
            (dolist (pair (list (cons s-ins 'row-insert)
                                (cons s-del 'row-delete)))
              (dolist (node (docx-view-ooxml--descendants trpr (car pair)))
                (push (docx-view-extra-revision-create
                       :kind (cdr pair)
                       :author (docx-view-ooxml--attr node a-author)
                       :date (docx-view-ooxml--attr node a-date))
                      acc)))))
        (nreverse acc)))))

(provide 'docx-view-ooxml)

;;; docx-view-ooxml.el ends here
