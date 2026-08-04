# Makefile for docx-view.
#
# Plain make, on purpose.  eldev and cask are both good, but each is one more
# thing to install before a contributor can run the tests, and this package's
# whole claim is that it needs nothing but Emacs and pandoc.
#
#   make test      run the ERT suite
#   make compile   byte-compile, treating every warning as an error
#   make lint      package-lint and checkdoc
#   make check     all of the above, which is what CI runs
#   make clean     remove .elc files

EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

# docx-view.el must come last: it requires the other three, and byte-compiling
# it first would compile them as a side effect, without the warning settings.
SRC  = docx-view-pandoc.el docx-view-ooxml.el docx-view-render.el docx-view.el
TEST = test/docx-view-test.el
ELC  = $(SRC:.el=.elc) $(TEST:.el=.elc)

.PHONY: all check test compile lint lint-package lint-checkdoc clean help

all: check

check: compile test lint

test:
	$(BATCH) -l $(TEST) -f ert-run-tests-batch-and-exit

# The file names are passed as arguments and read from `command-line-args-left'
# rather than spliced into a quoted list, which would make them symbols.
#
# `byte-compile-error-on-warn' has to be set after bytecomp is loaded.  Binding
# it with `let' on the command line fails: at that point it is still an
# ordinary lexical variable, and defining it as dynamic afterwards is an error.
compile:
	$(BATCH) --eval '(progn \
	  (require (quote bytecomp)) \
	  (setq byte-compile-error-on-warn t) \
	  (dolist (f command-line-args-left) \
	    (unless (byte-compile-file f) (kill-emacs 1))))' $(SRC) $(TEST)

lint: lint-package lint-checkdoc

# package-lint is fetched into a throwaway directory rather than the real
# package directory, so linting never disturbs the user's own installation.
# .dir-locals.el names docx-view.el as the main file; package-lint reads it
# because it calls `emacs-lisp-mode' on a buffer that already has a file name.
lint-package:
	$(BATCH) --eval '(progn \
	  (setq package-user-dir "/tmp/docx-view-lint-elpa") \
	  (require (quote package)) \
	  (add-to-list (quote package-archives) (quote ("melpa" . "https://melpa.org/packages/")) t) \
	  (package-initialize) \
	  (unless (package-installed-p (quote package-lint)) \
	    (package-refresh-contents) \
	    (package-install (quote package-lint))) \
	  (require (quote package-lint)))' \
	  -f package-lint-batch-and-exit $(SRC)

# checkdoc always exits 0 and writes its findings to a buffer, so a naive batch
# run is silent whether the file is clean or not.  The exit status has to be
# derived from that buffer.
#
# Three words are dropped from the verb-voice table, and nothing else is
# relaxed.  "changes" is this package's central noun and the name of an
# argument, and "holds" and "looks" appear only as third-person verbs in
# subordinate clauses ("...unless this buffer still holds a rendered
# document").  In each case the docstring already opens with a proper
# imperative and rewriting it to satisfy the heuristic would make it read
# worse.  The check itself stays on, so a genuine "Returns the..." opening is
# still caught.
lint-checkdoc:
	$(BATCH) --eval '(progn \
	  (require (quote checkdoc)) \
	  (dolist (w (quote ("changes" "holds" "looks"))) \
	    (setq checkdoc-common-verbs-wrong-voice \
	          (assoc-delete-all w checkdoc-common-verbs-wrong-voice))) \
	  (dolist (f command-line-args-left) (checkdoc-file f)) \
	  (let ((buf (get-buffer "*Warnings*"))) \
	    (when (and buf (> (buffer-size buf) 0)) (kill-emacs 1))))' $(SRC) $(TEST)

clean:
	rm -f $(ELC)

help:
	@echo "make test | compile | lint | check | clean"
