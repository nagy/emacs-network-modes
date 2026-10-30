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
;;   - a header line with a one-line classification
;;   - a bookmark handler per inspected value
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
;;   M-x net-copy-value   - copy the inspected value to the kill ring

;;; Code:

(require 'bindat)
(require 'bookmark)
(require 'button)
(require 'cl-lib)
(require 'json)
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
  "One-line classification of the inspected value.")

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
This is the `revert-buffer-function' of every inspect buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq net--summary nil
          net--rdap-type nil
          net--rdap-key nil
          net--rdap-start nil
          net--headings nil)
    (when net--render-function
      (funcall net--render-function))
    (goto-char (point-min))))

(defun net--header-line ()
  "Return the header line string of the current inspect buffer."
  (when net--summary
    (concat " " (propertize net--summary 'face 'net-muted-face))))

(defun net-set-summary (text)
  "Set the header line summary of the current buffer to TEXT.
TEXT names the classification only.  The buffer name and the mode line
already show the kind and the value."
  (setq net--summary text))

;;; Rendering helpers

(defun net-insert-heading (title)
  "Insert TITLE as a section heading.
Record the heading for Imenu."
  (unless (bobp)
    (insert "\n"))
  (let ((start (point)))
    (insert (propertize title 'face 'net-heading-face) "\n")
    (push (cons title (copy-marker start)) net--headings)))

(defun net--imenu-index ()
  "Return the section headings of the current buffer for Imenu."
  (mapcar (lambda (entry) (cons (car entry) (cdr entry)))
          (reverse net--headings)))

(defun net--insert-label (label)
  "Insert LABEL in the label column.
The column holds at least one space after a long LABEL."
  (let* ((text (format "%s" label))
         (padding (max 1 (- net--field-width (length text)))))
    (insert (propertize (concat text (make-string padding ?\s))
                        'face 'net-field-face))))

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

(defun net-insert-text (label text)
  "Insert LABEL followed by TEXT without a button.
TEXT can span several lines."
  (net--insert-label label)
  (insert (propertize (format "%s" text) 'face 'net-muted-face)
          "\n"))

(defun net--insert-link-button (kind value)
  "Insert a button that opens the KIND address VALUE."
  (insert-text-button (format "%s" value)
                      'net-kind kind
                      'net-value (format "%s" value)
                      'face 'net-value-face
                      'follow-link t
                      'action #'net--open-button
                      'help-echo (format "Inspect this %s value"
                                         (symbol-name kind))))

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
  "Insert TEXT as a warning line."
  (insert (propertize (format "%s\n" text) 'face 'net-warning-face)))

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
  (+ net--binary-header-size (* index (plist-get table :row-size))))

(defun net--binary-row (table index)
  "Return the unpacked TABLE row INDEX."
  (bindat-unpack (plist-get table :row-type)
                 (plist-get table :rows)
                 (net--binary-row-offset table index)))

(defun net--binary-start (table index)
  "Return the first address of TABLE row INDEX."
  (bindat-get-field
   (bindat-unpack (plist-get table :edge-type)
                  (plist-get table :rows)
                  (net--binary-row-offset table index))
   'start))

(defun net--binary-end (table index)
  "Return the last address of TABLE row INDEX."
  (bindat-get-field
   (bindat-unpack (plist-get table :edge-type)
                  (plist-get table :rows)
                  (net--binary-row-offset table index))
   'end))

(defun net--binary-number (table index column)
  "Return from TABLE row INDEX the numeric COLUMN."
  (aref (bindat-get-field (net--binary-row table index) 'numbers) column))

(defun net--binary-string (table index column)
  "Return from TABLE row INDEX the string COLUMN."
  (let ((name (aref (bindat-get-field (net--binary-row table index) 'strings)
                    column)))
    (aref (plist-get table :names) name)))

(defun net--binary-find (table value)
  "Return the row index of TABLE that covers VALUE, or nil.
The rows are sorted by start address and do not overlap."
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
        (let ((inhibit-read-only t))
          (net--rdap-begin-section)
          (net-insert-warning
           (format "Lookup timed out after %d seconds" net-rdap-timeout))
          (net-insert-field "Source" (net--rdap-url)))))))

(defun net--rdap-callback (buffer status)
  "Render the RDAP response in BUFFER.
STATUS is the `url-retrieve' status plist."
  (let ((data nil)
        (status-code nil)
        (network-error (plist-get status :error))
        (parse-error nil)
        (response-buffer (current-buffer)))
    (unless network-error
      (condition-case err
          (with-current-buffer response-buffer
            (setq status-code (bound-and-true-p url-http-response-status))
            (goto-char (or (bound-and-true-p url-http-end-of-headers)
                           (point-min)))
            (setq data (json-parse-buffer :object-type 'alist
                                          :array-type 'list
                                          :null-object nil
                                          :false-object nil)))
        (error (setq parse-error err))))
    (net--rdap-release-buffer response-buffer buffer)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (net--rdap-finish buffer)
        (let ((inhibit-read-only t))
          (net--rdap-begin-section)
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
           (t (net--rdap-render data)))
          (net-insert-field "Source" (net--rdap-url)))))))

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
  "w" #'net-copy-value
  "b" #'net-rdap
  "i" #'net-inspect)

(define-derived-mode net-mode special-mode "Net"
  "Base major mode for inspecting a network address.
Derived modes set `net--render-function' and render their fields with
`net-insert-heading', `net-insert-field' and `net-insert-link'.

\\{net-mode-map}"
  :group 'net
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'net-refresh)
  (setq-local header-line-format '(:eval (net--header-line)))
  (setq-local imenu-create-index-function #'net--imenu-index)
  (setq-local bookmark-make-record-function #'net--bookmark-make-record)
  (setq-local default-directory temporary-file-directory))

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
