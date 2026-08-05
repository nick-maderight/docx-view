;;; docx-view-pandoc.el --- Run pandoc and walk its JSON AST  -*- lexical-binding: t; -*-

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

;; This file owns the pandoc subprocess and the shape of its JSON output.
;;
;; Pandoc is asked for JSON, not for org.  That is not a stylistic choice: the
;; org writer discards every revision and comment span, so `-t org' cannot see
;; the very thing this package exists to show.  JSON keeps them.
;;
;; One invocation is enough for all three view modes.  `--track-changes=all'
;; yields insertions and deletions together, and the accept and reject views
;; are then a local filter over that same tree.  Re-running pandoc per view
;; would be slower and could in principle disagree with itself.
;;
;; AST encoding, as emitted by pandoc 3.x and read with `json-parse-buffer'
;; using `:object-type alist :array-type list':
;;
;;   a tagged node  ((t . "Para") (c . PAYLOAD))
;;   payload types  string   for Str and RawInline content
;;                  number   for ColWidth
;;                  absent   for Space, SoftBreak, LineBreak, HorizontalRule
;;                  list     for everything else
;;
;; A Span is ((t . "Span") (c ATTR INLINES)) where ATTR is (ID CLASSES KEYVALS)
;; and KEYVALS is an alist-like list of two-element lists.  The revision
;; classes are `insertion', `deletion', `paragraph-insertion',
;; `paragraph-deletion', `comment-start' and `comment-end'.
;;
;; Note the trap in ColWidth: its payload is a float such as 0.5.  Any walker
;; that reaches for `length' on every payload will fail with
;; `wrong-type-argument sequencep 0.5'.  `docx-view-pandoc-children' guards
;; against this.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)

(defgroup docx-view nil
  "View .docx files, with their tracked changes and comments, inside Emacs."
  :group 'wp
  :prefix "docx-view-"
  :link '(url-link "https://github.com/nick-maderight/docx-view"))

(defcustom docx-view-pandoc-program "pandoc"
  "Name of, or path to, the pandoc executable."
  :type '(choice (const :tag "Search `exec-path' for pandoc" "pandoc")
                 (file :tag "Explicit path"))
  :group 'docx-view)

(defcustom docx-view-pandoc-extra-args nil
  "Extra command line arguments passed to every pandoc invocation.
Use this for reader extensions, for example \"--extract-media=DIR\".  Do not
put \"--track-changes\" here: docx-view always asks for all changes and then
filters locally, and overriding that would hide the changes it exists to
show."
  :type '(repeat string)
  :group 'docx-view)

(defcustom docx-view-pandoc-timeout 60
  "Seconds to wait for pandoc before giving up on a synchronous conversion."
  :type 'number
  :group 'docx-view)

(define-error 'docx-view-pandoc-error "Pandoc failed to read the document")
(define-error 'docx-view-pandoc-missing
  "Pandoc was not found; see `docx-view-pandoc-program'" 'docx-view-pandoc-error)

;;;; Locating and checking pandoc

(defun docx-view-pandoc-executable ()
  "Return the absolute path to pandoc, or nil when it is not installed."
  (or (and (file-name-absolute-p docx-view-pandoc-program)
           (file-executable-p docx-view-pandoc-program)
           docx-view-pandoc-program)
      (executable-find docx-view-pandoc-program)))

(defun docx-view-pandoc-available-p ()
  "Return non-nil when pandoc can be run."
  (and (docx-view-pandoc-executable) t))

(defvar docx-view-pandoc--version nil
  "Cached result of `docx-view-pandoc-version'.")

(defun docx-view-pandoc-version ()
  "Return pandoc's version as a string, or nil when pandoc is absent.
The result is cached; call `docx-view-pandoc-reset-version' after changing
`docx-view-pandoc-program'."
  (or docx-view-pandoc--version
      (let ((exe (docx-view-pandoc-executable)))
        (when exe
          (setq docx-view-pandoc--version
                (with-temp-buffer
                  (when (eq 0 (call-process exe nil (list t nil) nil "--version"))
                    (goto-char (point-min))
                    (when (re-search-forward "^pandoc.* \\([0-9][0-9.]*\\)" nil t)
                      (match-string 1)))))))))

(defun docx-view-pandoc-reset-version ()
  "Forget the cached pandoc version."
  (setq docx-view-pandoc--version nil))

;;;; Invocation

(defun docx-view-pandoc--args (file)
  "Return the pandoc argument list for converting FILE to a JSON AST."
  (append (list "--from=docx" "--to=json" "--track-changes=all")
          docx-view-pandoc-extra-args
          (list (expand-file-name file))))

(defun docx-view-pandoc--explain (status stderr file)
  "Return a human-readable reason why pandoc exited with STATUS on FILE.
STDERR is pandoc's diagnostic output."
  (let ((trimmed (string-trim (or stderr ""))))
    (cond
     ((not (file-exists-p file))
      (format "No such file: %s" file))
     ((not (file-readable-p file))
      (format "File is not readable: %s" file))
     ((string-match-p "end of central directory" trimmed)
      (format "%s is not a zip container, so it is not a .docx" file))
     ((not (string-empty-p trimmed)) trimmed)
     (t (format "pandoc exited with status %s" status)))))

(defun docx-view-pandoc--parse-buffer ()
  "Parse the current buffer as a pandoc JSON AST and return it.
Signal `docx-view-pandoc-error' when the text is not valid JSON."
  (goto-char (point-min))
  (condition-case err
      (json-parse-buffer :object-type 'alist :array-type 'list
                         :null-object :null :false-object nil)
    (error
     (signal 'docx-view-pandoc-error
             (list (format "Could not parse pandoc's JSON output: %s"
                           (error-message-string err)))))))

(defun docx-view-pandoc-ast (file)
  "Convert FILE with pandoc and return the parsed JSON AST.
Signal `docx-view-pandoc-missing' when pandoc is absent, or
`docx-view-pandoc-error' when the conversion fails."
  (let ((exe (docx-view-pandoc-executable)))
    (unless exe (signal 'docx-view-pandoc-missing (list docx-view-pandoc-program)))
    (let ((err-file (make-temp-file "docx-view-stderr")))
      (unwind-protect
          (with-temp-buffer
            (let ((status (apply #'call-process exe nil (list t err-file) nil
                                 (docx-view-pandoc--args file))))
              (unless (eq status 0)
                (signal 'docx-view-pandoc-error
                        (list (docx-view-pandoc--explain
                               status
                               (with-temp-buffer
                                 (ignore-errors (insert-file-contents err-file))
                                 (buffer-string))
                               file))))
              (docx-view-pandoc--parse-buffer)))
        (ignore-errors (delete-file err-file))))))

(defun docx-view-pandoc-ast-async (file callback)
  "Convert FILE with pandoc asynchronously and call CALLBACK with the result.
CALLBACK is called with two arguments, AST and ERROR.  Exactly one of them is
non-nil: on success AST is the parsed tree, and on failure ERROR is a string
explaining what went wrong.  Return the process, or nil when pandoc is
absent (CALLBACK is still called, with an error)."
  (let ((exe (docx-view-pandoc-executable)))
    (if (not exe)
        (progn (funcall callback nil
                        (format "Pandoc not found (looked for %S)"
                                docx-view-pandoc-program))
               nil)
      (let* ((stdout (generate-new-buffer " *docx-view-pandoc*"))
             (stderr (generate-new-buffer " *docx-view-pandoc-stderr*"))
             (proc (make-process
                    :name "docx-view-pandoc"
                    :buffer stdout
                    :stderr stderr
                    :noquery t
                    :connection-type 'pipe
                    :coding 'utf-8-unix
                    :command (cons exe (docx-view-pandoc--args file)))))
        (set-process-sentinel
         proc
         (lambda (p _event)
           (when (memq (process-status p) '(exit signal))
             (let ((status (process-exit-status p))
                   (out (process-buffer p)))
               (unwind-protect
                   (if (eq status 0)
                       (condition-case err
                           (funcall callback
                                    (with-current-buffer out
                                      (docx-view-pandoc--parse-buffer))
                                    nil)
                         (error (funcall callback nil (error-message-string err))))
                     (funcall callback nil
                              (docx-view-pandoc--explain
                               status
                               (with-current-buffer stderr (buffer-string))
                               file)))
                 (when (buffer-live-p out) (kill-buffer out))
                 (when (buffer-live-p stderr) (kill-buffer stderr)))))))
        ;; The stderr buffer has no sentinel of its own; the process filter
        ;; above owns it.  Give it a dummy sentinel so Emacs does not report
        ;; the pipe process as an orphan on exit.
        (let ((sp (get-buffer-process stderr)))
          (when sp (set-process-sentinel sp #'ignore)))
        proc))))

;;;; AST accessors
;;
;; These are deliberately tiny and total: given anything at all they return
;; something sensible rather than signalling, because a document is untrusted
;; input and a viewer must not break on an unexpected node.

(defsubst docx-view-pandoc-node-p (node)
  "Return non-nil when NODE is a tagged pandoc AST node."
  (and (consp node) (consp (car node))
       (eq (caar node) t) (stringp (cdar node))))

(defsubst docx-view-pandoc-tag (node)
  "Return the tag of NODE as a string, or nil when NODE is not a node."
  (and (docx-view-pandoc-node-p node) (cdar node)))

(defsubst docx-view-pandoc-payload (node)
  "Return the `c' payload of NODE, or nil when it has none."
  (and (consp node) (cdr (assq 'c node))))

(defun docx-view-pandoc-children (node)
  "Return the child list of NODE, or nil when its payload is not a list.
This is the guard against ColWidth, whose payload is a float, and against
Str, whose payload is a string."
  (let ((c (docx-view-pandoc-payload node)))
    (and (consp c) (proper-list-p c) c)))

(defun docx-view-pandoc-blocks (ast)
  "Return the top-level block list of AST."
  (alist-get 'blocks ast))

(defun docx-view-pandoc-api-version (ast)
  "Return the pandoc-api-version of AST as a list of integers."
  (alist-get 'pandoc-api-version ast))

(defun docx-view-pandoc-meta (ast)
  "Return the metadata alist of AST."
  (alist-get 'meta ast))

;;;; Span attributes

(defsubst docx-view-pandoc-attr-id (attr)
  "Return the identifier from a pandoc ATTR triple."
  (nth 0 attr))

(defsubst docx-view-pandoc-attr-classes (attr)
  "Return the class list from a pandoc ATTR triple."
  (nth 1 attr))

(defun docx-view-pandoc-attr-get (attr key)
  "Return the value of KEY in the key/value list of a pandoc ATTR triple.
KEY is a string such as \"author\" or \"date\"."
  (cadr (assoc key (nth 2 attr))))

(defun docx-view-pandoc-span-attr (node)
  "Return the ATTR triple of Span NODE."
  (car (docx-view-pandoc-children node)))

(defun docx-view-pandoc-span-inlines (node)
  "Return the inline children of Span NODE."
  (cadr (docx-view-pandoc-children node)))

(defconst docx-view-pandoc-revision-classes
  '("insertion" "deletion" "paragraph-insertion" "paragraph-deletion")
  "Span classes by which pandoc reports a tracked change.")

(defconst docx-view-pandoc-comment-classes
  '("comment-start" "comment-end")
  "Span classes by which pandoc reports a comment anchor.")

(defun docx-view-pandoc-span-kind (node)
  "Return the docx-view kind symbol for Span NODE, or nil.
The kinds are `insertion', `deletion', `paragraph-insertion',
`paragraph-deletion', `comment-start' and `comment-end'."
  (when (equal (docx-view-pandoc-tag node) "Span")
    (let ((classes (docx-view-pandoc-attr-classes
                    (docx-view-pandoc-span-attr node))))
      (catch 'found
        (dolist (c (append docx-view-pandoc-revision-classes
                           docx-view-pandoc-comment-classes))
          (when (member c classes) (throw 'found (intern c))))
        nil))))

;;;; Plain text extraction
;;
;; Used for summaries, for the change list, and for `imenu'.

(defconst docx-view-pandoc--content-index
  '(("Span" . 1) ("Link" . 1) ("Image" . 1) ("Div" . 1)
    ("Header" . 2) ("Quoted" . 1) ("Cite" . 1) ("Figure" . 2))
  "Which child of a node holds its content, for tags that also carry an ATTR.
Descending blindly into such a node would treat the identifier, the class
list, the key/value pairs and the link target as if they were body text, so
a Span reporting an author would leak that author's name into the prose.")

(defun docx-view-pandoc-stringify (node &optional keep-comments)
  "Return the visible text of NODE, flattening all structure.
Space and SoftBreak become a space; LineBreak becomes a newline.

Deletions are included: callers that want only surviving text should filter
the tree with `docx-view-pandoc-filter-changes' first.

Comment bodies are excluded unless KEEP-COMMENTS is non-nil.  This matters
because pandoc puts the whole text of a comment inside the `comment-start'
span rather than off to one side, so a walker that descends into that span
silently splices the reviewer's remarks into the author's prose."
  (cond
   ((stringp node) node)
   ((not (consp node)) "")
   ((docx-view-pandoc-node-p node)
    (let* ((tag (docx-view-pandoc-tag node))
           (c (docx-view-pandoc-payload node))
           (index (cdr (assoc tag docx-view-pandoc--content-index))))
      (cond
       ((member tag '("Str" "Code" "Math" "RawInline" "RawBlock" "CodeBlock"))
        ;; Str carries a bare string; the others carry a list whose last
        ;; element is the literal text.
        (if (stringp c) c (or (car (last (and (proper-list-p c) c))) "")))
       ((member tag '("Space" "SoftBreak")) " ")
       ((equal tag "LineBreak") "\n")
       ((member tag '("HorizontalRule" "ColWidth" "ColWidthDefault")) "")
       ((and (not keep-comments)
             (memq (docx-view-pandoc-span-kind node) '(comment-start comment-end)))
        "")
       (index (docx-view-pandoc-stringify
               (nth index (docx-view-pandoc-children node)) keep-comments))
       (t (docx-view-pandoc-stringify (docx-view-pandoc-children node)
                                      keep-comments)))))
   ((proper-list-p node)
    (mapconcat (lambda (x) (docx-view-pandoc-stringify x keep-comments)) node ""))
   ;; A dotted pair that is not a tagged node: take the tail only, since the
   ;; head of such a pair is a key rather than content.
   (t (docx-view-pandoc-stringify (cdr node) keep-comments))))

;;;; View filtering
;;
;; The accept and reject previews are a pure transform of the `all' tree.
;; Deleting a Span means splicing its children into the parent inline list,
;; which is why this returns a list of replacements rather than one node.

(defun docx-view-pandoc--collapse-spaces (nodes)
  "Return NODES with each run of Space or SoftBreak reduced to its first.

Word writes a deletion with the spaces that surround it as separate runs, so
\"<ins>clearly</ins> <del>somewhat</del> shows\" arrives as Span, Space,
Span, Space, Str.  Dropping the deletion leaves the two Space nodes next to
each other and the accepted text reads \"clearly  shows\".

Measured across every fixture: pandoc's docx reader never emits two adjacent
Space nodes of its own, in any of the three track-changes modes, so this only
undoes what filtering just did.  Pandoc's own accept pass collapses them the
same way."
  (let (acc previous-was-space)
    (dolist (node nodes (nreverse acc))
      (let ((space (and (docx-view-pandoc-node-p node)
                        (member (docx-view-pandoc-tag node)
                                '("Space" "SoftBreak"))
                        t)))
        (unless (and space previous-was-space)
          (push node acc))
        (setq previous-was-space space)))))

(defun docx-view-pandoc-filter-changes (nodes mode)
  "Return NODES rewritten for MODE, one of `all', `accept' or `reject'.

With `accept', deletions are dropped and insertions are unwrapped, giving
the document as it would read if every change were taken.  With `reject' the
opposite.  With `all', NODES is returned unchanged.

Comment spans are left alone in every mode: whether a comment is shown is a
separate decision from whether a change is applied."
  (if (eq mode 'all)
      nodes
    (let ((drop (if (eq mode 'accept)
                    '(deletion paragraph-deletion)
                  '(insertion paragraph-insertion)))
          acc)
      (dolist (node nodes (docx-view-pandoc--collapse-spaces (nreverse acc)))
        (let ((kind (and (docx-view-pandoc-node-p node)
                         (docx-view-pandoc-span-kind node))))
          (cond
           ;; A revision span that this mode discards: drop it whole.
           ((memq kind drop) nil)
           ;; A revision span that this mode keeps: splice its children into
           ;; the parent, so accepted text reads as ordinary prose rather
           ;; than as a still-marked change.
           ((memq kind '(insertion deletion paragraph-insertion
                                   paragraph-deletion))
            (setq acc (nconc (nreverse (docx-view-pandoc-filter-changes
                                        (docx-view-pandoc-span-inlines node)
                                        mode))
                             acc)))
           ;; Any other tagged node: rebuild it with a filtered payload.  The
           ;; payload cell must be replaced in place, keeping every other
           ;; cell of the alist, and only when it really is a list.
           ((docx-view-pandoc-node-p node)
            (let ((c (docx-view-pandoc-payload node)))
              (push (if (and (consp c) (proper-list-p c))
                        (mapcar (lambda (cell)
                                  (if (eq (car-safe cell) 'c)
                                      (cons 'c (docx-view-pandoc-filter-changes
                                                c mode))
                                    cell))
                                node)
                      node)
                    acc)))
           ;; A bare list, such as a table row or a list item: recurse.
           ((and (consp node) (proper-list-p node))
            (push (docx-view-pandoc-filter-changes node mode) acc))
           ;; Anything else -- a string, a number, `:null', a dotted pair --
           ;; passes through untouched.
           (t (push node acc))))))))

(provide 'docx-view-pandoc)

;;; docx-view-pandoc.el ends here
