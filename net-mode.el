;;; net-mode.el --- Base major mode for network address inspection  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, network
;; Package-Requires: ((emacs "31.1"))
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
;; `special-mode'.  `net-mode' supplies the shared machinery:
;;
;;   - a buffer naming scheme, one buffer per inspected value
;;   - a read-only renderer with copyable field buttons
;;   - a report summary per value, which names the classification
;;   - a bookmark handler per inspected value
;;   - a report per value, which draws the buffer and the JSON view
;;   - an explicit RDAP lookup command, never automatic
;;   - `net-inspect', the dispatcher that sniffs the token at point
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
(require 'outline)
(require 'seq)
(require 'subr-x)
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

(defcustom net-goto-address t
  "Whether an inspect buffer links the URLs in its text.
When non-nil, `goto-address-mode' turns a URL or a mail address of an
RDAP remark or of a registry note into a link, so the reader opens it
with the keys of that mode."
  :type 'boolean
  :group 'net)

(defcustom net-text-buttons t
  "Whether an inspect buffer turns the addresses of its text into buttons.
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

(defvar-local net--headings nil
  "Section headings of this buffer, newest first.
Each element is (TITLE . MARKER).  The renderers fill it through
`net-insert-heading', and Imenu reads it.")

(defvar net-kinds nil
  "Alist of registered network address kinds.
Each element is (KIND . PLIST).  PLIST holds :label, :open, :sniff
and :priority.  Mode files register themselves with
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
PLIST keys are :label, :open, :sniff and :priority.  :open is called
with the canonical value string.  :sniff takes a string and returns
the canonical value string when it recognizes it."
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
            net--render-function render)
      (net-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun net-refresh (&rest _)
  "Render the inspected value again.
This is the `revert-buffer-function' of every inspect buffer.  Keep
point on the line that it was on before the render, by the identity
of that line, keep the line of every other window that shows the
buffer, and keep the sections that the reader folded."
  (let ((record (net--point-record))
        (windows (net--window-records))
        (collapsed (net--collapsed-sections)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq net--summary nil
            net--report nil
            net--rdap-type nil
            net--rdap-key nil
            net--rdap-start nil
            net--rdap-raw nil
            net--headings nil)
      (when net--render-function
        (funcall net--render-function))
      (net--restore-sections collapsed)
      (net--restore-point record)
      (net--restore-window-points windows))
    (set-buffer-modified-p nil)
    (net--json-redraw)))

;;; Point keeping

;; A render erases the buffer, so a refresh would move point to the
;; start of the buffer for every line that carries no name.  The
;; record of a position names the line and not the buffer position:
;; the label of a field row, the title of a heading or, for a line
;; without a name, the text of the line and its ordinal among the
;; equal lines above it.  A remark spans several lines, so a line
;; without a name leans on the nearest named line above it and keeps
;; its distance from that line.  The column of point travels with the
;; line.

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

(defun net--line-identity ()
  "Return the identity of the line of point, or nil.
The identity is the `net-line' value of a named row, a cons of a kind
and a name, or a cons of `text' and a cons of the text of the line and
its ordinal among the equal lines above it.  A line of whitespace
alone has no identity, because its text would match every blank line."
  (or (get-text-property (line-beginning-position) 'net-line)
      (let ((text (net--line-text)))
        (unless (string-empty-p text)
          (cons 'text (cons text (net--line-occurrence text)))))))

(defun net--point-record (&optional position)
  "Return a record of the line at POSITION, or nil.
POSITION defaults to point.  The record holds the identity of the
line, the number of lines from the named line to the line of
POSITION, and the column of POSITION.  A line without a name leans
on the nearest named line above it.  Return nil when no line of the
buffer has a name, because then no place exists to keep."
  (let ((offset 0)
        column
        identity)
    (save-excursion
      (goto-char (or position (point)))
      (setq column (- (point) (line-beginning-position)))
      (beginning-of-line)
      (let ((done nil))
        (while (not done)
          (setq identity (net--line-identity))
          (cond (identity (setq done t))
                ((bobp) (setq done t))
                (t
                 (setq offset (1+ offset))
                 (forward-line -1))))))
    (when identity
      (list :identity identity :offset offset :column column))))

(defun net--goto-line (identity)
  "Move point to the first line whose `net-line' value equals IDENTITY.
Return non-nil when such a line exists.  Leave point at `point-min'
when no line holds that name."
  (let ((found nil))
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (when (equal (get-text-property (point) 'net-line) identity)
          (setq found (point)))
        (forward-line 1)))
    (prog1 (and found t)
      (goto-char (or found (point-min))))))

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

(defun net--goto-identity (identity)
  "Move point to the line that IDENTITY names.
Return non-nil when the function found that line."
  (pcase identity
    (`(text . ,line) (net--goto-text line))
    (_ (net--goto-line identity))))

(defun net--record-position (record)
  "Return the buffer position that RECORD names, or nil.
The position starts at the line that the identity of RECORD names,
moves down by the recorded number of lines and keeps the recorded
column, clipped to the end of a shorter line."
  (when record
    (save-excursion
      (goto-char (point-min))
      (when (net--goto-identity (plist-get record :identity))
        (forward-line (plist-get record :offset))
        (let ((column (plist-get record :column)))
          (unless (zerop column)
            (goto-char (min (+ (line-beginning-position) column)
                            (line-end-position)))))
        (point)))))

(defun net--restore-point (record)
  "Move point to the position that RECORD describes.
A nil RECORD moves point to the start of the buffer, because no line
carried a name before the render."
  (goto-char (or (net--record-position record) (point-min))))

(defun net--window-records ()
  "Return the point record of every other window of the buffer.
Every window but the selected one contributes one cons of the window
and its record.  The selected window needs no entry, because its
point is the point of the buffer.  A window whose line has no
identity contributes a nil record."
  (let ((buffer (current-buffer))
        (selected (selected-window))
        records)
    (dolist (window (get-buffer-window-list buffer nil t))
      (unless (eq window selected)
        (push (cons window (net--point-record (window-point window)))
              records)))
    records))

(defun net--restore-window-points (records)
  "Move the point of every window of RECORDS to its recorded line.
A window whose line is gone shows the start of the buffer, and a dead
window stays alone."
  (dolist (record records)
    (let ((window (car record)))
      (when (window-live-p window)
        (set-window-point window
                          (or (net--record-position (cdr record))
                              (point-min)))))))


(defun net-set-summary (text)
  "Set the report summary of the current buffer to TEXT.
TEXT names the classification only.  The buffer name and the mode line
already show the kind and the value, and the body shows every value
that TEXT names, so no header line repeats it."
  (setq net--summary text))

;;; Sections

;; A heading line carries `net-heading' with its title, and
;; `outline-search-function' finds that text property, so no heading
;; needs a special character in the text.  Every section is a top
;; level section, and a render restores a fold by the title.

(defun net--outline-search (&optional bound move backward looking-at)
  "Search for the next `net-heading' text property.
BOUND, MOVE, BACKWARD and LOOKING-AT have the meaning that
`outline-search-function' documents."
  (outline-search-text-property 'net-heading nil bound move backward
                                looking-at))

(defun net--enclosing-heading ()
  "Return the start of the heading line of the section around point.
Return nil when point sits above the first heading."
  (save-excursion
    (beginning-of-line)
    (cond
     ((get-text-property (point) 'net-heading) (point))
     ((outline-previous-heading) (point)))))

(defun net--keep-final-newline-visible ()
  "Stop a fold from hiding the newline that ends the buffer.
`outline-hide-subtree' reaches `point-max' when the folded section
ends the buffer, and Emacs then drops that line break, so the heading
of a later RDAP section would draw on the row of the folded one."
  (let ((end (point-max)))
    (when (> end (point-min))
      (dolist (overlay (overlays-in (1- end) end))
        (when (= (overlay-end overlay) end)
          (move-overlay overlay (overlay-start overlay) (1- end)))))))

(defun net-toggle-section ()
  "Fold or unfold the network section around point.
The command works on every line of a section, not only on the line
that shows its heading, so a reader folds a long field table, an RDAP
entity list or a remark body from the middle of it."
  (interactive nil net-mode)
  (let ((heading (net--enclosing-heading)))
    (unless heading
      (user-error "No network section at point"))
    (save-excursion
      (goto-char heading)
      (outline-toggle-children))
    (net--keep-final-newline-visible)))

(defun net--heading-position (title)
  "Return the start of the heading line titled TITLE, or nil."
  (save-excursion
    (when (net--goto-line (cons 'heading title))
      (point))))

(defun net--hide-section (title)
  "Fold the section titled TITLE in the current buffer, when present."
  (when-let* ((position (net--heading-position title)))
    (save-excursion
      (goto-char position)
      (outline-hide-subtree)
      (net--keep-final-newline-visible))))

(defun net--collapsed-sections ()
  "Return the titles of the folded sections of the current buffer.
`net-refresh' reads this before it erases the buffer, so a refresh
keeps the fold of the reader."
  (when (bound-and-true-p outline-minor-mode)
    (let (titles)
      (dolist (heading net--headings)
        (when (and (marker-position (cdr heading))
                   (save-excursion
                     (goto-char (cdr heading))
                     (outline-invisible-p (line-end-position))))
          (push (car heading) titles)))
      (nreverse titles))))

(defun net--restore-sections (titles)
  "Fold the sections of TITLES in the current buffer."
  (dolist (title titles)
    (net--hide-section title)))

;;; Rendering helpers

(defun net-insert-heading (title)
  "Insert TITLE as a section heading.
Record the heading for Imenu.  The line carries TITLE in the
`net-heading' text property, so the outline search of `net-mode'
finds it and a render restores a fold by name."
  (unless (bobp)
    (insert "\n"))
  (let ((start (point)))
    (insert (propertize title 'face 'net-heading-face
                        'net-heading title
                        'net-line (cons 'heading title))
            "\n")
    (push (cons title (copy-marker start)) net--headings)))

(defun net--imenu-index ()
  "Return the section headings of the current buffer for Imenu."
  (mapcar (lambda (entry) (cons (car entry) (cdr entry)))
          (reverse net--headings)))

(defun net--insert-label (label)
  "Insert LABEL in the label column.
The column holds at least one space after a long LABEL.  A label
names its row in the `net-line' text property, so a refresh keeps
point on the row."
  (let* ((text (format "%s" label))
         (padded (concat text
                         (make-string (max 1 (- net--field-width
                                                (length text)))
                                      ?\s))))
    (insert (if (string-empty-p text)
                (propertize padded 'face 'net-field-face)
              (propertize padded 'face 'net-field-face
                          'net-line (cons 'field text))))))

(defun net-insert-field (label value &optional face)
  "Insert LABEL and VALUE as a copyable field.
VALUE is turned into a button that copies it to the kill ring.  FACE
replaces `net-value-face' for the button text.  A nil VALUE shows
\"unknown\"."
  (net--insert-label label)
  (if (null value)
      (insert (propertize "unknown" 'face 'net-muted-face))
    (let ((text (format "%s" value)))
      (insert-text-button text
                          'net-value text
                          'face (or face 'net-value-face)
                          'follow-link t
                          'action #'net--copy-button
                          'help-echo "Copy this value")))
  (insert "\n"))

(defun net-insert-text (label text &optional plain)
  "Insert LABEL followed by TEXT without a button.
TEXT can span several lines.  A network address inside TEXT becomes a
button that opens its own inspect buffer, unless PLAIN is non-nil,
which a row that names a file passes, because a file name can read as
a domain name."
  (net--insert-label label)
  (let ((start (point)))
    (insert (propertize (format "%s" text) 'face 'net-muted-face))
    (net--link-addresses start (point) plain)
    (insert "\n")))

(defun net-insert-file (label text file)
  "Insert LABEL and TEXT as a button that opens FILE.
TEXT stays a short name, so the buffer never prints a store path.  The
path lives in the `net-file' text property, where `ffap-file-at-point'
and Embark find it, and in the button that `RET' pushes."
  (net--insert-label label)
  (insert-text-button (format "%s" text)
                      'net-file file
                      'face 'net-muted-face
                      'follow-link t
                      'action #'net--open-file-button
                      'help-echo (format "Open %s"
                                         (file-name-nondirectory file)))
  (insert "\n"))

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
  (net--insert-label label)
  (net--insert-link-button kind value)
  (insert "\n"))

(defun net-insert-link-list (label items)
  "Insert LABEL and a comma separated list of address buttons.
ITEMS is a list of (KIND . VALUE) pairs.  The list wraps at the
window edge instead of putting one button on each line."
  (net--insert-label label)
  (let ((first t))
    (dolist (item items)
      (unless first
        (insert ", "))
      (setq first nil)
      (net--insert-link-button (car item) (cdr item))))
  (insert "\n"))

(defun net-insert-warning (text)
  "Insert TEXT as a warning line.
The line carries its own text as its `net-line' name."
  (let ((line (format "%s\n" text)))
    (insert (propertize line 'face 'net-warning-face
                        'net-line (cons 'warning line)))))

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
  "Render one report SECTION.
A section holds `:items' and one object of values, or `:records'
with one object of values per row.  A records section can also hold
`:items', which it renders after the rows; those items belong to the
buffer only and never reach the JSON."
  (when-let* ((heading (plist-get section :heading)))
    (net-insert-heading heading))
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
        (record (net--point-record))
        (windows (net--window-records))
        (text (net--json-text source)))
    (erase-buffer)
    (when text
      (insert text)
      (json-pretty-print-buffer))
    (net--restore-point record)
    (net--restore-window-points windows)))

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

(define-derived-mode net-json-mode js-json-mode "Net JSON"
  "Major mode for the JSON view of a network inspect buffer.
The buffer shows the report of the buffer in `net--json-source' as
pretty printed JSON.  It is read-only.  `net-json-view' creates it,
and a refresh of the report buffer redraws it.

\\{net-json-mode-map}"
  :group 'net
  (setq-local revert-buffer-function #'net--json-revert)
  (setq-local default-directory
              (file-name-as-directory temporary-file-directory))
  (setq buffer-read-only t))

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
    (pop-to-buffer buffer)))

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
  "Return a bookmark record for the current inspect buffer."
  (list (cons 'handler #'net--bookmark-jump)
        (cons 'kind net--kind)
        (cons 'value net--value)))

(defun net--bookmark-jump (bookmark)
  "Jump to the address stored in BOOKMARK."
  (let ((kind (alist-get 'kind bookmark))
        (value (alist-get 'value bookmark)))
    (net--open kind value)))

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

(defun net--rdap-begin-section ()
  "Start a new RDAP section at the end of the buffer.
Delete an earlier section first.  Return the marker at its start."
  (let ((inhibit-read-only t))
    (when (and net--rdap-start (marker-position net--rdap-start))
      (delete-region net--rdap-start (point-max)))
    (goto-char (point-max))
    (setq net--rdap-start (copy-marker (point-max)))
    (net-insert-heading "RDAP")
    net--rdap-start))

(defun net--rdap-draw-section (body)
  "Draw the RDAP section with BODY in the current buffer.
BODY inserts the rows of the section.  The Source row follows them.
An answer arrives asynchronously, so the section keeps the line of
point: the reader who waits for an answer keeps the line that the
reader watched, and the line of every other window follows."
  (let ((inhibit-read-only t)
        (record (net--point-record))
        (windows (net--window-records)))
    (net--rdap-begin-section)
    (funcall body)
    (net-insert-field "Source" (net--rdap-url))
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
        (net-insert-heading "RDAP Entities")
        (dolist (entity entities)
          (let ((roles (mapconcat #'identity (alist-get 'roles entity) ", ")))
            (net-insert-field (if (string-empty-p roles) "Entity" roles)
                              (net--rdap-entity-name entity))))))
    (let ((remarks (alist-get 'remarks data)))
      (when remarks
        (net-insert-heading "RDAP Remarks")
        (dolist (remark remarks)
          (dolist (line (alist-get 'description remark))
            (when (stringp line)
              (let ((start (point))
                    (fill-column 78))
                (net-insert-text "" line)
                (fill-region start (point)))))))))))

;;; Base mode

(defvar-keymap net-mode-map
  :doc "Keymap for `net-mode' and its derived modes."
  :parent special-mode-map
  "RET" #'push-button
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "C-c TAB" #'net-toggle-section
  "w" #'net-copy-value
  "b" #'net-rdap
  "J" #'net-json-view
  "i" #'net-inspect)

(define-derived-mode net-mode special-mode "Net"
  "Base major mode for inspecting a network address.
A derived mode sets `net--render-function' to a function that calls
`net--render-report' with its `net-KIND-report' value, and
`net-json-view' shows that report as JSON.

\\{net-mode-map}"
  :group 'net
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'net-refresh)
  (setq-local imenu-create-index-function #'net--imenu-index)
  (setq-local bookmark-make-record-function #'net--bookmark-make-record)
  ;; A heading line carries `net-heading' with its title, so the
  ;; outline search finds it and no heading needs a special character.
  ;; Every section is a top level section.  The faces of the renderer
  ;; stay, because the heading already carries `net-heading-face'.
  (setq-local outline-search-function #'net--outline-search)
  (setq-local outline-level (lambda () 1))
  (setq-local outline-minor-mode-highlight nil)
  (outline-minor-mode 1)
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

;;;###autoload
(defun net-inspect (&optional string)
  "Inspect the network address at point or STRING.
The dispatcher asks each registered mode in turn, so it recognizes
IP addresses, CIDR prefixes, MAC addresses, AS numbers, domain names
and AF_VSOCK addresses."
  (interactive
   (list (when current-prefix-arg
           (read-string "Network address: "
                        (thing-at-point 'net-address)
                        'net-inspect-history))))
  (let* ((input (or string (net--thing-at-point)))
         (kind (and input (net-sniff input))))
    (unless input
      (user-error "No network address at point"))
    (unless kind
      (user-error "No network mode recognizes %s" input))
    (net--open (car kind) (cdr kind))))

(provide 'net-mode)
;;; net-mode.el ends here
