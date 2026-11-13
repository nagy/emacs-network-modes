;;; net-mode.el --- Base major mode for network address inspection  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, network
;; Package-Requires: ((emacs "31.1") (magit-section "3.0.0"))
;; URL: https://github.com/nagy/emacs-network-modes

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides read-only major modes that inspect network
;; addresses: IP addresses, CIDR prefixes, MAC addresses, autonomous
;; system numbers, domain names and AF_VSOCK addresses.
;;
;; Every mode derives from `net-mode', which itself derives from
;; `magit-section-mode'.  `net-mode' supplies the shared machinery:
;;
;;   - a buffer naming scheme, one buffer per inspected value
;;   - a read-only section tree with copyable field buttons
;;   - folds, section motion and a section index from magit-section
;;   - a report summary per value, which names the classification
;;   - a bookmark handler per inspected value
;;   - a report per value, which draws the buffer and the JSON view
;;   - an explicit RDAP lookup command, never automatic
;;   - `net-inspect', the dispatcher that sniffs the token at point
;;
;; The report plist is the only section list: one heading becomes one
;; `net-section' and one row becomes one `net-field' section, so a
;; refresh keeps point and folds by the identity of the row.
;;
;; Each concrete mode registers itself in `net-kinds' with an opener
;; and a sniffer.  `net-inspect' and `net-sniff' use that registry, so
;; the dispatcher never needs a hard dependency on any mode file.
;;
;; Display buffers stay offline.  The only network access happens when
;; the user invokes `net-rdap' from a buffer with an RDAP identity.
;;
;; Entry points:
;;
;;   M-x net-inspect      - inspect the address at point, or ask
;;   M-x net-open         - open a value of a known kind
;;   M-x net-rdap         - fetch RDAP data for the current value
;;   M-x net-json-view    - show the report of the current value as JSON
;;   M-x net-copy-value   - copy the inspected value to the kill ring

;;; Code:

(require 'bindat)
(require 'bookmark)
(require 'button)
(require 'cl-lib)
(require 'ffap)
(require 'goto-addr)
(require 'js)
(require 'json)
(require 'json-ts-mode nil t)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'treesit)
(require 'url)
(require 'url-http)

(defgroup net nil
  "Inspect network addresses in read-only buffers."
  :group 'tools
  :prefix "net-"
  :link '(url-link :tag "Repository"
                   "https://github.com/nagy/emacs-network-modes"))

(defcustom net-data-directory nil
  "Directory that holds the bundled network databases.
The package can inspect every address without it.  The directory lets
the modes report vendor, registry, country and autonomous system
metadata.  The Nix package sets this to a store path that holds the
downloaded databases.  A nil value means no bundled databases."
  :type '(choice (const :tag "None" nil) directory)
  :group 'net)

(defcustom net-buffer-name-format "*net-%s %s*"
  "Format of inspect buffer names.
The first argument is the kind name, for example \"ip\".  The second
argument is the canonical address string."
  :type 'string
  :group 'net)

(defcustom net-json-buffer-name-format "%s JSON"
  "Format of the JSON view buffer name.
The argument is the name of the source inspect buffer."
  :type 'string
  :group 'net)

(defcustom net-json-side-window nil
  "Non-nil if the JSON view opens in a side window.
When non-nil, `net-json-view' shows the buffer at the right edge and
keeps the inspect buffer selected, so the report and its JSON stay
visible together.  The default replaces the report in the selected
window, as `pop-to-buffer' does."
  :type 'boolean
  :group 'net)

(defcustom net-goto-address t
  "Non-nil if an inspect buffer links the URLs in its text.
When non-nil, `goto-address-mode' turns a URL or a mail address of an
RDAP remark or of a registry note into a link, so the reader opens it
with the keys of that mode."
  :type 'boolean
  :group 'net)

(defcustom net-text-buttons t
  "Non-nil if an inspect buffer turns the addresses in its text into buttons.
When non-nil, a remark or a note that names an address, a prefix, a
MAC address, an AS number, a domain or a vsock address gets a button
that opens the inspect buffer of that value."
  :type 'boolean
  :group 'net)

(defcustom net-rdap-bootstrap-url "https://rdap.org"
  "RDAP bootstrap base URL.
`net-rdap' appends TYPE/KEY to this URL, for example
\"ip/192.0.2.1\".  The default redirects to the authoritative registry."
  :type 'string
  :group 'net)

(defcustom net-rdap-timeout 30
  "Seconds to wait for an RDAP answer before the lookup times out.
The value covers the whole request.  A timeout clears the in-flight
flag, so the next lookup can start, and renders a warning line.  A
late answer still replaces that line."
  :type 'natnum
  :group 'net)

(defface net-heading-face
  '((t :inherit outline-1 :weight bold))
  "Face for section headings in network inspect buffers."
  :group 'net)

(defface net-field-face
  '((t :inherit font-lock-type-face))
  "Face for field labels in network inspect buffers."
  :group 'net)

(defface net-value-face
  '((t :inherit font-lock-string-face))
  "Face for field values in network inspect buffers."
  :group 'net)

(defface net-warning-face
  '((t :inherit warning))
  "Face for warnings in network inspect buffers."
  :group 'net)

(defface net-muted-face
  '((t :inherit shadow))
  "Face for secondary and unknown values in network inspect buffers."
  :group 'net)

(defconst net--field-width 24
  "Width of the label column in network inspect buffers.")

(defvar-local net--kind nil
  "Symbol naming the kind of the value in this buffer.")

(defvar-local net--value nil
  "Canonical string of the inspected value in this buffer.")

(defvar-local net--render-function nil
  "Function that renders the inspected value into the current buffer.")

(defvar-local net--report-function nil
  "Function that returns the report of the inspected value.
`net-refresh' calls it to compare a fresh report with the report of
the last render, so a refresh of unchanged data renders nothing.
The `:report' property of the registered kind supplies it.")

(defvar-local net--rendered nil
  "Key of the last render of this buffer, or nil.
The key holds the kind, the value, the render function and the
report of that render.  `net-refresh' renders only when a fresh key
differs from this one.")

(defvar-local net--summary nil
  "One-line classification of the inspected value.
It reaches the JSON view only, because the buffer body shows the same
facts as fields.")

(defvar-local net--rdap-type nil
  "RDAP object type of the inspected value, or nil.
The value is one of \"ip\", \"domain\" or \"autnum\".")

(defvar-local net--rdap-key nil
  "RDAP lookup key of the inspected value, or nil.")

(defvar-local net--rdap-start nil
  "Marker at the start of the rendered RDAP section, or nil.
The next lookup replaces that section instead of appending another.")

(defvar-local net--rdap-in-flight nil
  "Non-nil while an RDAP request is in flight for this buffer.")

(defvar-local net--rdap-timer nil
  "Timer that abandons the RDAP request of this buffer, or nil.")

(defvar-local net--rdap-request-buffer nil
  "Buffer that holds the response of the RDAP request, or nil.")

(defvar-local net--rdap-raw nil
  "Body of the last successful RDAP answer, or nil.
`net-json-view' parses it again with hash tables, so the JSON view
shows the answer exactly as the server sent it.")

(defvar-local net--report nil
  "Report plist of the current inspect buffer, or nil.
`net--render-report' sets it, and `net-json-view' encodes it.")

(defvar-local net--json-buffer nil
  "JSON view buffer linked to this inspect buffer, or nil.")

(defvar-local net--json-source nil
  "Inspect buffer whose report this JSON buffer shows.")

(defvar-local net--rdap-section nil
  "Root of the RDAP section tree of this buffer, or nil.
A second lookup removes that section from the tree before it inserts
the new one, so `magit-get-section' never finds a stale object.")

(defvar net--label-counts nil
  "Occurrences of every row label in the section being inserted.
`net--field-value' reads the hash table to give a repeated label a
unique section value.  `net--render-section' and the RDAP renderer
bind it to a fresh table per section, so two rows of different
sections can carry the same label.")

;; The JSON view takes its parent from the machine at load time, so its
;; `define-derived-mode' sits inside an `if' and the byte compiler
;; cannot see the definition.
(declare-function net-json-mode "net-mode" (&optional arg))

(defvar net-kinds nil
  "Alist of registered network address kinds.
Each element is (KIND . PLIST).  PLIST holds :label, :open, :report,
:sniff and :priority.  Mode files register themselves with
`net-register-kind'.")

(defconst net--kind-features
  '(net-cidr net-mac net-vsock net-asn net-domain net-ip)
  "Features to load before dispatching an unknown token.")

;;; Data directory

(defun net-data-file (name)
  "Return the path of NAME inside `net-data-directory', or nil.
NAME is a plain file name, for example \"as.json\"."
  (when net-data-directory
    (expand-file-name name net-data-directory)))

(defun net-data-available-p (file)
  "Return non-nil when database FILE exists and is readable."
  (and (stringp file) (file-readable-p file)))

(defun net-data-description (file &optional detail)
  "Return a one-line description of the database FILE.
DETAIL names a count, for example \"296150 ranges\".  A file in the Nix
store has an epoch modification time, so it reports a pinned copy
instead of a meaningless date."
  (let* ((attributes (file-attributes file))
         (time (file-attribute-modification-time attributes))
         (date (cond ((null attributes) nil)
                     ((time-less-p time (encode-time 86400 0 0 1 1 1980))
                      "pinned copy")
                     (t (format-time-string "%Y-%m-%d" time))))
         (name (file-name-nondirectory file)))
    (cond ((null date) name)
          (detail (format "%s, %s, %s" name detail date))
          (t (format "%s, %s" name date)))))

(defun net--file-at-point (&optional _name)
  "Return the file of the database row at point, or nil.
A row names its file in the `net-file' text property instead of
printing the full path, so `ffap' reads the path from there.
`net-mode' installs this function in the buffer-local `ffap-alist'
with a key that matches every name.  `ffap-file-at-point' calls it
with the file name it guessed, which the text property replaces."
  (get-text-property (point) 'net-file))

;;; Kind registry

(defun net-register-kind (kind plist)
  "Register address KIND with property list PLIST.
PLIST keys are :label, :open, :report, :sniff and :priority.  :open
is called with the canonical value string.  :report takes that
string and returns the report plist, which `net-refresh' compares
before it renders.  :sniff takes a string and returns the canonical
value string when it recognizes it."
  (let ((cell (assq kind net-kinds)))
    (if cell
        (setcdr cell plist)
      (setq net-kinds (append net-kinds (list (cons kind plist)))))))

(defun net-kind-property (kind property)
  "Return a property of KIND.
PROPERTY selects which property of the registered address kind."
  (plist-get (cdr (assq kind net-kinds)) property))

(defun net--load-kinds ()
  "Load every mode feature that registers an address kind."
  (dolist (feature net--kind-features)
    (require feature nil t)))

(defun net-sniff (string)
  "Return (KIND . VALUE) when STRING is a known network address.
Return nil when no registered mode recognizes STRING."
  (net--load-kinds)
  (let ((kinds (sort (copy-sequence net-kinds)
                     (lambda (a b)
                       (> (or (plist-get (cdr a) :priority) 0)
                          (or (plist-get (cdr b) :priority) 0))))))
    (cl-loop for (kind . plist) in kinds
             for sniffer = (plist-get plist :sniff)
             for value = (and sniffer (funcall sniffer string))
             when value
             return (cons kind value))))

(defun net--open (kind value)
  "Open a KIND address VALUE in its inspect buffer."
  (let ((opener (net-kind-property kind :open)))
    (unless opener
      (user-error "No network mode registered for %s" kind))
    (funcall opener value)))

;;;###autoload
(defun net-open (kind value)
  "Inspect a KIND address VALUE.
KIND is one of `ip', `cidr', `mac', `asn', `domain' or `vsock'."
  (net--open kind value))

(defun net--field-value (label)
  "Return the section value of a row labelled LABEL.
A parent can hold two rows with the same label, for example two RDAP
events of the same action or two remarks, so the second occurrence
gains an ordinal.  The first occurrence keeps the bare label, because
its identity must survive a render that drops the repeat."
  (let ((text (format "%s" label)))
    (unless net--label-counts
      (setq net--label-counts (make-hash-table :test #'equal)))
    (let ((count (gethash text net--label-counts 0)))
      (puthash text (1+ count) net--label-counts)
      (if (zerop count) text (format "%s#%d" text (1+ count))))))

(defmacro net--with-label-counts (&rest body)
  "Run BODY with a fresh row label counter."
  (declare (indent 0) (debug t))
  `(let ((net--label-counts (make-hash-table :test #'equal)))
     ,@body))

;;; Display

(defun net--buffer-name (kind value)
  "Return the inspect buffer name for KIND and VALUE."
  (format net-buffer-name-format (symbol-name kind) value))

(defun net-display (kind value mode render)
  "Show a KIND address VALUE in a MODE buffer rendered by RENDER.
Reuse and refresh the buffer when it already exists."
  (let ((buffer (get-buffer-create (net--buffer-name kind value))))
    (with-current-buffer buffer
      (funcall mode)
      (setq net--kind kind
            net--value value
            net--render-function render
            net--report-function (net-kind-property kind :report))
      (net-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun net--render-key ()
  "Return the key that decides whether a render changes the buffer.
The key holds the kind, the value, the render function and the
report that the render function would draw, or nil when the buffer
cannot build one."
  (when (and net--value net--render-function net--report-function)
    (list net--kind
          net--value
          net--render-function
          (funcall net--report-function net--value))))

(defun net--render ()
  "Erase the current buffer and render the inspected value again.
`net-refresh' calls this after it decides that the buffer needs a
render.  Keep point on the section that it was on before the render,
keep the line of every other window that shows the buffer, and keep
the sections that the reader folded.  The visibility cache keys on
the section identity, so it restores a fold by itself."
  (let ((record (net--point-record))
        (windows (net--window-records)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq net--summary nil
            net--report nil
            net--rdap-type nil
            net--rdap-key nil
            net--rdap-start nil
            net--rdap-section nil
            net--rdap-raw nil)
      (when net--render-function
        (magit-insert-section (net-report (or net--kind 'report))
          (net--with-label-counts
            (funcall net--render-function))))
      (set-buffer-modified-p nil))
    ;; Show the root section with the cache off, so the cache ends up
    ;; holding only the sections that the reader really folded.  The
    ;; copy holds the sections that came back hidden from the cache.
    (when magit-root-section
      (let ((magit-section-cache-visibility nil))
        (magit-section-show magit-root-section)))
    (net--restore-point record)
    (net--restore-window-points windows)))

(defun net-refresh (&optional force)
  "Render the inspected value again unless its report did not change.
This is the `revert-buffer-function' of every inspect buffer.  A
render erases the buffer, so it runs only when a fresh report
differs from the report of the last render: an unchanged value
keeps its section objects, its folds, its point and its RDAP answer.
FORCE renders regardless, and `C-u g' passes it."
  (interactive "P")
  (let ((key (net--render-key)))
    (unless (and (not force) key (equal key net--rendered))
      (net--render)
      (setq net--rendered (list net--kind net--value
                                net--render-function net--report))))
  ;; The buffer name carries the value, and a narrow window truncates
  ;; it, so the mode line names it too.
  (setq-local mode-line-process
              (and net--value (list (concat " " net--value))))
  (set-buffer-modified-p nil)
  (net--json-redraw))

;;; Point keeping

;; A render erases the buffer and inserts a new section tree, so a
;; refresh keeps point by the identity of the section at point: the
;; `magit-section-ident' of that section, the number of lines from its
;; start, and the column of point.  The identity survives the render,
;; because the report builder gives every row a stable value.  A row
;; that a new render drops leaves point at `point-min'.
;;
;; The record holds no section object, because a bookmark serializes
;; the record to a file and an EIEIO object does not read back.  The
;; restore looks the identity up with `magit-get-section' instead.

(defun net--point-record (&optional position)
  "Return a record of the section at POSITION, or nil.
POSITION defaults to point.  The record holds the identity of the
section, the number of lines from its start to the line of POSITION,
and the column of POSITION.  A line that belongs to no section, such
as the blank line between two headings, records the root section the
way `magit-current-section' answers it."
  (let ((position (or position (point))))
    (when-let* ((section (or (magit-section-at position)
                             magit-root-section)))
      (list :ident (magit-section-ident section)
            :line (- (line-number-at-pos position)
                     (line-number-at-pos (oref section start)))
            :column (- position
                       (save-excursion
                         (goto-char position)
                         (line-beginning-position)))))))

(defun net--record-position (record)
  "Return the buffer position that RECORD names, or nil.
The position starts at the section that the identity of RECORD names,
moves down by the recorded number of lines and keeps the recorded
column, clipped to the end of a shorter line.  Return nil when the
new render holds no section with that identity."
  (when-let* ((record record)
              (section (magit-get-section (plist-get record :ident))))
    (save-excursion
      (goto-char (oref section start))
      (forward-line (or (plist-get record :line) 0))
      (let ((column (or (plist-get record :column) 0)))
        (unless (zerop column)
          (goto-char (min (+ (line-beginning-position) column)
                          (line-end-position)))))
      (point))))

(defun net--restore-point (record)
  "Move point to the position that RECORD describes.
A nil RECORD, or a record whose section the render dropped, moves
point to the start of the buffer."
  (goto-char (or (net--record-position record) (point-min))))

(defun net--window-records (&optional record-function)
  "Return the point record of every other window of the buffer.
Every window but the selected one contributes one cons of the window
and its record.  The selected window needs no entry, because its
point is the point of the buffer.  RECORD-FUNCTION takes a position
and returns a record, and defaults to `net--point-record'."
  (let ((buffer (current-buffer))
        (selected (selected-window))
        (record-function (or record-function #'net--point-record))
        records)
    (dolist (window (get-buffer-window-list buffer nil t))
      (unless (eq window selected)
        (push (cons window (funcall record-function
                                    (window-point window)))
              records)))
    records))

(defun net--restore-window-points (records &optional position-function)
  "Move the point of every window of RECORDS to its recorded line.
A window whose line is gone shows the start of the buffer, and a dead
window stays alone.  POSITION-FUNCTION takes a record and returns a
position, and defaults to `net--record-position'."
  (let ((position-function (or position-function #'net--record-position)))
    (dolist (record records)
      (let ((window (car record)))
        (when (window-live-p window)
          (set-window-point window
                            (or (funcall position-function (cdr record))
                                (point-min))))))))

;; The JSON view carries no sections, so it keeps point by the text of
;; the line and by the ordinal of that line among the equal lines
;; above it.

(defun net--line-text ()
  "Return the text of the current line without properties."
  (string-trim-right
   (buffer-substring-no-properties (line-beginning-position)
                                   (line-end-position))))

(defun net--line-occurrence (text)
  "Return the number of lines above point that hold TEXT.
The count makes the ordinal of the line of point among the equal
lines of the buffer, so a render keeps the right one of two equal
lines."
  (let ((origin (line-beginning-position)))
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (< (point) origin)
          (when (equal (net--line-text) text)
            (setq count (1+ count)))
          (forward-line 1))
        count))))

(defun net--text-record (&optional position)
  "Return a record of the text of the line at POSITION, or nil.
POSITION defaults to point.  The record holds the text of the line,
its ordinal among the equal lines above it and the column of
POSITION.  A line of whitespace alone records nothing, because its
text would match every blank line."
  (let* ((position (or position (point)))
         (text (save-excursion
                 (goto-char position)
                 (net--line-text)))
         (column (- position
                    (save-excursion
                      (goto-char position)
                      (line-beginning-position)))))
    (unless (string-empty-p text)
      (list :text text :ordinal (net--line-occurrence text)
            :column column))))

(defun net--goto-text (line)
  "Move point to the line that LINE names.
LINE is a cons of the text of a line and its ordinal among the equal
lines above it.  Return non-nil when the function found that line.
When the buffer holds fewer equal lines than the ordinal, the last
one serves, because a new line can push an old one down."
  (let ((text (car line))
        (ordinal (cdr line))
        (index 0)
        (found nil)
        (last nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward (concat "^" (regexp-quote text) "[ \t]*$")
                                nil t)
        (setq last (line-beginning-position))
        (unless (or found (< index ordinal))
          (setq found last))
        (setq index (1+ index))))
    (prog1 (and (or found last) t)
      (when (or found last)
        (goto-char (or found last))))))

(defun net--text-record-position (record)
  "Return the buffer position that RECORD names, or nil."
  (when-let* ((text (plist-get record :text)))
    (save-excursion
      (goto-char (point-min))
      (when (net--goto-text (cons text (plist-get record :ordinal)))
        (let ((column (or (plist-get record :column) 0)))
          (unless (zerop column)
            (goto-char (min (+ (line-beginning-position) column)
                            (line-end-position)))))
        (point)))))

(defun net-set-summary (text)
  "Set the report summary of the current buffer to TEXT.
TEXT names the classification only.  The buffer name and the mode line
already show the kind and the value, and the body shows every value
that TEXT names, so no header line repeats it."
  (setq net--summary text))

;;; Sections

;; A report becomes a tree of magit sections.  The root section holds
;; the kind of the buffer, every heading of the report becomes a
;; `net-section', and every row becomes a `net-field' or
;; `net-warning' section of its own.  A row has its own section
;; because point and the fold of a row key on its identity: a new row
;; above the reader then moves the reader with its row, and not with
;; its line number.
;;
;; The report plist is the only section list.  `net--render-section'
;; walks `:sections' in display order, so the buffer and the JSON view
;; cannot drift apart, and a second knob that lists sections would
;; double the configuration surface for no gain.

(defun net--insert-blank-line ()
  "Insert a blank line above the section that follows, when needed."
  (unless (bobp)
    (insert "\n")))

(defun net--insert-heading-line (title)
  "Insert TITLE as the heading line of the section being inserted.
The line carries TITLE in the `net-heading' text property, so
`embark-net.el' recognizes the heading of point, and it carries the
`face' property, so `magit-insert-heading' keeps the face of the
mode and does not substitute its own.  The same face goes into
`font-lock-face', so a buffer that turns the font-lock alias off
still shows it."
  (let ((text (format "%s" title)))
    (magit-insert-heading
     (propertize text
                 'face 'net-heading-face
                 'font-lock-face 'net-heading-face
                 'net-heading text))))

(defun net--foldable-section (section)
  "Return SECTION or the nearest ancestor that carries a body."
  (when section
    (if (magit-section-content-p section)
        section
      (net--foldable-section (oref section parent)))))

(defun net--section-by-heading (title)
  "Return the heading section titled TITLE, or nil."
  (let (found)
    (when magit-root-section
      (magit-map-sections
       (lambda (section)
         (when (and (not found)
                    (eq (oref section type) 'net-section)
                    (equal (oref section value) title))
           (setq found section)))))
    found))

(defun net-toggle-section (&optional section)
  "Fold or unfold SECTION, or the nearest foldable section above point.
A row that carries no body folds the heading section that holds it,
so a reader folds a long field table, an RDAP entity list or a remark
body from any line of it."
  (interactive nil net-mode)
  (let ((section (net--foldable-section (or section (magit-section-at)))))
    (unless section
      (user-error "No foldable network section at point"))
    (magit-section-toggle section)))

;;; Rendering helpers

(defun net--imenu-index ()
  "Return the heading sections of the current buffer for Imenu.
`magit-map-sections' visits depth first and ends with the root, so the
index takes the positions from the section objects and sorts them
into buffer order.  A row stays out of the index, because the index
would otherwise list every field of the report."
  (let (index)
    (when magit-root-section
      (magit-map-sections
       (lambda (section)
         (when (eq (oref section type) 'net-section)
           (push (cons (format "%s" (oref section value))
                       (oref section start))
                 index)))))
    (sort index (lambda (a b) (< (cdr a) (cdr b))))))

(defun net--insert-label (label)
  "Insert LABEL in the label column.
The column holds at least one space after a long LABEL."
  (let* ((text (format "%s" label))
         (padded (concat text
                         (make-string (max 1 (- net--field-width
                                                (length text)))
                                      ?\s))))
    (insert (propertize padded 'face 'net-field-face))))

(defvar-keymap net-button-map
  :doc "Keymap for the buttons of a network inspect buffer.
It inherits `button-map', so `RET' pushes the button and the mouse
keys follow it, and it puts `TAB' back on the fold command, because
the `keymap' property of a button beats the keymap of the major
mode."
  :parent button-map
  "TAB" #'net-toggle-section)

(defun net-insert-field (label value &optional face)
  "Insert LABEL and VALUE as a copyable field section.
VALUE is turned into a button that copies it to the kill ring.  FACE
replaces `net-value-face' for the button text.  A nil VALUE shows
\"unknown\".  The row carries LABEL as its section value, so a
refresh keeps point on it."
  (magit-insert-section (net-field (net--field-value label))
    (net--insert-label label)
    (if (null value)
        (insert (propertize "unknown" 'face 'net-muted-face))
      (let ((text (format "%s" value)))
        (insert-text-button text
                            'net-value text
                            'keymap net-button-map
                            'face (or face 'net-value-face)
                            'follow-link t
                            'action #'net--copy-button
                            'help-echo "Copy this value")))
    (insert "\n")))

(defun net-insert-text (label text &optional plain)
  "Insert LABEL followed by TEXT as a plain text section.
TEXT can span several lines.  A network address inside TEXT becomes a
button that opens its own inspect buffer, unless PLAIN is non-nil,
which a row that names a file passes, because a file name can read as
a domain name."
  (magit-insert-section (net-field (net--field-value label))
    (net--insert-label label)
    (let ((start (point)))
      (insert (propertize (format "%s" text) 'face 'net-muted-face))
      (net--link-addresses start (point) plain))
    (insert "\n")))

(defun net-insert-file (label text file)
  "Insert LABEL and TEXT as a button that opens FILE.
TEXT stays a short name, so the buffer never prints a store path.  The
path lives in the `net-file' text property, where `ffap-file-at-point'
and Embark find it, and in the button that `RET' pushes."
  (magit-insert-section (net-field (net--field-value label))
    (net--insert-label label)
    (insert-text-button (format "%s" text)
                        'net-file file
                        'keymap net-button-map
                        'face 'net-muted-face
                        'follow-link t
                        'action #'net--open-file-button
                        'help-echo (format "Open %s"
                                           (file-name-nondirectory file)))
    (insert "\n")))

(defun net--insert-link-button (kind value)
  "Insert a button that opens the KIND address VALUE."
  (let ((start (point))
        (text (format "%s" value)))
    (insert text)
    (net--buttonize-address start (point) kind value)))

(defun net--buttonize-address (start end kind value)
  "Turn the text between START and END into a button for KIND VALUE.
The button opens the inspect buffer of the value."
  (make-text-button start end
                    'net-kind kind
                    'net-value (if (stringp value)
                                   value
                                 (buffer-substring-no-properties
                                  start end))
                    'keymap net-button-map
                    'face 'net-value-face
                    'follow-link t
                    'action #'net--open-button
                    'help-echo (format "Inspect this %s value"
                                       (symbol-name kind))))

;;; Text links

;; A remark or a note can name an address or a URL.  The address
;; becomes a text button of the same shape as a link row, so the
;; reader opens its inspect buffer from the sentence.  The URL goes
;; through `goto-address-mode', which marks it with an overlay, so a
;; copy of the text stays plain.

(defconst net--text-token-regexp
  "\\b[[:alnum:]][[:alnum:]:./%_-]*[[:alnum:]]\\b"
  "Regexp for one word of a text row that can name an address.")

(defun net--link-address (token start end)
  "Turn TOKEN between START and END into a button when it names a value.
Return non-nil when the token became a button."
  (when-let* ((kind (net-sniff token)))
    (net--buttonize-address start end (car kind) (cdr kind))
    t))

(defun net--link-addresses (start end &optional plain)
  "Turn every network address between START and END into a button.
PLAIN disables the pass for a row that carries a file name."
  (when (and net-text-buttons (not plain))
    (save-excursion
      (goto-char start)
      (while (re-search-forward net--text-token-regexp end t)
        (net--link-address (match-string-no-properties 0)
                           (match-beginning 0)
                           (match-end 0))))))

(defun net--init-text-links ()
  "Link the URLs in the text of the current buffer.
`goto-address-mode' reads the URLs through its own fontification, so
it never touches the text of a row."
  (when net-goto-address
    (goto-address-mode 1)))

(defun net-insert-link (label kind value)
  "Insert a button labelled LABEL that opens the KIND address VALUE."
  (magit-insert-section (net-field (net--field-value label))
    (net--insert-label label)
    (net--insert-link-button kind value)
    (insert "\n")))

(defun net-insert-link-list (label items)
  "Insert LABEL and a comma separated list of address buttons.
ITEMS is a list of (KIND . VALUE) pairs.  The list wraps at the
window edge instead of putting one button on each line."
  (magit-insert-section (net-field (net--field-value label))
    (net--insert-label label)
    (let ((first t))
      (dolist (item items)
        (unless first
          (insert ", "))
        (setq first nil)
        (net--insert-link-button (car item) (cdr item))))
    (insert "\n")))

(defun net-insert-warning (text)
  "Insert TEXT as a warning section.
The row carries TEXT as its section value, so a refresh keeps point
on it."
  (magit-insert-section (net-warning (net--field-value text))
    (insert (propertize (format "%s\n" text) 'face 'net-warning-face))))

;;; Reports

(defconst net--json-schema 1
  "Version of the report layout that the JSON view writes.")

(defconst net--json-safe-integer (1- (ash 1 53))
  "Largest integer that a JSON double represents exactly.
IPv6 integers and host counts exceed it, so the encoder writes them
as strings, as RFC 7493 recommends.")

(defun net--item-value (reference source)
  "Return the value of REFERENCE inside the plist SOURCE.
REFERENCE is a keyword that names a key of SOURCE, or a literal
value, which comes back unchanged."
  (declare (pure t) (side-effect-free t))
  (if (keywordp reference)
      (plist-get source reference)
    reference))

(defun net--render-item (item source)
  "Render one report ITEM from the plist SOURCE.
The first element of ITEM is its type:

  (:field LABEL KEY [TEXT])   copyable value
  (:link LABEL KIND KEY [TEXT])   button that opens another kind
  (:links LABEL KIND KEY [TEXTS])  list of buttons
  (:text LABEL KEY [FILEKEY]) plain text, can span lines
  (:warning KEY)              warning line

TEXT and TEXTS override the displayed text, so the buffer can show a
sentence while the JSON keeps the bare value.  FILEKEY names the
filesystem path of the database that TEXT describes.  A readable file
turns the row into a button that opens it, and `ffap' resolves the row
without the buffer printing the path."
  (pcase (car item)
    (:field
     (let ((display (nth 3 item)))
       (net-insert-field (nth 1 item)
                         (if display
                             (net--item-value display source)
                           (net--item-value (nth 2 item) source)))))
    (:link
     (net-insert-link (nth 1 item) (nth 2 item)
                      (net--item-value (or (nth 4 item) (nth 3 item))
                                       source)))
    (:links
     (net-insert-link-list
      (nth 1 item)
      (mapcar (lambda (value) (cons (nth 2 item) value))
              (net--item-value (or (nth 4 item) (nth 3 item)) source))))
    (:text
     (let ((text (net--item-value (nth 2 item) source))
           (file (and (nth 3 item) (net--item-value (nth 3 item) source))))
       (if (net-data-available-p file)
           (net-insert-file (nth 1 item) text file)
         ;; A row that names an unreadable file prints a file name, and
         ;; a file name can read as a domain name, so it keeps plain.
         (net-insert-text (nth 1 item) text (and (nth 3 item) t)))))
    (:warning
     (net-insert-warning (net--item-value (nth 1 item) source)))))

(defun net--render-section (section)
  "Render one report SECTION as a magit section.
A section holds `:items' and one object of values, or `:records'
with one object of values per row.  A records section can also hold
`:items', which it renders after the rows; those items belong to the
buffer only and never reach the JSON.  The heading of the section
names it across renders, so a fold and point survive a refresh."
  (let ((heading (plist-get section :heading)))
    (net--insert-blank-line)
    (if heading
        (magit-insert-section (net-section (format "%s" heading))
          (net--insert-heading-line heading)
          (net--with-label-counts
            (net--render-section-rows section)))
      (net--with-label-counts
        (net--render-section-rows section)))))

(defun net--render-section-rows (section)
  "Insert the rows of SECTION into the section being inserted."
  (if-let* ((records (plist-get section :records)))
      (dolist (record records)
        (dolist (item (plist-get record :items))
          (net--render-item item record)))
    (dolist (item (plist-get section :items))
      (net--render-item item section)))
  (when (plist-get section :records)
    (dolist (item (plist-get section :items))
      (net--render-item item section))))

(defun net--render-report (report)
  "Render REPORT in the current inspect buffer.
REPORT holds `:summary', `:sections' and, when the value has one, the
`rdap' identity.  `:rdap-type' and `:rdap-key' supply the RDAP lookup."
  (setq net--report report)
  (when-let* ((summary (plist-get report :summary)))
    (net-set-summary summary))
  (dolist (section (plist-get report :sections))
    (net--render-section section))
  (when-let* ((key (plist-get report :rdap-key)))
    (setq-local net--rdap-type (plist-get report :rdap-type)
                net--rdap-key key)))

(defun net--json-name (key)
  "Return the JSON member name of KEY."
  (declare (pure t) (side-effect-free t))
  (if (keywordp key)
      (substring (symbol-name key) 1)
    (format "%s" key)))

(defun net--flag (text)
  "Return the boolean form of the registry flag TEXT.
Registry CSV files spell a flag as `True', `False', `N/A' or an
empty cell.  Return t, `:json-false' or nil respectively."
  (pcase (and (stringp text) (downcase (string-trim text)))
    ((or "true" "yes") t)
    ((or "false" "no") :json-false)
    (_ nil)))

(defun net--json-value (value)
  "Return VALUE in a form that `json-encode' writes safely.
A plist becomes an object, any other list becomes an array, a hash
table and a vector pass through, and an integer beyond
`net--json-safe-integer' becomes a string."
  (declare (pure t) (side-effect-free t))
  (cond
   ((integerp value)
    (if (<= (abs value) net--json-safe-integer)
        value
      (number-to-string value)))
   ((keywordp (car-safe value))
    (let (result)
      (while value
        (push (cons (net--json-name (car value))
                    (net--json-value (cadr value)))
              result)
        (setq value (cddr value)))
      (nreverse result)))
   ((consp value)
    (mapcar #'net--json-value value))
   (t value)))

(defun net--report-section-object (section)
  "Return the JSON members of SECTION as an alist.
The item keys name the members, so a display label never reaches the
JSON.  `:json-extra' adds members that the buffer does not show."
  (declare (pure t) (side-effect-free t))
  (let (result)
    (dolist (item (plist-get section :items))
      (let ((key (pcase (car item)
                   ((or :field :text) (nth 2 item))
                   (:link (nth 3 item))
                   (:links (nth 3 item))
                   (:warning (nth 1 item)))))
        (when (keywordp key)
          (push (cons (net--json-name key)
                      (net--json-value (plist-get section key)))
                result))))
    (let ((extra (plist-get section :json-extra)))
      (while extra
        (push (cons (net--json-name (car extra))
                    (net--json-value (cadr extra)))
              result)
        (setq extra (cddr extra))))
    (nreverse result)))

(defun net--report-sections (report)
  "Return the JSON members of the sections of REPORT as an alist."
  (declare (pure t) (side-effect-free t))
  (let (result)
    (dolist (section (plist-get report :sections))
      (push (cons (net--json-name (plist-get section :json))
                  (if-let* ((records (plist-get section :records)))
                      (mapcar (lambda (record)
                                (net--json-value (plist-get record :json)))
                              records)
                    (net--report-section-object section)))
            result))
    (nreverse result)))

(defun net--json-report (report kind value answer)
  "Return the JSON view of REPORT as an alist.
KIND and VALUE name the inspected value.  ANSWER is the parsed RDAP
response, or nil."
  (declare (pure t) (side-effect-free t))
  (let ((result (list (cons "schema" net--json-schema)
                      (cons "kind" (symbol-name kind))
                      (cons "value" value))))
    (when-let* ((summary (plist-get report :summary)))
      (setq result (append result (list (cons "summary" summary)))))
    (when-let* ((rdap (plist-get report :rdap)))
      (setq result (append result
                           (list (cons "rdap" (net--json-value rdap))))))
    (setq result (append result (net--report-sections report)))
    (when answer
      (setq result (append result (list (cons "rdapAnswer" answer)))))
    result))

;;; JSON view

(defun net--json-parse-answer (raw)
  "Return the parsed RDAP response RAW with hash tables, or nil."
  (when (and (stringp raw) (not (string-empty-p raw)))
    (condition-case nil
        (json-parse-string raw)
      (error nil))))

(defun net--json-text (source)
  "Return the JSON text of inspect buffer SOURCE, or nil."
  (let ((report (buffer-local-value 'net--report source)))
    (when report
      (json-encode
       (net--json-report report
                         (buffer-local-value 'net--kind source)
                         (buffer-local-value 'net--value source)
                         (net--json-parse-answer
                          (buffer-local-value 'net--rdap-raw source)))))))

(defun net--json-render (source)
  "Replace the current buffer with the JSON text of SOURCE.
Keep point on the line that it was on before the render, and keep
the line of every other window that shows the buffer."
  (let ((inhibit-read-only t)
        (record (net--text-record))
        (windows (net--window-records #'net--text-record))
        (text (net--json-text source)))
    (erase-buffer)
    (when text
      (insert text)
      (json-pretty-print-buffer))
    (goto-char (or (net--text-record-position record) (point-min)))
    (net--restore-window-points windows #'net--text-record-position)))

(defun net--json-redraw ()
  "Redraw the JSON view of the current inspect buffer."
  (let ((source (current-buffer)))
    (when-let* ((json net--json-buffer))
      (when (and (buffer-live-p json)
                 (with-current-buffer json
                   (eq net--json-source source)))
        (with-current-buffer json
          (net--json-render source))))))

(defun net--json-revert (&rest _args)
  "Redraw the current JSON buffer from its inspect buffer."
  (when (buffer-live-p net--json-source)
    (net--json-render net--json-source)))

(defun net--json-ts-available-p ()
  "Return non-nil when the JSON tree-sitter grammar can serve the view.
`json-ts-mode' signals an error without its grammar, so a machine
without the grammar builds the view on `js-json-mode' instead."
  (and (fboundp 'json-ts-mode)
       (treesit-language-available-p 'json)))

(defun net--json-imenu-index ()
  "Return an Imenu index of the members of the JSON view.
Only a line that opens an object or an array names a member, so the
index lists the sections of the report and not every leaf.  The
function reads the text, so both parent modes get the same index."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "^ *\"\\([^\"]+\\)\": *[{[][ \t]*$" nil t)
        (push (cons (match-string-no-properties 1)
                    (line-beginning-position))
              index)))
    (nreverse index)))

(defun net--json-show-source ()
  "Show the inspect buffer that this JSON buffer reports on."
  (interactive nil net-json-mode)
  (unless (buffer-live-p net--json-source)
    (user-error "The inspect buffer is gone"))
  (pop-to-buffer net--json-source))

(defun net--json-mode-setup ()
  "Set up the JSON view buffer."
  (setq-local revert-buffer-function #'net--json-revert)
  (setq-local imenu-create-index-function #'net--json-imenu-index)
  (setq-local default-directory
              (file-name-as-directory temporary-file-directory))
  (setq buffer-read-only t))

(defvar-keymap net-json-mode-map
  :doc "Keymap for `net-json-mode'."
  "q" #'quit-window
  "g r" #'net--json-revert
  "J" #'net--json-show-source)

(if (net--json-ts-available-p)
    (define-derived-mode net-json-mode json-ts-mode "Net JSON"
      "Major mode for the JSON view of a network inspect buffer.
The buffer shows the report of the buffer in `net--json-source' as
pretty printed JSON.  It is read-only.  `net-json-view' creates it,
and a refresh of the report buffer redraws it.  The machine carries
the JSON tree-sitter grammar, so the view takes the faces and the
navigation of `json-ts-mode'.

\\{net-json-mode-map}"
      :group 'net
      :interactive nil
      (net--json-mode-setup))
  (define-derived-mode net-json-mode js-json-mode "Net JSON"
    "Major mode for the JSON view of a network inspect buffer.
The buffer shows the report of the buffer in `net--json-source' as
pretty printed JSON.  It is read-only.  `net-json-view' creates it,
and a refresh of the report buffer redraws it.  The machine carries
no JSON tree-sitter grammar, so the view takes the faces of
`js-json-mode'.

\\{net-json-mode-map}"
    :group 'net
    :interactive nil
    (net--json-mode-setup)))

;;;###autoload
(defun net-json-view ()
  "Show the JSON report of the current network inspect buffer.
The buffer holds the report that drew this buffer, plus the RDAP
answer when one arrived.  The command reuses the buffer it created
before: a second call switches to that buffer, and a refresh of this
buffer redraws it."
  (interactive)
  (unless (derived-mode-p 'net-mode)
    (user-error "Not a network inspect buffer"))
  (unless net--report
    (user-error "No network report to show"))
  (let* ((source (current-buffer))
         (name (format net-json-buffer-name-format (buffer-name source)))
         (linked (and (buffer-live-p net--json-buffer)
                      (with-current-buffer net--json-buffer
                        (eq major-mode 'net-json-mode))
                      net--json-buffer))
         (buffer (or linked (get-buffer name))))
    (if (and (buffer-live-p buffer)
             (with-current-buffer buffer (eq major-mode 'net-json-mode)))
        (with-current-buffer buffer
          (setq-local net--json-source source)
          (net--json-render source))
      (setq buffer (get-buffer-create (generate-new-buffer-name name)))
      (with-current-buffer buffer
        (net-json-mode)
        (setq-local net--json-source source)
        (net--json-render source)))
    (setq-local net--json-buffer buffer)
    (if net-json-side-window
        (display-buffer buffer '((display-buffer-in-side-window)
                                 (side . right)
                                 (window-width . 0.4)))
      (pop-to-buffer buffer))
    buffer))

(defun net--split-csv-line (line)
  "Split LINE at commas into a list of fields.
Double quotes protect commas and unquote doubled quotes.  IANA
registries use this shape for columns that hold RFC lists."
  (declare (pure t) (side-effect-free t))
  (let ((fields nil)
        (field nil)
        (in-quotes nil)
        (index 0)
        (length (length line)))
    (while (< index length)
      (let ((char (aref line index)))
        (cond
         ((and in-quotes (= char ?\"))
          (if (and (< (1+ index) length) (= (aref line (1+ index)) ?\"))
              (progn (push ?\" field) (cl-incf index))
            (setq in-quotes nil)))
         ((= char ?\") (setq in-quotes t))
         ((and (not in-quotes) (= char ?,))
          (push (apply #'string (nreverse field)) fields)
          (setq field nil))
         (t (push char field))))
      (cl-incf index))
    (push (apply #'string (nreverse field)) fields)
    (nreverse fields)))

(defun net--read-csv-file (file)
  "Return the records of the CSV FILE as a list of field lists.
Each field holds its unquoted text.  A quoted field can span several
lines, so the AS registry RDAP column stays one field.  Return nil
when FILE is not readable."
  (when (net-data-available-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((records nil)
            (record nil))
        (while (not (eobp))
          ;; One match reads one field, quotes or not, in C.
          (re-search-forward "\\(?:\"\\(?:[^\"]\\|\"\"\\)*\"\\|[^,\r\n]*\\)")
          (let ((field (match-string 0)))
            (when (and (> (length field) 1)
                       (eq (aref field 0) ?\")
                       (eq (aref field (1- (length field))) ?\"))
              (setq field (replace-regexp-in-string
                           "\"\"" "\"" (substring field 1 -1) t t)))
            (push field record))
          (cond
           ((eq (char-after) ?\,) (forward-char 1))
           ((memq (char-after) '(?\n ?\r))
            (if (eq (char-after) ?\r) (forward-char 1))
            (if (eq (char-after) ?\n) (forward-char 1))
            (setq record (net--csv-record record))
            (when record (push record records))
            (setq record nil))))
        (setq record (net--csv-record record))
        (when record (push record records))
        (nreverse records)))))

(defun net--csv-record (record)
  "Return RECORD in file order, or nil when every field is empty."
  (declare (pure t) (side-effect-free t))
  (let ((fields (nreverse record)))
    (unless (seq-every-p #'string-empty-p fields)
      fields)))

;;; Packed range tables

(defconst net--binary-magic "NETR"
  "Magic bytes of a packed range table.")

(defconst net--binary-version 1
  "Format version of a packed range table.
Bump it here and in `tools/pack-network-data.el' together, so a stale
derivation cannot be misread.")

(defconst net--binary-header-size 20
  "Size in bytes of the header of a packed range table.")

(defconst net--binary-header-type
  (bindat-type (magic str 4)
               (version uint 16 t)
               (width u8)
               (numbers u8)
               (strings u8)
               (_ fill 3)
               (count uint 32 t)
               (strings-offset uint 32 t))
  "Bindat type of the header of a packed range table.
`uint' takes its size in bits and an optional little-endian flag, so
`uint 16 t' is a 16-bit little-endian field.")

(defvar net--binary-cache nil
  "Alist of (FILE MTIME SIZE . TABLE) for packed range tables.")

(defun net--binary-row-type (width numbers strings)
  "Return the Bindat type of one packed table row.
WIDTH is the address width in bytes, NUMBERS the number of 32-bit
number columns and STRINGS the number of string columns."
  (bindat-type (start uint (* 8 width))
               (end uint (* 8 width))
               (numbers vec numbers uint 32 t)
               (strings vec strings uint 32 t)))

(defun net--binary-edge-type (width)
  "Return the Bindat type of the addresses of a row WIDTH bytes wide."
  (bindat-type (start uint (* 8 width))
               (end uint (* 8 width))))

(defun net--binary-names-type ()
  "Return the Bindat type of the packed string table.
The table carries its own count, so one table size fits every file."
  (bindat-type (count uint 32 t)
               (names repeat count (len uint 16 t) (text str len))))

(defun net--binary-available-p (file)
  "Return non-nil when FILE starts with the packed table magic."
  (when (net-data-available-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil 0 (length net--binary-magic))
      (equal (buffer-string) net--binary-magic))))

(defun net--binary-names (bytes offset)
  "Return from BYTES the string table names at OFFSET."
  (let* ((entries (bindat-get-field
                   (bindat-unpack (net--binary-names-type) bytes offset)
                   'names))
         (names (make-vector (length entries) nil))
         (index 0))
    (dolist (entry entries)
      (aset names index
            (decode-coding-string (bindat-get-field entry 'text) 'utf-8))
      (setq index (1+ index)))
    names))

(defun net--binary-parse (file)
  "Return the packed table in FILE, or nil when FILE is not packed."
  (when (net--binary-available-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (let* ((bytes (buffer-string))
             (size (length bytes)))
        (when (>= size net--binary-header-size)
          (let* ((header (bindat-unpack net--binary-header-type bytes))
                 (version (bindat-get-field header 'version))
                 (width (bindat-get-field header 'width))
                 (numbers (bindat-get-field header 'numbers))
                 (strings (bindat-get-field header 'strings))
                 (count (bindat-get-field header 'count))
                 (strings-offset (bindat-get-field header 'strings-offset))
                 (row-size (+ (* 2 width) (* 4 numbers) (* 4 strings))))
            (when (and (= version net--binary-version)
                       (memq width '(4 16))
                       (= strings-offset
                          (+ net--binary-header-size (* count row-size)))
                       (<= strings-offset size))
              (list :file file
                    :width width
                    :numbers numbers
                    :strings strings
                    :count count
                    :row-size row-size
                    :rows bytes
                    :row-type (net--binary-row-type width numbers strings)
                    :edge-type (net--binary-edge-type width)
                    :names (net--binary-names bytes strings-offset)))))))))

(defun net--binary-table (file &optional layout)
  "Return the packed range table in FILE, or nil.
LAYOUT is a plist with :width, :numbers and :strings.  Signal an
error when FILE is packed but its layout differs, so a stale
derivation cannot be read as the wrong table."
  (when-let* ((attributes (and (net-data-available-p file)
                               (file-attributes file)))
              (key (list file
                         (file-attribute-modification-time attributes)
                         (file-attribute-size attributes))))
    (let ((table (if-let* ((cached (assoc key net--binary-cache)))
                     (cdr cached)
                   (let ((parsed (net--binary-parse file)))
                     (when parsed
                       (setq net--binary-cache
                             (cons (cons key parsed) net--binary-cache)))
                     parsed))))
      (when table
        (dolist (property '(:width :numbers :strings))
          (when (and (plist-member layout property)
                     (not (equal (plist-get layout property)
                                 (plist-get table property))))
            (error "Packed table layout mismatch in %s: %s is %s, expected %s"
                   file property (plist-get table property)
                   (plist-get layout property))))
        table))))

(defun net--binary-row-offset (table index)
  "Return the byte offset of TABLE row INDEX."
  (declare (pure t) (side-effect-free t))
  (+ net--binary-header-size (* index (plist-get table :row-size))))

(defun net--binary-row (table index)
  "Return the unpacked TABLE row INDEX."
  (declare (pure t) (side-effect-free t))
  (bindat-unpack (plist-get table :row-type)
                 (plist-get table :rows)
                 (net--binary-row-offset table index)))

(defun net--binary-start (table index)
  "Return the first address of TABLE row INDEX."
  (declare (pure t) (side-effect-free t))
  (bindat-get-field
   (bindat-unpack (plist-get table :edge-type)
                  (plist-get table :rows)
                  (net--binary-row-offset table index))
   'start))

(defun net--binary-end (table index)
  "Return the last address of TABLE row INDEX."
  (declare (pure t) (side-effect-free t))
  (bindat-get-field
   (bindat-unpack (plist-get table :edge-type)
                  (plist-get table :rows)
                  (net--binary-row-offset table index))
   'end))

(defun net--binary-number (table index column)
  "Return from TABLE row INDEX the numeric COLUMN."
  (declare (pure t) (side-effect-free t))
  (aref (bindat-get-field (net--binary-row table index) 'numbers) column))

(defun net--binary-string (table index column)
  "Return from TABLE row INDEX the string COLUMN."
  (declare (pure t) (side-effect-free t))
  (let ((name (aref (bindat-get-field (net--binary-row table index) 'strings)
                    column)))
    (aref (plist-get table :names) name)))

(defun net--binary-find (table value)
  "Return the row index of TABLE that covers VALUE, or nil.
The rows are sorted by start address and do not overlap."
  (declare (pure t) (side-effect-free t))
  (let ((low 0)
        (high (1- (plist-get table :count))))
    (while (<= low high)
      (let ((middle (/ (+ low high) 2)))
        (if (> (net--binary-start table middle) value)
            (setq high (1- middle))
          (setq low (1+ middle)))))
    (when (> low 0)
      (let ((index (1- low)))
        (when (<= value (net--binary-end table index))
          index)))))

(defun net--copy-button (button)
  "Copy the value of BUTTON to the kill ring."
  (let ((value (button-get button 'net-value)))
    (kill-new value)
    (message "Copied: %s" value)))

(defun net--open-file-button (button)
  "Open the database file of BUTTON."
  (find-file (button-get button 'net-file)))

(defun net--open-button (button)
  "Open the value of BUTTON in its own inspect buffer."
  (net--open (button-get button 'net-kind)
             (button-get button 'net-value)))

;;;###autoload
(defun net-copy-value ()
  "Copy the inspected value to the kill ring."
  (interactive)
  (unless net--value
    (user-error "This buffer has no inspected value"))
  (kill-new net--value)
  (message "Copied: %s" net--value))

;;; Bookmarks

(defun net--bookmark-make-record ()
  "Return a bookmark record for the current inspect buffer.
The record carries the row of point, so a jump lands on the field
that the reader saved and not at the start of the report."
  (list (cons 'handler #'net--bookmark-jump)
        (cons 'kind net--kind)
        (cons 'value net--value)
        (cons 'target (net--point-record))))

(defun net--bookmark-jump (bookmark)
  "Jump to the address stored in BOOKMARK.
Return the inspect buffer.  A record with a target moves point to the
row that it recorded, when that row still exists."
  (let ((buffer (net--open (alist-get 'kind bookmark)
                           (alist-get 'value bookmark)))
        (target (alist-get 'target bookmark)))
    (when (and target (buffer-live-p buffer))
      (with-current-buffer buffer
        (net--restore-point target)))
    buffer))

(put 'net--bookmark-jump 'bookmark-handler-type "Network address")

;;; RDAP

(defun net--rdap-url ()
  "Return the RDAP URL of the current buffer, or nil."
  (when (and net--rdap-type net--rdap-key)
    (format "%s/%s/%s"
            (string-trim-right net-rdap-bootstrap-url "/")
            net--rdap-type
            net--rdap-key)))

(defun net-rdap-available-p ()
  "Return non-nil when the current buffer has an RDAP identity."
  (and net--rdap-type net--rdap-key t))

;;;###autoload
(defun net-rdap ()
  "Fetch and render RDAP data for the current inspect buffer.
The command never runs automatically.  It contacts the network only
when invoked."
  (interactive)
  (unless (net-rdap-available-p)
    (user-error "This buffer has no RDAP lookup"))
  (let ((url (net--rdap-url))
        (target (current-buffer)))
    (when (net--rdap-in-flight-p target)
      (user-error "RDAP lookup already in flight"))
    (setq-local net--rdap-in-flight t)
    (setq-local net--rdap-raw nil)
    (message "RDAP: %s" url)
    (setq-local net--rdap-request-buffer
                (url-retrieve
                 url
                 (lambda (status)
                   (net--rdap-callback target status))
                 nil t t))
    (setq-local net--rdap-timer
                (run-with-timer net-rdap-timeout nil
                                #'net--rdap-abandon target))))

(defun net--rdap-in-flight-p (buffer)
  "Return non-nil when BUFFER has an RDAP request in flight."
  (and (buffer-live-p buffer)
       (buffer-local-value 'net--rdap-in-flight buffer)))

(defun net--rdap-release-buffer (response-buffer target)
  "Hand RESPONSE-BUFFER to the URL garbage collector.
TARGET is the inspect buffer, which the caller must keep."
  (when (and (buffer-live-p response-buffer)
             (not (eq response-buffer target)))
    (url-mark-buffer-as-dead response-buffer)))

(defun net--rdap-remove-section ()
  "Remove the RDAP section tree and its text from the buffer.
The answer arrives after the report render, so the tree must forget
the old section objects before it inserts new ones: `magit-get-section'
would otherwise find a stale object for the same identity."
  (when (and net--rdap-section magit-root-section
             (memq net--rdap-section (oref magit-root-section children)))
    (oset magit-root-section children
          (delq net--rdap-section (oref magit-root-section children))))
  (setq net--rdap-section nil)
  (when (and net--rdap-start (marker-position net--rdap-start))
    (let ((inhibit-read-only t))
      (delete-region net--rdap-start (point-max)))))

(defun net--rdap-begin-section ()
  "Start a new RDAP section at the end of the buffer.
Delete an earlier section first.  Return the marker at its start,
which also covers the blank line above the heading, so a second
answer cannot leave an empty line behind."
  (net--rdap-remove-section)
  (goto-char (point-max))
  (setq net--rdap-start (copy-marker (point-max)))
  (insert "\n")
  net--rdap-start)

(defun net--rdap-draw-section (body)
  "Draw the RDAP section with BODY in the current buffer.
BODY inserts the rows of the section.  The Source row follows them.
An answer arrives asynchronously, so the section keeps the line of
point: the reader who waits for an answer keeps the line that the
reader watched, and the line of every other window follows.

A render never edits the report again, so it records positions as
plain integers.  This function is the one exception: it appends text
after every report section, so the integers of the earlier sections
keep their value."
  (let ((inhibit-read-only t)
        (record (net--point-record))
        (windows (net--window-records)))
    (net--rdap-begin-section)
    (let ((magit-insert-section--parent magit-root-section)
          (magit-insert-section--oldroot nil))
      (setq net--rdap-section
            (net--with-label-counts
              (magit-insert-section (net-section "RDAP")
                (net--insert-heading-line "RDAP")
                (funcall body)
                (net-insert-field "Source" (net--rdap-url))))))
    (when (and net--rdap-section (oref net--rdap-section hidden))
      (magit-section-hide net--rdap-section))
    (net--restore-point record)
    (net--restore-window-points windows)))

(defun net--rdap-finish (buffer)
  "Clear the RDAP state of BUFFER.
Return non-nil when BUFFER still waited for an answer."
  (with-current-buffer buffer
    (when (timerp net--rdap-timer)
      (cancel-timer net--rdap-timer))
    (setq net--rdap-timer nil
          net--rdap-request-buffer nil)
    (prog1 net--rdap-in-flight
      (setq net--rdap-in-flight nil))))

(defun net--rdap-abandon (buffer)
  "Stop waiting for the RDAP answer of BUFFER.
This runs `net-rdap-timeout' seconds after `net-rdap'.  A late answer
still replaces the warning line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (net--rdap-finish buffer)
        (setq-local net--rdap-raw nil)
        (net--rdap-draw-section
         (lambda ()
           (net-insert-warning
            (format "Lookup timed out after %d seconds" net-rdap-timeout))))
        (set-buffer-modified-p nil)
        (net--json-redraw)))))

(defun net--rdap-callback (buffer status)
  "Render the RDAP response in BUFFER.
STATUS is the `url-retrieve' status plist."
  (let ((data nil)
        (status-code nil)
        (raw nil)
        (network-error (plist-get status :error))
        (parse-error nil)
        (response-buffer (current-buffer)))
    (unless network-error
      (condition-case err
          (with-current-buffer response-buffer
            (setq status-code (bound-and-true-p url-http-response-status))
            (goto-char (or (bound-and-true-p url-http-end-of-headers)
                           (point-min)))
            (let ((body (buffer-substring-no-properties (point) (point-max))))
              (setq raw (if (multibyte-string-p body)
                            body
                          (decode-coding-string body 'utf-8)))
              (setq data (json-parse-string raw :object-type 'alist
                                            :array-type 'list
                                            :null-object nil
                                            :false-object nil))))
        (error (setq parse-error err))))
    (net--rdap-release-buffer response-buffer buffer)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (net--rdap-finish buffer)
        (setq-local net--rdap-raw (and data raw))
        (net--rdap-draw-section
         (lambda ()
           (cond
            (network-error
             (net-insert-warning
              (format "Lookup failed: %s" network-error)))
            ((and (null data) status-code (>= status-code 400))
             (net-insert-warning
              (format "Lookup failed: HTTP %d" status-code)))
            ((null data)
             (net-insert-warning
              (format "Lookup failed: %s" (or parse-error "empty answer"))))
            (t (net--rdap-render data)))))
        (set-buffer-modified-p nil)
        (net--json-redraw)))))

(defun net--rdap-entity-name (entity)
  "Return the display name of the RDAP ENTITY alist."
  (or (alist-get 'handle entity)
      (let ((vcard (alist-get 'vcardArray entity)))
        (when vcard
          (seq-some (lambda (entry)
                      (when (and (listp entry)
                                 (equal (car entry) "fn")
                                 (nth 3 entry))
                        (nth 3 entry)))
                    (nth 1 vcard))))))

(defun net--rdap-render-error (data)
  "Render the RDAP error object DATA."
  (net-insert-warning
   (format "RDAP error %s: %s"
           (or (alist-get 'errorCode data) "unknown")
           (or (alist-get 'title data) "no title")))
  (dolist (line (alist-get 'description data))
    (net-insert-text "" line)))

(defun net--rdap-subsection (heading body)
  "Insert the RDAP HEADING section inside the RDAP section and run BODY.
The section nests under the RDAP section of the buffer, so a fold of
the RDAP section hides every subsection with it."
  (insert "\n")
  (net--with-label-counts
    (magit-insert-section (net-section heading)
      (net--insert-heading-line heading)
      (funcall body))))

(defun net--fill-text (text &optional width)
  "Return TEXT filled to WIDTH columns.
An RDAP remark arrives as one long line, so it fills at WIDTH,
which defaults to 78, before the renderer inserts it.  A fill after
the insert would move the end of the row section."
  (with-temp-buffer
    (let ((fill-column (or width 78)))
      (insert text)
      (fill-region (point-min) (point-max))
      (string-trim-right (buffer-string)))))

(defun net--rdap-render (data)
  "Render the RDAP response alist DATA in the current buffer."
  (cond
   ((not (listp data))
    (net-insert-warning "RDAP returned no JSON object"))
   ((alist-get 'errorCode data)
    (net--rdap-render-error data))
   (t
    (dolist (key '((handle . "Handle")
                   (name . "Name")
                   (type . "Type")
                   (country . "Country")
                   (ipVersion . "IP version")
                   (startAddress . "Start address")
                   (endAddress . "End address")))
      (let ((value (alist-get (car key) data)))
        (when value
          (net-insert-field (cdr key) value))))
    (let ((status (alist-get 'status data)))
      (when status
        (net-insert-field "Status" (mapconcat #'identity status ", "))))
    (let ((events (alist-get 'events data)))
      (when events
        (dolist (event events)
          (when-let* ((action (alist-get 'eventAction event))
                      (date (alist-get 'eventDate event)))
            (net-insert-field (capitalize action) date)))))
    (let ((entities (alist-get 'entities data)))
      (when entities
        (net--rdap-subsection
         "RDAP Entities"
         (lambda ()
           (dolist (entity entities)
             (let ((roles (mapconcat #'identity
                                     (alist-get 'roles entity) ", ")))
               (net-insert-field (if (string-empty-p roles) "Entity" roles)
                                 (net--rdap-entity-name entity))))))))
    (let ((remarks (alist-get 'remarks data)))
      (when remarks
        (net--rdap-subsection
         "RDAP Remarks"
         (lambda ()
           (dolist (remark remarks)
             (dolist (line (alist-get 'description remark))
               (when (stringp line)
                 (net-insert-text "" (net--fill-text line))))))))))))

;;; Base mode

(defvar-keymap net-mode-map
  :doc "Keymap for `net-mode' and its derived modes.
`magit-section-mode-map' supplies `C-c TAB', `n', `p', `^', `M-n',
`M-p' and the visibility levels.  `TAB' folds the nearest section
that carries a body, so a reader folds a table from any of its rows.
A button carries `net-button-map', which inherits `button-map' and
keeps `TAB' on the fold command, so `RET' still follows a button."
  "RET" #'push-button
  "TAB" #'net-toggle-section
  "w" #'net-copy-value
  "b" #'net-rdap
  "J" #'net-json-view
  "i" #'net-inspect)

(define-derived-mode net-mode magit-section-mode "Net"
  "Base major mode for inspecting a network address.
A derived mode sets `net--render-function' to a function that calls
`net--render-report' with its `net-KIND-report' value, and
`net-json-view' shows that report as JSON.

The parent mode supplies the section tree: `TAB' folds the section of
point, `C-c TAB' cycles the fold of a section and its children, `n'
and `p' move between sections, `^' goes to the parent and `1' to `4'
show that many levels.

\\{net-mode-map}"
  :group 'net
  :interactive nil
  (setq-local revert-buffer-function #'net-refresh)
  (setq-local imenu-create-index-function #'net--imenu-index)
  (setq-local bookmark-make-record-function #'net--bookmark-make-record)
  ;; A render inserts every section once and never edits the report
  ;; again, so a position stays valid as a plain integer: markers cost
  ;; a superlinear render above a few thousand sections.  A child
  ;; count would rewrite the heading of a section after its children
  ;; recorded their positions, which shifts every later position of
  ;; the tree, so no heading of this buffer ends with a colon and the
  ;; option of the reader stays at its default.
  (setq-local magit-section-inhibit-markers t)
  ;; A rendered value can hold a long remark or a list of related
  ;; addresses, so the buffer wraps at the window edge instead of
  ;; clipping the tail of a row.  The parent keeps
  ;; `line-move-visual' for its truncation, which reads wrong here.
  (setq-local truncate-lines nil)
  (setq-local line-move-visual nil)
  ;; The parent mode takes `list-buffers-directory' from
  ;; `default-directory', which a render then points elsewhere.
  (setq-local list-buffers-directory nil)
  (net--init-text-links)
  ;; A database row holds a short name, so `ffap' learns the real path
  ;; from the `net-file' text property.  The key matches every name,
  ;; because this body runs before `major-mode' names the derived mode.
  ;; The entry stays buffer-local, so other buffers keep the stock
  ;; `ffap' behaviour.
  (setq-local ffap-alist
              (cons (cons "" #'net--file-at-point) ffap-alist))
  ;; The rendered data comes from the network, not from a file: keep
  ;; the buffer out of the project, the version-controlled tree and
  ;; the language servers of the buffer that opened it.
  (setq-local default-directory
              (file-name-as-directory temporary-file-directory)))

;;; Dispatcher and thing-at-point

(defconst net--trailing-punctuation ".:/_-"
  "Characters that can follow an address in running text.")

(defun net--thing-candidates (text)
  "Return the parts of TEXT that can name a network address.
Each element is (OFFSET . STRING), where OFFSET counts characters
from the start of TEXT.  An address can sit behind a URL scheme and
before a path or a query, so the result holds TEXT first, then the
part after the scheme, then the part before the first path or query
character, and last the host without a port."
  (let ((candidates (list (cons 0 text)))
        (offset 0)
        (rest text))
    (when (string-match "\\`[A-Za-z][A-Za-z0-9+.-]*://" rest)
      (setq offset (match-end 0)
            rest (substring rest offset))
      (push (cons offset rest) candidates))
    (let ((split (string-match "[/?#]" rest)))
      (when (and split (> split 0))
        (setq rest (substring rest 0 split))
        (push (cons offset rest) candidates)))
    ;; A port after a URL scheme is not part of the host, but a bare
    ;; "CID:PORT" pair stays whole because no scheme matched.
    (when (and (> offset 0)
               (string-match "\\`\\(.+\\):[0-9]+\\'" rest))
      (push (cons offset (match-string 1 rest)) candidates))
    (nreverse candidates)))

(defun net--thing-bounds (chars predicate)
  "Return the bounds of a CHARS token around point that satisfies PREDICATE.
CHARS is a `skip-chars' set that makes up a token.  Prefer the token
without its trailing punctuation, so an address at the end of a
sentence still matches, and look inside a URL for its host.  Fall
back to the raw token."
  (save-excursion
    (skip-chars-forward chars)
    (let ((end (point)))
      (skip-chars-backward chars)
      (let* ((beg (point))
             (raw (and (< beg end)
                       (buffer-substring-no-properties beg end)))
             (trimmed (and raw
                           (string-trim-right
                            raw (concat "[" net--trailing-punctuation "]+")))))
        (or (and trimmed
                 (not (string-empty-p trimmed))
                 (seq-some (lambda (candidate)
                             (let ((start (+ beg (car candidate)))
                                   (string (cdr candidate)))
                               (when (and (not (string-empty-p string))
                                          (funcall predicate string))
                                 (cons start (+ start (length string))))))
                           (net--thing-candidates trimmed)))
            (and raw (funcall predicate raw) (cons beg end)))))))

(defun net--thing-at-point ()
  "Return the network-like token at point, or nil."
  (when-let* ((bounds (bounds-of-thing-at-point 'net-address)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(defun net--thing-sniff-p (string)
  "Return non-nil when STRING is a known network address."
  (and (net-sniff string) t))

(put 'net-address 'bounds-of-thing-at-point
     (lambda ()
       (net--thing-bounds "0-9A-Za-z:./%_-" #'net--thing-sniff-p)))
(put 'net-address 'thing-at-point
     (lambda ()
       (when-let* ((bounds (bounds-of-thing-at-point 'net-address)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(defvar net-inspect-history nil
  "History of values read by `net-inspect'.")

(defun net--address-annotation (candidate)
  "Return the kind label of CANDIDATE for the completion buffer.
A candidate that no registered mode recognizes stays bare."
  (when-let* ((kind (net-sniff candidate)))
    (format "  %s" (or (net-kind-property (car kind) :label)
                       (symbol-name (car kind))))))

(defun net-read-address (&optional prompt)
  "Read a network address and return it as a string.
PROMPT defaults to \"Network address: \".  Completion offers the
inputs of this session, because the dispatcher cannot know the
addresses that a reader has in mind.  Every candidate carries the kind
that recognizes it as an annotation, and the prompt announces the
`net-address' completion category, so a completion UI shows the kind
beside the address.  Empty input answers the address at point."
  (let* ((default (thing-at-point 'net-address))
         (completion-extra-properties
          (list :category 'net-address
                :annotation-function #'net--address-annotation
                :display-sort-function #'identity))
         (input (completing-read (or prompt "Network address: ")
                                 net-inspect-history nil nil
                                 default 'net-inspect-history)))
    (if (string-empty-p input) default input)))

;;;###autoload
(defun net-inspect (&optional string)
  "Inspect the network address at point or STRING.
The dispatcher asks each registered mode in turn, so it recognizes
IP addresses, CIDR prefixes, MAC addresses, AS numbers, domain names
and AF_VSOCK addresses."
  (interactive
   (list (when current-prefix-arg
           (net-read-address))))
  (let* ((input (or string (net--thing-at-point)))
         (kind (and input (net-sniff input))))
    (unless input
      (user-error "No network address at point"))
    (unless kind
      (user-error "No network mode recognizes %s" input))
    (net--open (car kind) (cdr kind))))

(provide 'net-mode)
;;; net-mode.el ends here
