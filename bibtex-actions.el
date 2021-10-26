;;; bibtex-actions.el --- Bibliographic commands based on completing-read -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Bruce D'Arcus
;;
;; Author: Bruce D'Arcus <https://github.com/bdarcus>
;; Maintainer: Bruce D'Arcus <https://github.com/bdarcus>
;; Created: February 27, 2021
;; License: GPL-3.0-or-later
;; Version: 0.4
;; Homepage: https://github.com/bdarcus/bibtex-actions
;; Package-Requires: ((emacs "26.3") (bibtex-completion "1.0") (parsebib "3.0"))
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;;  A completing-read front-end for browsing and acting on bibliographic data.
;;
;;  When used with vertico/selectrum/icomplete-vertical, embark, and marginalia,
;;  it provides similar functionality to helm-bibtex and ivy-bibtex: quick
;;  filtering and selecting of bibliographic entries from the minibuffer, and
;;  the option to run different commands against them.
;;
;;; Code:

(eval-when-compile
  (require 'cl-lib)
  (require 'subr-x))
(require 'seq)
(require 'bibtex-actions-file)
(require 'bibtex-completion)
(require 'parsebib)
(require 's)
;; Not ideal, find a better FIX
(require 'reftex)
(require 'oc)

(declare-function org-element-context "org-element")
(declare-function org-element-property "org-element")
(declare-function org-element-type "org-element")
(declare-function org-cite-get-references "org-cite")
(declare-function org-cite-register-processor "org-cite")
(declare-function org-cite-make-insert-processor "org-cite")
(declare-function org-cite-basic--complete-style "org-cite")
(declare-function embark-act "ext:embark")

;;; Declare variables for byte compiler

(defvar crm-separator)
(defvar embark-keymap-alist)
(defvar embark-target-finders)
(defvar embark-general-map)
(defvar embark-meta-map)
(defvar bibtex-actions-file-open-note-function)
(defvar bibtex-actions-file-extensions)
(defvar bibtex-actions-file-open-prompt)
(defvar bibtex-actions-file-variable)

;;; Variables

(defface bibtex-actions
  '((t :inherit font-lock-doc-face))
  "Default Face for `bibtex-actions' candidates."
  :group 'bibtex-actions)

(defface bibtex-actions-highlight
  '((t :weight bold))
  "Face used to highlight content in `bibtex-actions' candidates."
  :group 'bibtex-actions)

(defcustom bibtex-actions-bibliography
  (bibtex-actions-file--normalize-paths bibtex-completion-bibliography)
  "A list of bibliography files."
  ;; The bibtex-completion default is likely to be removed in the future.
  :group 'bibtex-actions
  :type '(repeat file))

(defcustom bibtex-actions-library-paths
  (bibtex-actions-file--normalize-paths bibtex-completion-library-path)
  "A list of files paths for related PDFs, etc."
  ;; The bibtex-completion default is likely to be removed in the future.
  :group 'bibtex-actions
  :type '(repeat path))

(defcustom bibtex-actions-notes-paths
  (bibtex-actions-file--normalize-paths bibtex-completion-notes-path)
  "A list of file paths for bibliographic notes."
  ;; The bibtex-completion default is likely to be removed in the future.
  :group 'bibtex-actions
  :type '(repeat path))

(defcustom bibtex-actions-templates
  '((main . "${author editor:30}     ${date year issued:4}     ${title:48}")
    (suffix . "          ${=key= id:15}    ${=type=:12}    ${tags keywords keywords:*}")
    (note . "#+title: Notes on ${author editor}, ${title}"))
  "Configures formatting for the bibliographic entry.

The main and suffix templates are for candidate display, and note
for the title field for new notes."
    :group 'bibtex-actions
    :type  '(alist :key-type string))

(defcustom bibtex-actions-display-transform-functions
  ;; TODO change this name, as it might be confusing?
  '((t  . bibtex-actions-clean-string)
    (("author" "editor") . bibtex-actions-shorten-names))
  "Configure transformation of field display values from raw values.

All functions that match a particular field are run in order."
  :group 'bibtex-actions
  :type '(alist :key-type   (choice (const t) (repeat string))
                :value-type function))

(defcustom bibtex-actions-symbols
  `((file  .  ("F" . " "))
    (note .   ("N" . " "))
    (link .   ("L" . " ")))
  "Configuration alist specifying which symbol or icon to pick for a bib entry.
This leaves room for configurations where the absense of an item
may be indicated with the same icon but a different face.

To avoid alignment issues make sure that both the car and cdr of a symbol have
the same width."
  :group 'bibtex-actions
  :type '(alist :key-type string
                :value-type (choice (string :tag "Symbol"))))

(defcustom bibtex-actions-symbol-separator " "
  "The padding between prefix symbols."
  :group 'bibtex-actions
  :type 'string)

(defcustom bibtex-actions-force-refresh-hook nil
  "Hook run when user forces a (re-) building of the candidates cache.
This hook is only called when the user explicitly requests the
cache to be rebuilt.  It is intended for 'heavy' operations which
recreate entire bibliography files using an external reference
manager like Zotero or JabRef."
  :group 'bibtex-actions
  :type '(repeat function))

(defcustom bibtex-actions-default-action 'bibtex-actions-open
  "The default action for the `bibtex-actions-at-point' command."
  :group 'bibtex-actions
  :type 'function)

(defcustom bibtex-actions-at-point-fallback 'prompt
  "Fallback action for `bibtex-actions-at-point'.
The action is used when no citation key is found at point.
`prompt' means choosing entries via `bibtex-actions-select-keys'
and nil means no action."
  :group 'bibtex-actions
  :type '(choice (const :tag "Prompt" 'prompt)
                 (const :tag "Ignore" nil)))

(defcustom bibtex-actions-at-point-function 'bibtex-actions-dwim
  "The function to run for 'bibtex-actions-at-point'."
  :group 'bibtex-actions
  :type 'function)

(defcustom bibtex-actions-major-mode-functions
  '(((latex-mode) .
     ((local-bib-files . bibtex-actions-latex--local-bib-files)
      (insert-keys . bibtex-actions-latex--insert-keys)
      (keys-at-point . bibtex-actions-latex--keys-at-point)))
    ((org-mode) .
     ((local-bib-files . org-cite-list-bibliography-files)
      (keys-at-point . bibtex-actions-get-key-org-cite))))
  "The variable determining the major mode specifc functionality.
It is alist with keys being a list of major modes. The value is an alist
with values being functions to be used for these modes while the keys
are symbols used to lookup them up. The keys are

local-bib-files: the corresponding functions should return the list of
local bibliography files.

insert-keys: the corresponding function should insert the list of keys given
to as the argument at point in the buffer.

keys-at-point: the corresponding function should return the list of keys at
point."
  :group 'bibtex-actions
  :type '(alist :key-type (repeat string :tag "Major modes")
                :value-type (set (cons (const local-bib-files) function)
                                 (cons (const insert-keys) function)
                                 (cons (const keys-at-pont function)))))

;;; History, including future history list.

(defvar bibtex-actions-history nil
  "Search history for `bibtex-actions'.")

(defcustom bibtex-actions-presets nil
  "List of predefined searches."
  :group 'bibtex-actions
  :type '(repeat string))

;;; Keymaps

(defvar bibtex-actions-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "t") '("add pdf attachment" . bibtex-actions-add-pdf-attachment))
    (define-key map (kbd "a") '("add pdf to library" . bibtex-actions-add-pdf-to-library))
    (define-key map (kbd "b") '("insert bibtex" . bibtex-actions-insert-bibtex))
    (define-key map (kbd "c") '("insert citation" . bibtex-actions-insert-citation))
    (define-key map (kbd "k") '("insert key" . bibtex-actions-insert-key))
    (define-key map (kbd "fr") '("insert formatted reference" . bibtex-actions-insert-reference))
    (define-key map (kbd "o") '("open source document" . bibtex-actions-open))
    (define-key map (kbd "e") '("open bibtex entry" . bibtex-actions-open-entry))
    (define-key map (kbd "l") '("open source URL or DOI" . bibtex-actions-open-link))
    (define-key map (kbd "n") '("open notes" . bibtex-actions-open-notes))
    (define-key map (kbd "f") '("open library files" . bibtex-actions-open-library-files))
    (define-key map (kbd "r") '("refresh" . bibtex-actions-refresh))
    ;; Embark doesn't currently use the menu description.
    ;; https://github.com/oantolin/embark/issues/251
    (define-key map (kbd "RET") '("default action" . bibtex-actions-run-default-action))
    map)
  "Keymap for 'bibtex-actions'.")

(defvar bibtex-actions-buffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") '("open source document" . bibtex-actions-open))
    (define-key map (kbd "e") '("open bibtex entry" . bibtex-actions-open-entry))
    (define-key map (kbd "l") '("open source URL or DOI" . bibtex-actions-open-link))
    (define-key map (kbd "n") '("open notes" . bibtex-actions-open-notes))
    (define-key map (kbd "f") '("open library files" . bibtex-actions-open-library-files))
    (define-key map (kbd "r") '("refresh library" . bibtex-actions-refresh))
    ;; Embark doesn't currently use the menu description.
    ;; https://github.com/oantolin/embark/issues/251
    (define-key map (kbd "RET") '("default action" . bibtex-actions-run-default-action))
    map)
  "Keymap for Embark citation-key actions.")

;;; Completion functions

(cl-defun bibtex-actions-select-refs (&optional &key rebuild-cache)
  "Select bibliographic references.

Provides a wrapper around 'completing-read-multiple, and returns
an alist of key-entry, where the entry is a field-value alist.

Therefore, for each returned candidate, 'car' is the citekey, and
'cdr' is an alist of structured data.

Includes the following optional argument:

'REBUILD-CACHE' if t, forces rebuilding the cache before
offering the selection candidates."
  (let* ((crm-separator "\\s-*&\\s-*")
         (candidates (bibtex-actions--get-candidates rebuild-cache))
         (chosen
          (completing-read-multiple
           "References: "
           (lambda (string predicate action)
             (if (eq action 'metadata)
                 `(metadata
                   (affixation-function . bibtex-actions--affixation)
                   (category . bib-reference))
               (complete-with-action action candidates string predicate)))
           nil nil nil
           'bibtex-actions-history bibtex-actions-presets nil)))
    (seq-map
     (lambda (choice)
       ;; Collect citation key-entry of selected candidate(s).
       (or (cdr (assoc choice candidates))
           ;; When calling embark at-point, use keys to look up and return the
           ;; selected candidates.
           ;; See https://github.com/bdarcus/bibtex-actions/issues/233#issuecomment-901536901
           (cdr (seq-find (lambda (cand) (equal choice (cadr cand))) candidates))))
     chosen)))

(defun bibtex-actions-select-files (files)
  "Select file(s) from a list of FILES."
  ;; TODO add links to candidates
  (completing-read-multiple
   "Open related file(s): "
   (lambda (string predicate action)
     (if (eq action 'metadata)
         `(metadata
        ; (group-function . bibtex-actions-select-group-related-sources)
           (category . file))
       (complete-with-action action files string predicate)))))

(defun bibtex-actions-select-group-related-sources (file transform)
  "Group by FILE by source, TRANSFORM."
    (let ((extension (file-name-extension file)))
      (when transform file
        ;; Transform for grouping and group title display.
        (pcase extension
          ((or "org" "md") "Notes")
          (_ "Library Files")))))

(defun bibtex-actions-latex--local-bib-files ()
  "Retrieve local bibliographic files for a latex buffer using reftex."
  (reftex-access-scan-info t)
  (ignore-errors (reftex-get-bibfile-list)))

(defun bibtex-actions-latex--keys-at-point ()
  "Return a list of keys at point in a latex buffer."
  (let ((macro (TeX-current-macro)))
    (when (string-match-p "cite" macro)
      (split-string (thing-at-point 'list t) "," t "[{} ]+"))))

(defun bibtex-actions-latex--insert-keys (keys)
  "Insert comma sperated KEYS in a latex buffer."
  (string-join keys ", "))

(defun bibtex-actions--major-mode-function (key &rest args)
  "Function for the major mode corresponding to KEY applied to ARGS."
  (funcall (alist-get key (cdr (seq-find (lambda (x) (memq major-mode (car x)))
                                bibtex-actions-major-mode-functions)))))

(defun bibtex-actions--local-files-to-cache ()
  "The local bibliographic files not included in the global bibliography."
  ;; We cache these locally to the buffer.
  (seq-difference (bibtex-actions-file--normalize-paths
                   (bibtex-actions--major-mode-function 'local-bib-files))
                  (bibtex-actions-file--normalize-paths
                   bibtex-actions-bibliography)))

(defun bibtex-actions-get-value (field item)
  "Return the FIELD value for ITEM."
  (cdr (assoc-string field item 'case-fold)))

(defun bibtex-actions-has-a-value (fields item)
  "Return the first field that has a value in ITEM among FIELDS ."
  (seq-find (lambda (field) (bibtex-actions-get-value field item)) fields))

(defun bibtex-actions-display-value (fields item)
  "Return the first non nil value for ITEM among FIELDS .

The value is transformed using `bibtex-actions-display-transform-functions'"
  (let ((field (bibtex-actions-has-a-value fields item)))
    (seq-reduce (lambda (string fun)
                  (if (or (eq t (car fun))
                          (member field (car fun)))
                      (funcall (cdr fun) string)
                    string))
                bibtex-actions-display-transform-functions
            ;; Make sure we always return a string, even if empty.
                (or (bibtex-actions-get-value field item) ""))))

;; Lifted from bibtex-completion
(defun bibtex-actions-clean-string (s)
  "Remove quoting brackets and superfluous whitespace from string S."
  (replace-regexp-in-string "[\n\t ]+" " "
         (replace-regexp-in-string "[\"{}]+" "" s)))

(defun bibtex-actions-shorten-names (names)
  "Return a list of family names from a list of full NAMES.

To better accomomodate corporate names, this will only shorten
personal names of the form 'family, given'."
  (when (stringp names)
    (mapconcat
     (lambda (name)
       (if (eq 1 (length name))
           (cdr (split-string name " "))
         (car (split-string name ", "))))
     (split-string names " and ") ", ")))

(defun bibtex-actions--fields-for-format (template)
  "Return list of fields for TEMPLATE."
  ;; REVIEW I don't really like this code, but it works correctly.
  ;;        Would be good to at least refactor to remove s dependency.
  (let* ((fields-rx "${\\([^}]+\\)}")
         (raw-fields (seq-mapcat #'cdr (s-match-strings-all fields-rx template))))
    (seq-map
     (lambda (field)
       (car (split-string field ":")))
     (seq-mapcat (lambda (raw-field) (split-string raw-field " ")) raw-fields))))

(defun bibtex-actions--fields-in-formats ()
  "Find the fields to mentioned in the templates."
  (seq-mapcat #'bibtex-actions--fields-for-format
              (list (bibtex-actions-get-template 'main)
                    (bibtex-actions-get-template 'suffix)
                    (bibtex-actions-get-template 'note))))

(defun bibtex-actions--fields-to-parse ()
  "Determine the fields to parse from the template."
  (seq-concatenate
   'list
   (bibtex-actions--fields-in-formats)
   (list "doi" "url" bibtex-actions-file-variable)))

(defun bibtex-actions--format-candidates (bib-files &optional context)
  "Format candidates from BIB-FILES, with optional hidden CONTEXT metadata.
This both propertizes the candidates for display, and grabs the
key associated with each one."
  (let* ((candidates ())
         (raw-candidates
          (parsebib-parse bib-files :fields (bibtex-actions--fields-to-parse)))
         (main-width (bibtex-actions--format-width (bibtex-actions-get-template 'main)))
         (suffix-width (bibtex-actions--format-width (bibtex-actions-get-template 'suffix)))
         (symbols-width (string-width (bibtex-actions--symbols-string t t t)))
         (star-width (- (frame-width) (+ 2 symbols-width main-width suffix-width))))
    (maphash
     (lambda (citekey entry)
       (let* ((files
               (when (bibtex-actions-file--files-for-entry
                      citekey
                      entry
                      bibtex-actions-library-paths
                      bibtex-actions-file-extensions)
                 " has:files"))
              (notes
               (when (bibtex-actions-file--files-for-entry
                      citekey
                      entry
                      bibtex-actions-notes-paths
                      bibtex-actions-file-extensions)
                 " has:notes"))
              (link
               (when (bibtex-actions-has-a-value '("doi" "url") entry)
                 "has:link"))
              (candidate-main
               (bibtex-actions--format-entry
                entry
                star-width
                (bibtex-actions-get-template 'main)))
              (candidate-suffix
               (bibtex-actions--format-entry
                entry
                star-width
                (bibtex-actions-get-template 'suffix)))
              ;; We display this content already using symbols; here we add back
              ;; text to allow it to be searched, and citekey to ensure uniqueness
              ;; of the candidate.
              (candidate-hidden (string-join (list files notes link context citekey) " ")))
         (push
          (cons
           ;; If we don't trim the trailing whitespace,
           ;; 'completing-read-multiple' will get confused when there are
           ;; multiple selected candidates.
           (string-trim-right
            (concat
             ;; We need all of these searchable:
             ;;   1. the 'candidate-main' variable to be displayed
             ;;   2. the 'candidate-suffix' variable to be displayed with a different face
             ;;   3. the 'candidate-hidden' variable to be hidden
             (propertize candidate-main 'face 'bibtex-actions-highlight) " "
             (propertize candidate-suffix 'face 'bibtex-actions) " "
             (propertize candidate-hidden 'invisible t)))
           (cons citekey entry))
          candidates)))
       raw-candidates)
    candidates))

  (defun bibtex-actions--affixation (cands)
    "Add affixation prefix to CANDS."
    (seq-map
     (lambda (candidate)
       (let ((candidate-symbols (bibtex-actions--symbols-string
                                 (string-match "has:files" candidate)
                                 (string-match "has:note" candidate)
                                 (string-match "has:link" candidate))))
         (list candidate candidate-symbols "")))
     cands))

(defun bibtex-actions--symbols-string (has-files has-note has-link)
  "String for display from booleans HAS-FILES HAS-LINK HAS-NOTE."
  (cl-flet ((thing-string (has-thing thing-symbol)
                          (if has-thing
                              (cadr (assoc thing-symbol bibtex-actions-symbols))
                            (cddr (assoc thing-symbol bibtex-actions-symbols)))))
    (seq-reduce (lambda (constructed newpart)
                  (let* ((str (concat constructed newpart
                                      bibtex-actions-symbol-separator))
                         (pos (length str)))
                    (put-text-property (- pos 1) pos 'display
                                       (cons 'space (list :align-to (string-width str)))
                                       str)
                    str))
                (list (thing-string has-files 'file)
                      (thing-string has-note 'note)
                      (thing-string has-link 'link)
                      "")
                "")))

(defvar bibtex-actions--candidates-cache 'uninitialized
  "Store the global candidates list.

Default value of 'uninitialized is used to indicate that cache
has not yet been created")

(defvar-local bibtex-actions--local-candidates-cache 'uninitialized
  ;; We use defvar-local so can maintain per-buffer candidate caches.
  "Store the local (per-buffer) candidates list.")

;;;###autoload
(defun bibtex-actions-refresh (&optional force-rebuild-cache scope)
  "Reload the candidates cache.

If called interactively with a prefix or if FORCE-REBUILD-CACHE
is non-nil, also run the `bibtex-actions-before-refresh-hook' hook.

If SCOPE is `global' only global cache is refreshed, if it is
`local' only local cache is refreshed.  With any other value both
are refreshed."
  (interactive (list current-prefix-arg nil))
  (when force-rebuild-cache
    (run-hooks 'bibtex-actions-force-refresh-hook))
  (unless (eq 'local scope)
    (setq bibtex-actions--candidates-cache
      (bibtex-actions--format-candidates
       bibtex-actions-bibliography)))
  (unless (eq 'global scope)
    (setq bibtex-actions--local-candidates-cache
          (bibtex-actions--format-candidates
           (bibtex-actions--local-files-to-cache) "is:local"))))

(defun bibtex-actions-get-template (template-name)
  "Return template string for TEMPLATE-NAME."
  (cdr (assoc template-name bibtex-actions-templates)))

(defun bibtex-actions--get-candidates (&optional force-rebuild-cache)
  "Get the cached candidates.
If the cache is unintialized, this will load the cache.
If FORCE-REBUILD-CACHE is t, force reload the cache."
  (when force-rebuild-cache
    (bibtex-actions-refresh force-rebuild-cache))
  (when (eq 'uninitialized bibtex-actions--candidates-cache)
    (bibtex-actions-refresh nil 'global))
  (when (eq 'uninitialized bibtex-actions--local-candidates-cache)
    (bibtex-actions-refresh nil 'local))
  (seq-concatenate 'list
                   bibtex-actions--local-candidates-cache
                   bibtex-actions--candidates-cache))

(defun bibtex-actions--get-entry (key)
  "Return the cached entry for KEY."
    (cddr (seq-find
           (lambda (entry)
             (string-equal key (cadr entry)))
           (bibtex-actions--get-candidates))))

(defun bibtex-actions-get-link (entry)
  "Return a link for an ENTRY."
  (let* ((field (bibtex-actions-has-a-value '(doi pmid pmcid url) entry))
         (base-url (pcase field
                     ('doi "https://doi.org/")
                     ('pmid "https://www.ncbi.nlm.nih.gov/pubmed/")
                     ('pmcid "https://www.ncbi.nlm.nih.gov/pmc/articles/"))))
    (when field
      (concat base-url (bibtex-actions-get-value field entry)))))

(defun bibtex-actions--extract-keys (keys-entries)
  "Extract list of keys from KEYS-ENTRIES alist."
  (seq-map #'car keys-entries))

;;;###autoload
(defun bibtex-actions-insert-preset ()
  "Prompt for and insert a predefined search."
  (interactive)
  (unless (minibufferp)
    (user-error "Command can only be used in minibuffer"))
  (when-let ((enable-recursive-minibuffers t)
             (search (completing-read "Preset: " bibtex-actions-presets)))
    (insert search)))

;;; Formatting functions

(defun bibtex-actions--format-width (format-string)
  "Calculate minimal width needed by the FORMAT-STRING."
  (let ((content-width (apply #'+
                              (seq-map #'string-to-number
                                       (split-string format-string ":"))))
        (whitespace-width (string-width (s-format format-string
                                                  (lambda (_) "")))))
    (+ content-width whitespace-width)))

(defun bibtex-actions--fit-to-width (value width)
  "Propertize the string VALUE so that only the WIDTH columns are visible."
  (let* ((truncated-value (truncate-string-to-width value width))
         (display-value (truncate-string-to-width truncated-value width 0 ?\s)))
    (if (> (string-width value) width)
        (concat display-value (propertize (substring value (length truncated-value))
                                          'invisible t))
      display-value)))

(defun bibtex-actions--format-entry (entry width format-string)
  "Formats a BibTeX ENTRY for display in results list.
WIDTH is the width for the * field, and the display format is governed by
FORMAT-STRING."
  (s-format
   format-string
   (lambda (raw-field)
     (let* ((field (split-string raw-field ":"))
            (field-names (split-string (car field) "[ ]+"))
            (field-width (string-to-number (cadr field)))
            (display-width (if (> field-width 0)
                               ;; If user specifies field width of "*", use
                               ;; WIDTH; else use the explicit 'field-width'.
                               field-width
                             width))
            ;; Make sure we always return a string, even if empty.
            (display-value (bibtex-actions-display-value field-names entry)))
       (bibtex-actions--fit-to-width display-value display-width)))))

(defun bibtex-actions--format-entry-no-widths (entry format-string)
  "Format ENTRY for display per FORMAT-STRING."
  (s-format
   format-string
   (lambda (raw-field)
     (let ((field-names (split-string raw-field "[ ]+")))
       (bibtex-actions-display-value field-names entry)))))

;;; At-point functions

;;; Org-cite

(defun bibtex-actions-get-key-org-cite ()
  "Return key at point for org-cite citation-reference."
  (when-let (((eq major-mode 'org-mode))
             (elt (org-element-context)))
    (pcase (org-element-type elt)
      ('citation-reference
       (org-element-property :key elt))
      ('citation
       (org-cite-get-references elt t)))))

;;; Embark

(defun bibtex-actions-citation-key-at-point ()
  "Return citation keys at point as a list for `embark'."
  (when-let ((keys (bibtex-actions--major-mode-function 'keys-at-point)))
    (cons 'citation-key (bibtex-actions--stringify-keys keys))))

(defun bibtex-actions--stringify-keys (keys)
  "Return a list of KEYS as a crm-string for `embark'."
  (if (listp keys) (string-join keys " & ") keys))

;;; Commands

;;;###autoload
(defun bibtex-actions-open (keys-entries)
  "Open related resource (link or file) for KEYS-ENTRIES."
  ;; TODO add links
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
  (let* ((files
         (bibtex-actions-file--files-for-multiple-entries
          keys-entries
          (append bibtex-actions-library-paths bibtex-actions-notes-paths)
          bibtex-actions-file-extensions))
         (links
          (seq-map
           (lambda (key-entry)
             (bibtex-actions-get-link (cdr key-entry)))
           keys-entries))
         (resource-candidates (delete-dups (append files (remq nil links))))
         (resources
          (when resource-candidates
            (completing-read-multiple "Related resources: " resource-candidates))))
    (if resource-candidates
        (dolist (resource resources)
          (cond ((string-match "http" resource 0)
                 (browse-url resource))
                (t (bibtex-actions-file-open resource))))
      (message "No associated resources"))))

;;;###autoload
(defun bibtex-actions-open-library-files (keys-entries)
 "Open library files associated with the KEYS-ENTRIES.

With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
  (let ((files
         (bibtex-actions-file--files-for-multiple-entries
          keys-entries
          bibtex-actions-library-paths
          bibtex-actions-file-extensions)))
    (if bibtex-actions-file-open-prompt
        (let ((selected-files
               (bibtex-actions-select-files files)))
          (dolist (file selected-files)
            (bibtex-actions-file-open file))))
      (dolist (file files)
        (bibtex-actions-file-open file))))

(make-obsolete 'bibtex-actions-open-pdf
               'bibtex-actions-open-library-files "1.0")

;;;###autoload
(defun bibtex-actions-open-notes (keys-entries)
  "Open notes associated with the KEYS-ENTRIES.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
  (when (and (equal bibtex-actions-notes-paths nil)
             (equal bibtex-actions-file-open-note-function
                    'bibtex-actions-file-open-notes-default-org))
    (message "You must set 'bibtex-actions-notes-paths' to open notes with default notes function"))
  (dolist (key-entry keys-entries)
    ;; REVIEW doing this means the function won't be compatible with, for
    ;; example, 'orb-edit-note'.
    (funcall bibtex-actions-file-open-note-function
             (car key-entry) (cdr key-entry))))

;;;###autoload
(defun bibtex-actions-open-entry (keys-entries)
  "Open bibliographic entry associated with the KEYS-ENTRIES.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
 (bibtex-completion-show-entry
  (bibtex-actions--extract-keys keys-entries)))

;;;###autoload
(defun bibtex-actions-open-link (keys-entries)
  "Open URL or DOI link associated with the KEYS-ENTRIES in a browser.

With prefix, rebuild the cache before offering candidates."
  ;;      (browse-url-default-browser "https://google.com")
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
  (dolist (key-entry keys-entries)
    (let ((link (bibtex-actions-get-link (cdr key-entry))))
      (if link
          (browse-url-default-browser link)
        (message "No link found for %s" key-entry)))))

;;;###autoload
(defun bibtex-actions-insert-citation (keys-entries)
  "Insert citation for the KEYS-ENTRIES.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
  ;; TODO
  (bibtex-completion-insert-citation
   (bibtex-actions--extract-keys
    keys-entries)))

;;;###autoload
(defun bibtex-actions-insert-reference (keys-entries)
  "Insert formatted reference(s) associated with the KEYS-ENTRIES.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
  (bibtex-completion-insert-reference
   (bibtex-actions--extract-keys
    keys-entries)))

;;;###autoload
(defun bibtex-actions-insert-key (keys-entries)
  "Insert BibTeX KEYS-ENTRIES.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
 (bibtex-actions--major-mode-function 'insert-keys
  (bibtex-actions--extract-keys
   keys-entries)))

;;;###autoload
(defun bibtex-actions-insert-bibtex (keys-entries)
  "Insert bibliographic entry associated with the KEYS-ENTRIES.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
 (bibtex-completion-insert-bibtex
  (bibtex-actions--extract-keys
   keys-entries)))

;;;###autoload
(defun bibtex-actions-add-pdf-attachment (keys-entries)
  "Attach PDF(s) associated with the KEYS-ENTRIES to email.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
 (bibtex-completion-add-PDF-attachment
  (bibtex-actions--extract-keys
   keys-entries)))

;;;###autoload
(defun bibtex-actions-add-pdf-to-library (keys-entries)
 "Add PDF associated with the KEYS-ENTRIES to library.
The PDF can be added either from an open buffer, a file, or a
URL.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-select-refs
                      :rebuild-cache current-prefix-arg)))
  (bibtex-completion-add-pdf-to-library
   (bibtex-actions--extract-keys
    keys-entries)))

(defun bibtex-actions-run-default-action (keys)
  "Run the default action `bibtex-actions-default-action' on KEYS."
  (let* ((keys-parsed
          (if (stringp keys)
              (split-string keys " & ")
            (split-string (cdr keys) " & ")))
         (keys-entries
          (seq-map
           (lambda (key)
             (cons key (bibtex-actions--get-entry key))) keys-parsed)))
    (funcall bibtex-actions-default-action keys-entries)))

;;;###autoload
(defun bibtex-actions-dwim ()
  "Run the default action on citation keys found at point."
  (interactive)
  (if-let ((keys (cdr (bibtex-actions-citation-key-at-point))))
      ;; FIX how?
      (bibtex-actions-run-default-action keys)))

(provide 'bibtex-actions)
;;; bibtex-actions.el ends here
