;;; docx-view.el --- View .docx tracked changes and comments  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Nick

;; Author: Nick <nick@maderightsoftware.com>
;; Maintainer: Nick <nick@maderightsoftware.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, files, wp, outlines
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

;; Read a .docx in Emacs with its tracked changes and its comments visible,
;; rendered as org text.  The point is collaboration: reviewing what a
;; colleague changed and what they said about it, without leaving Emacs and
;; without a word processor.
;;
;; This is a viewer.  It does not convert, and it does not write.  A .docx
;; opened here can never be modified by Emacs, by design and with a guard in
;; place to enforce it.
;;
;; Usage:
;;
;;   M-x docx-view-find-file    open a .docx for reading
;;   C-c C-c                    cycle all changes / accepted / rejected
;;   C-c C-n and C-c C-p        move between changes
;;   C-c C-l                    list every change in a side buffer
;;   C-c C-o                    show the comment or change at point
;;   C-c C-a                    show only one reviewer's changes
;;
;; After installation, opening any .docx file uses this mode automatically.
;;
;; Requirements: pandoc, and the unzip program.  Both are checked for at
;; startup with an explanatory message rather than a backtrace.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'subr-x)
(require 'docx-view-pandoc)
(require 'docx-view-ooxml)
(require 'docx-view-render)

(declare-function dired-get-file-for-visit "dired")

;;;; Options

(defcustom docx-view-default-mode 'all
  "Which revisions are shown when a document is first opened."
  :type '(choice (const :tag "All changes, marked up" all)
                 (const :tag "As if every change were accepted" accept)
                 (const :tag "As if every change were rejected" reject))
  :group 'docx-view)

(defcustom docx-view-show-warnings t
  "Whether to report in the echo area what the reader could not represent."
  :type 'boolean
  :group 'docx-view)

(defcustom docx-view-startup-folded nil
  "Whether a document opens with its headings folded."
  :type 'boolean
  :group 'docx-view)

;;;; Buffer-local state
;;
;; A rendered buffer keeps visiting the .docx it came from, the way
;; `archive-mode' and `image-mode' do.  Clearing `buffer-file-name' would be
;; one way to make the file unwritable, but it breaks revert, dired and the
;; mode line, and it turns C-x C-s into a prompt for a filename.  The file is
;; protected by `docx-view--protect-buffer' instead, which was measured to
;; work where read-only alone does not.

(defvar-local docx-view--file nil
  "Absolute path of the .docx this buffer is showing.")

(defvar-local docx-view--document nil
  "The `docx-view-document' currently rendered.")

(defvar-local docx-view--mode nil
  "Which revisions this buffer is showing: `all', `accept' or `reject'.")

(defvar-local docx-view--author-filter nil
  "When non-nil, only changes by this author are marked.")

(defvar-local docx-view--overlays nil
  "Overlays applied by `docx-view--apply-overlays'.")

;;;; The change link type
;;
;; Registration happens at load time, not in the mode function.  Until the
;; type is registered org parses "[[dvchg:ins-1][very]]" as a fuzzy internal
;; link whose path is the whole string, so every org-element query for our
;; links comes back empty while the buffer still looks correct -- a failure
;; that is invisible until something depends on it.

(defun docx-view-follow-change (key &optional _arg)
  "Show the change or comment identified by KEY."
  (let ((change (docx-view-change-by-key key)))
    (if change
        (docx-view--describe-change change)
      (message "docx-view: no change with key %s" key))))

(defun docx-view-change-face (key)
  "Return the face for the change link identified by KEY.
Returning a face rather than a fixed one is what lets an insertion and a
deletion look different, and one reviewer differ from another, without a
separate link type per case."
  (let* ((change (docx-view-change-by-key key))
         (kind (and change (docx-view-change-kind change)))
         (base (pcase kind
                 ('insertion 'docx-view-insertion)
                 ('deletion 'docx-view-deletion)
                 ((or 'paragraph-insertion 'paragraph-deletion)
                  'docx-view-paragraph-change)
                 ('comment (if (and (docx-view-change-comment change)
                                    (docx-view-comment-resolved
                                     (docx-view-change-comment change)))
                               'docx-view-comment-resolved
                             'docx-view-comment-marker))
                 (_ 'org-link)))
         (author (and change (docx-view-change-author change)))
         (color (and docx-view--document
                     (docx-view-render-author-color
                      author (docx-view-document-authors docx-view--document)))))
    (cond
     ;; A change hidden by the author filter still needs to be legible, so it
     ;; is dimmed rather than removed.
     ((and docx-view--author-filter author
           (not (equal author docx-view--author-filter)))
      'shadow)
     (color (list base (list :foreground color)))
     (t base))))

(defun docx-view-change-help (_window _object position)
  "Return help text for the change link at POSITION."
  (let* ((key (get-text-property position 'docx-view-key))
         (change (and key (docx-view-change-by-key key))))
    (when change (docx-view--change-summary change))))

(org-link-set-parameters
 docx-view-render-link-type
 :follow #'docx-view-follow-change
 :face #'docx-view-change-face
 :help-echo "Show this change"
 ;; Exporting a view of somebody else's document is not what this package is
 ;; for, and silently emitting a broken link would be worse than nothing.
 :export (lambda (_path desc _backend _info) (or desc "")))

;;;; Looking changes up

(defun docx-view-change-by-key (key)
  "Return the change with KEY in the current buffer, or nil."
  (when docx-view--document
    (seq-find (lambda (c) (equal (docx-view-change-key c) key))
              (docx-view-document-changes docx-view--document))))

(defun docx-view-change-at-point (&optional pos)
  "Return the change at POS, or at point, or nil."
  (let ((pos (or pos (point))))
    (or (get-text-property pos 'docx-view-key)
        ;; The link's own text carries the property; just past the end of a
        ;; link it does not, which is where point often is after a search.
        (and (> pos (point-min)) (get-text-property (1- pos) 'docx-view-key)))))

;;;; Rendering into the buffer

(defun docx-view--check-requirements ()
  "Signal a `user-error' when a required external program is missing."
  (unless (docx-view-pandoc-available-p)
    (user-error "Docx-view needs pandoc; install it, or set `docx-view-pandoc-program'"))
  (unless (executable-find docx-view-unzip-program)
    (user-error "Docx-view needs the %s program to read comments"
                docx-view-unzip-program)))

(defconst docx-view--zip-magic '("PK\3\4" "PK\5\6" "PK\7\10")
  "Leading bytes of a zip archive: an entry, an empty archive, a spanned one.
A .docx is a zip, so these are the first four bytes of every real one.")

(defun docx-view-file-p (file)
  "Return non-nil when FILE looks like a Word document.
Only four bytes are read, so this is cheap enough to run before deciding
what to do with a buffer.  The check exists because entering this mode
erases the buffer, and erasing a buffer that holds something else -- an org
file the mode was invoked on by mistake, say -- would throw away work."
  (and (stringp file) (file-regular-p file) (file-readable-p file)
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (ignore-errors
           (insert-file-contents-literally file nil 0 4)
           (and (member (buffer-string) docx-view--zip-magic) t)))))

(defun docx-view--kind-label (kind)
  "Return a plain-language label for change KIND."
  (pcase kind
    ('insertion "inserted")
    ('deletion "deleted")
    ('paragraph-insertion "paragraph split here")
    ('paragraph-deletion "paragraph merged with the next")
    ('comment "comment")
    (_ (symbol-name kind))))

(defun docx-view--change-summary (change)
  "Return a one-line description of CHANGE."
  (let ((comment (docx-view-change-comment change)))
    (concat
     (docx-view--kind-label (docx-view-change-kind change))
     (let ((a (docx-view-change-author change)))
       (if a (format " by %s" a) ""))
     (let ((d (docx-view-change-date change)))
       (if d (format " on %s" (docx-view-render-format-date d)) ""))
     (cond
      ((and comment (docx-view-comment-resolved comment)) " (resolved)")
      ((and comment (not (docx-view-comment-anchored comment))) " (unanchored)")
      (t ""))
     (let ((text (docx-view-change-text change)))
       (if (and text (not (string-empty-p text)))
           (format ": %s" (truncate-string-to-width
                           (replace-regexp-in-string "\n+" " " text) 60 nil nil t))
         "")))))

(defun docx-view--apply-overlays (changes)
  "Put an overlay on each of CHANGES in the current buffer.
The overlay carries the styling and the key.  Text properties are set too,
because `help-echo' and the change key must be readable from a position
without searching the overlay list."
  (mapc #'delete-overlay docx-view--overlays)
  (setq docx-view--overlays nil)
  (with-silent-modifications
    (dolist (change changes)
      (let ((beg (docx-view-change-beg change))
            (end (docx-view-change-end change)))
        (when (and beg end (< beg end) (<= end (point-max)))
          (let ((ov (make-overlay beg end nil t nil)))
            (overlay-put ov 'docx-view t)
            (overlay-put ov 'docx-view-key (docx-view-change-key change))
            (overlay-put ov 'evaporate t)
            (overlay-put ov 'help-echo (docx-view--change-summary change))
            (push ov docx-view--overlays))
          (put-text-property beg end 'docx-view-key
                             (docx-view-change-key change))
          (put-text-property beg end 'help-echo #'docx-view-change-help))))))

(defun docx-view--comment-range-face ()
  "Highlight the stretch of text each comment annotates.
Only the marker's own extent is highlighted for now: pandoc gives the range
as a pair of anchors and reconstructing the exact span would mean tracking
offsets through the whole render, which buys little when the marker already
sits at the range's start."
  nil)

(defun docx-view--render ()
  "Render `docx-view--file' into the current buffer at `docx-view--mode'."
  (let* ((inhibit-read-only t)
         (doc (docx-view-render-document docx-view--file docx-view--mode)))
    (setq docx-view--document doc)
    (erase-buffer)
    ;; The buffer may still be unibyte from `find-file' having read the
    ;; archive, in which case inserting the rendered text would mangle every
    ;; character above ASCII.
    (set-buffer-multibyte t)
    (insert (format "#+title: %s\n" (file-name-nondirectory docx-view--file)))
    (insert "#+startup: showall\n")
    (let ((authors (docx-view-document-authors doc)))
      (when authors
        (insert (format "#+subtitle: reviewed by %s\n"
                        (string-join authors ", ")))))
    (insert (format "* %s\n" (docx-view--header-line doc)))
    (insert (docx-view-document-text doc))
    (docx-view-render-locate-changes (docx-view-document-changes doc))
    (docx-view--apply-overlays (docx-view-document-changes doc))
    (goto-char (point-min))
    (set-buffer-modified-p nil)
    (if docx-view-startup-folded (org-overview) (org-fold-show-all))
    (when (and docx-view-show-warnings (docx-view-document-warnings doc))
      (message "docx-view: %s"
               (string-join (docx-view-document-warnings doc); one line each
                            "; ")))))

(defun docx-view--header-line (doc)
  "Return the summary heading text for DOC."
  (let* ((changes (docx-view-document-changes doc))
         (revisions (seq-remove (lambda (c) (eq (docx-view-change-kind c) 'comment))
                                changes))
         (comments (docx-view-document-comments doc))
         (extra (docx-view-document-extra doc)))
    (format "%s: %d change%s, %d comment%s%s"
            (pcase docx-view--mode
              ('all "All changes") ('accept "Changes accepted")
              ('reject "Changes rejected") (_ "Document"))
            (length revisions) (if (= 1 (length revisions)) "" "s")
            (length comments) (if (= 1 (length comments)) "" "s")
            (if extra (format ", %d unshown revision%s" (length extra)
                              (if (= 1 (length extra)) "" "s"))
              ""))))

;;;; Write protection
;;
;; This matters more than it looks.  Setting `buffer-read-only' alone does NOT
;; protect the file: it stops interactive editing but not `save-buffer', and a
;; save would write the rendered org text over the binary .docx and destroy
;; it.  Measured, and confirmed by the file's checksum changing.
;;
;; Clearing `buffer-file-name' would also prevent it, but that breaks revert,
;; dired integration and the mode line, and turns C-x C-s into a prompt for a
;; filename.  A `write-contents-functions' entry that signals is the guard
;; that protects the file without breaking anything else.

(defun docx-view--refuse-write ()
  "Refuse to write this buffer, and say why.
Returning non-nil would tell Emacs the buffer had been saved; signalling
first means it never gets that far.

Note what this does and does not cover.  `save-buffer' is stopped before any
byte is written, so the .docx is safe.  `write-file' is stopped too, but only
after it has already called `set-visited-file-name': the buffer ends up
visiting the new name with this mode's local variables killed, which is
harmless -- the .docx is untouched and the new file is never written -- but
it does mean the buffer stops being a docx view.  That is why the commands
check `docx-view--ensure-document' rather than assuming."
  (user-error "This is a read-only view of %s; docx-view never writes .docx files"
              (if docx-view--file
                  (file-name-nondirectory docx-view--file)
                "a document")))

(defun docx-view--protect-buffer ()
  "Make it impossible for this buffer to overwrite the file it came from.

Measured, on a copy of a real .docx: with no guard, or with only
`buffer-read-only' set, `save-buffer' writes the rendered org text over the
document and the file's checksum changes -- read-only stops interactive
editing but not saving.  A `write-contents-functions' entry that signals
leaves the file byte-identical, and also covers `write-file', so
\\[write-file] cannot be used to sidestep it."
  (add-hook 'write-contents-functions #'docx-view--refuse-write nil t)
  (setq buffer-read-only t)
  ;; Without this, killing Emacs asks whether to save a buffer that must
  ;; never be saved.
  (setq buffer-offer-save nil)
  ;; An auto-save would drop a #file.docx# of org text beside the document.
  (setq-local buffer-auto-save-file-name nil)
  (auto-save-mode -1)
  ;; The rendered text is generated, so a backup of it means nothing.
  (setq-local backup-inhibited t))

;;;; Commands
;;
;; `write-file' calls `set-visited-file-name', which kills the buffer's local
;; variables and re-runs `set-auto-mode' -- so a buffer can leave this mode
;; behind while its keybindings are still on screen.  Measured: a command
;; that assumed `docx-view--file' was set signalled a wrong-type-argument.
;; Every command therefore checks first and reports in plain language.

(defun docx-view--ensure-document ()
  "Signal a `user-error' unless this buffer still holds a rendered document."
  (unless (and docx-view--file docx-view--document)
    (user-error "This buffer is no longer showing a .docx; use `docx-view-find-file'")))

(defun docx-view-set-mode (mode)
  "Show revisions according to MODE: `all', `accept' or `reject'."
  (interactive
   (list (intern (completing-read "Show: " '("all" "accept" "reject") nil t))))
  (unless (memq mode '(all accept reject))
    (user-error "Unknown mode: %s" mode))
  (docx-view--ensure-document)
  (setq docx-view--mode mode)
  (let ((line (line-number-at-pos)))
    (docx-view--render)
    (goto-char (point-min))
    (forward-line (1- line)))
  (message "docx-view: showing %s"
           (pcase mode
             ('all "all changes, marked up")
             ('accept "the document as if every change were accepted")
             ('reject "the document as if every change were rejected"))))

(defun docx-view-cycle-mode ()
  "Cycle between showing all changes, accepted changes and rejected changes."
  (interactive)
  (docx-view--ensure-document)
  (docx-view-set-mode (pcase docx-view--mode
                        ('all 'accept) ('accept 'reject) (_ 'all))))

(defun docx-view-next-change (&optional n)
  "Move to the Nth next change.  N defaults to 1, and may be negative."
  (interactive "p")
  (docx-view--ensure-document)
  (let* ((n (or n 1))
         (positions (sort (delq nil (mapcar #'docx-view-change-beg
                                            (docx-view--visible-changes)))
                          #'<))
         (positions (if (< n 0) (nreverse positions) positions))
         (target (nth (1- (abs n))
                      (seq-filter (lambda (p) (if (< n 0) (< p (point))
                                                (> p (point))))
                                  positions))))
    (if (not target)
        (message "docx-view: no %s change" (if (< n 0) "previous" "further"))
      (goto-char target)
      (message "%s" (docx-view--change-summary
                     (docx-view-change-by-key (docx-view-change-at-point)))))))

(defun docx-view-previous-change (&optional n)
  "Move to the Nth previous change.  N defaults to 1."
  (interactive "p")
  (docx-view-next-change (- (or n 1))))

(defun docx-view--visible-changes ()
  "Return the changes not hidden by the author filter."
  (let ((changes (and docx-view--document
                      (docx-view-document-changes docx-view--document))))
    (if (not docx-view--author-filter)
        changes
      (seq-filter (lambda (c) (equal (docx-view-change-author c)
                                     docx-view--author-filter))
                  changes))))

(defun docx-view--describe-change (change)
  "Show CHANGE in detail, in the echo area or a help buffer."
  (let ((comment (docx-view-change-comment change)))
    (if (not comment)
        (message "%s" (docx-view--change-summary change))
      (let ((thread (docx-view--thread-of comment)))
        (with-help-window "*docx-view comment*"
          (princ (format "Comment %s\n\n" (docx-view-comment-id comment)))
          (dolist (c thread)
            (princ (format "%s%s%s%s\n"
                           (or (docx-view-comment-author c) "Unknown")
                           (let ((e (docx-view-comment-email c)))
                             (if e (format " <%s>" e) ""))
                           (let ((d (docx-view-comment-date c)))
                             (if d (format ", %s" (docx-view-render-format-date d)) ""))
                           (if (docx-view-comment-resolved c) " (resolved)" "")))
            (dolist (para (docx-view-comment-paragraphs c))
              (princ (format "    %s\n" para)))
            (princ "\n")))))))

(defun docx-view--thread-of (comment)
  "Return the thread COMMENT belongs to, root first."
  (let* ((all (docx-view-document-comments docx-view--document))
         (threads (docx-view-ooxml-comment-threads all)))
    (or (seq-find (lambda (thread)
                    (seq-find (lambda (c) (eq c comment)) thread))
                  threads)
        (list comment))))

(defun docx-view-show-at-point ()
  "Show the change or comment at point."
  (interactive)
  (let* ((key (docx-view-change-at-point))
         (change (and key (docx-view-change-by-key key))))
    (if change
        (docx-view--describe-change change)
      (message "docx-view: no change at point"))))

(defun docx-view-filter-author (author)
  "Mark only the changes made by AUTHOR.  An empty AUTHOR clears the filter."
  (interactive
   (list (completing-read
          "Show changes by (empty for all): "
          (and docx-view--document (docx-view-document-authors docx-view--document))
          nil nil)))
  (docx-view--ensure-document)
  (setq docx-view--author-filter (and (not (string-empty-p author)) author))
  ;; The face is computed per link, so a redisplay is all that is needed.
  (font-lock-flush)
  (message "docx-view: %s"
           (if docx-view--author-filter
               (format "showing changes by %s" docx-view--author-filter)
             "showing changes by everyone")))

(defun docx-view-revert (&optional _ignore-auto _noconfirm)
  "Re-read the document from disk.
The normal revert would reinstate the .docx bytes; this re-renders instead."
  (interactive)
  (unless docx-view--file (user-error "This buffer is not showing a file"))
  (condition-case err
      (progn (docx-view--render)
             (message "docx-view: re-read %s"
                      (file-name-nondirectory docx-view--file)))
    (error (docx-view--render-failure err))))

(defun docx-view-open-externally ()
  "Open the underlying .docx with the system's own handler."
  (interactive)
  (unless docx-view--file (user-error "This buffer is not showing a file"))
  (if (fboundp 'browse-url-of-file)
      (browse-url-of-file docx-view--file)
    (user-error "Cannot open %s externally" docx-view--file)))

;;;; The change list

(defvar-local docx-view-list--source nil
  "Buffer whose changes a change-list buffer is showing.")

(defun docx-view-list-changes ()
  "Show every change in the document in a separate buffer."
  (interactive)
  (unless docx-view--document (user-error "No document in this buffer"))
  (let ((source (current-buffer))
        (changes (docx-view-document-changes docx-view--document))
        (buffer (get-buffer-create "*docx-view changes*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (docx-view-list-mode)
        (setq docx-view-list--source source)
        (if (null changes)
            (insert "This document has no tracked changes and no comments.\n")
          (dolist (change changes)
            (let ((start (point)))
              (insert (format "%-28s %s\n"
                              (concat (docx-view--kind-label
                                       (docx-view-change-kind change))
                                      (let ((a (docx-view-change-author change)))
                                        (if a (concat " / " a) "")))
                              (let ((text (docx-view-change-text change)))
                                (truncate-string-to-width
                                 (replace-regexp-in-string
                                  "\n+" " " (or text "")) 90 nil nil t))))
              (put-text-property start (point) 'docx-view-key
                                 (docx-view-change-key change)))))
        (goto-char (point-min))
        (set-buffer-modified-p nil)))
    (display-buffer buffer)))

(defun docx-view-list-visit ()
  "Go to the change described on this line, in the document buffer."
  (interactive)
  (let ((key (get-text-property (point) 'docx-view-key))
        (source docx-view-list--source))
    (cond
     ((not (buffer-live-p source)) (user-error "The document buffer is gone"))
     ((not key) (user-error "No change on this line"))
     (t
      (pop-to-buffer source)
      (let ((change (docx-view-change-by-key key)))
        (when (and change (docx-view-change-beg change))
          (goto-char (docx-view-change-beg change))
          (message "%s" (docx-view--change-summary change))))))))

;; `defvar-keymap' would read better here, but it arrived in Emacs 29.1 and
;; this package supports 27.1, so the keymaps are built the portable way.
;; Depending on the compat package to get the nicer macro would cost the
;; package its only virtue of having no dependencies at all.
(defvar docx-view-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'docx-view-list-visit)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `docx-view-list-mode'.")

(define-derived-mode docx-view-list-mode special-mode "DocxChanges"
  "Major mode for the list of changes in a .docx file."
  (setq truncate-lines t))

;;;; The major mode

(defvar docx-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map org-mode-map)
    (define-key map (kbd "C-c C-c") #'docx-view-cycle-mode)
    (define-key map (kbd "C-c C-n") #'docx-view-next-change)
    (define-key map (kbd "C-c C-p") #'docx-view-previous-change)
    (define-key map (kbd "C-c C-l") #'docx-view-list-changes)
    (define-key map (kbd "C-c C-o") #'docx-view-show-at-point)
    (define-key map (kbd "C-c C-a") #'docx-view-filter-author)
    (define-key map (kbd "C-c C-e") #'docx-view-open-externally)
    (define-key map (kbd "C-c C-v") #'docx-view-set-mode)
    (define-key map (kbd "g") #'docx-view-revert)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `docx-view-mode'.")

(easy-menu-define docx-view-menu docx-view-mode-map
  "Menu for `docx-view-mode'."
  '("Docx"
    ["Show all changes" (docx-view-set-mode 'all)
     :style radio :selected (eq docx-view--mode 'all)]
    ["Show changes accepted" (docx-view-set-mode 'accept)
     :style radio :selected (eq docx-view--mode 'accept)]
    ["Show changes rejected" (docx-view-set-mode 'reject)
     :style radio :selected (eq docx-view--mode 'reject)]
    "---"
    ["Next change" docx-view-next-change]
    ["Previous change" docx-view-previous-change]
    ["List all changes" docx-view-list-changes]
    ["Show change at point" docx-view-show-at-point]
    "---"
    ["Filter by author" docx-view-filter-author]
    ["Re-read from disk" docx-view-revert]
    ["Open in external application" docx-view-open-externally]))

(define-derived-mode docx-view-mode org-mode "Docx"
  "Major mode for reading a .docx file with its changes and comments.

The buffer is org text and every org command works, but it is a view: it
cannot be saved over the document it came from.

\\{docx-view-mode-map}"
  :group 'docx-view
  (setq-local revert-buffer-function #'docx-view-revert)
  (setq-local org-hide-emphasis-markers t)
  ;; The buffer is generated, so a folded view on open would hide the point
  ;; of opening it.  `showall' in the rendered header covers the same ground
  ;; for anyone who reads the text outside this mode.
  (setq-local org-startup-folded nil)
  (setq-local imenu-create-index-function #'docx-view--imenu-index)
  (docx-view--protect-buffer)
  ;; `buffer-file-name' is `permanent-local', so it survives the
  ;; `kill-all-local-variables' that every major mode performs; anything set
  ;; before this mode ran does not, which is why the file is read from here
  ;; rather than passed in.
  ;;
  ;; Rendering replaces the buffer's contents, so it happens only once the
  ;; file is known to be an archive.  Invoked by hand on something else, the
  ;; mode leaves the buffer alone and says so, rather than erasing it.
  (cond
   ((not buffer-file-name)
    (setq buffer-read-only nil))
   ((not (docx-view-file-p buffer-file-name))
    (setq buffer-read-only nil)
    (message "docx-view: %s is not a Word document; buffer left as it was"
             (file-name-nondirectory buffer-file-name)))
   (t
    (setq docx-view--file buffer-file-name
          docx-view--mode (or docx-view--mode docx-view-default-mode))
    (condition-case err
        (progn (docx-view--check-requirements) (docx-view--render))
      (error (docx-view--render-failure err))))))

(defun docx-view--render-failure (err)
  "Put an explanation of ERR in the buffer instead of the document."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (set-buffer-multibyte t)
    (insert (format "#+title: %s\n\n"
                    (if docx-view--file
                        (file-name-nondirectory docx-view--file)
                      "docx-view")))
    (insert "* This document could not be read\n\n")
    (insert (error-message-string err) "\n\n")
    (insert "docx-view needs pandoc and unzip on PATH.  Install them, or set\n"
            "`docx-view-pandoc-program' and `docx-view-unzip-program'.\n\n")
    (insert "Type g to try again, or C-c C-e to open the file in another "
            "application.\n")
    (goto-char (point-min))
    (set-buffer-modified-p nil)))

(defun docx-view--imenu-index ()
  "Return an `imenu' index of the document's headings and its changes."
  (let (headings changes)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (push (cons (match-string-no-properties 2) (match-beginning 0)) headings)))
    (dolist (change (and docx-view--document
                         (docx-view-document-changes docx-view--document)))
      (when (docx-view-change-beg change)
        (push (cons (docx-view--change-summary change)
                    (docx-view-change-beg change))
              changes)))
    (append (list (cons "Headings" (nreverse headings)))
            (and changes (list (cons "Changes" (nreverse changes)))))))

;;;; Entry points

;;;###autoload
(defun docx-view-find-file (file)
  "Open FILE, a .docx, in a read-only view showing changes and comments."
  (interactive "fView .docx file: ")
  (let ((file (expand-file-name file)))
    (unless (file-readable-p file)
      (user-error "Cannot read %s" file))
    (docx-view--check-requirements)
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'docx-view-mode) (docx-view-mode)))
      (pop-to-buffer buffer))))

;;;###autoload
(defalias 'docx-view 'docx-view-find-file
  "View a .docx file with its tracked changes and comments.")

;; Rendering happens inside the mode function, so the mode can go straight
;; into `auto-mode-alist' and the buffer keeps visiting the .docx -- which is
;; what `revert-buffer', dired and the mode line all need.  This is the shape
;; `archive-mode' and `image-mode' use for the same reason.
;;
;; The entry goes at the FRONT of the list because Emacs ships a `.docx' entry
;; of its own pointing at `doc-view-mode-maybe'; `add-to-list' without APPEND
;; puts ours ahead of it, and `auto-mode-alist' is searched in order.
;;
;; The macro-enabled and template variants are included because pandoc reads
;; all of them -- verified on .docm, .dotx and .dotm, each of which produced
;; the same block count as the .docx it was copied from.
;;;###autoload
(defconst docx-view-file-name-regexp "\\.do[ct][xm]\\'"
  "Match the file names docx-view offers to render.
Covers .docx and .docm documents and .dotx and .dotm templates, all of which
pandoc's docx reader accepts.")

;;;###autoload
(add-to-list 'auto-mode-alist (cons docx-view-file-name-regexp 'docx-view-mode))

;; `find-file' decides how to decode a file before the major mode runs.  A
;; .docx is a zip, so decoding it as text is wasted work on a file that is
;; about to be erased, and on a large document the org startup scan over that
;; binary was measured at over a second.  Reading it as raw bytes skips both.
;;;###autoload
(add-to-list 'auto-coding-alist (cons docx-view-file-name-regexp 'no-conversion))

;;;###autoload
(defun docx-view-dired-view ()
  "View the .docx file at point in Dired."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a Dired buffer"))
  (docx-view-find-file (dired-get-file-for-visit)))

(provide 'docx-view)

;;; docx-view.el ends here
