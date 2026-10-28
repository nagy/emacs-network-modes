;;; net-asn.el --- Inspect autonomous system numbers  -*- lexical-binding: t; -*-

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

;; `net-asn-mode' displays one autonomous system number: its asplain
;; and asdot forms, its 16-bit or 32-bit class, its reservation status,
;; the registry block that assigned it, and the metadata that the
;; ipverse as-metadata project publishes.
;;
;; Two optional databases add detail:
;;
;;   net-asn-database-file      ipverse as-metadata as.json
;;   net-asn-registry-file      IANA as-numbers-1.csv
;;   net-asn-registry-file-v2   IANA as-numbers-2.csv
;;
;; The as.json file is large (tens of megabytes), so the lookup scans
;; the file for the one object with a matching \"asn\" key instead of
;; parsing the whole array.  `net-asn-load-database' builds a full hash
;; table for users who inspect many AS numbers in one session.
;;
;; Entry points:
;;
;;   M-x net-asn-inspect      - inspect an AS number

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'net-mode)

(defcustom net-asn-database-file (net-data-file "as.json")
  "AS metadata database in the ipverse as-metadata JSON format, or nil.
Download it from https://github.com/ipverse/as-metadata and point this
option at as.json.  The file is not shipped with the package."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defcustom net-asn-registry-file (net-data-file "as-numbers-1.csv")
  "IANA 16-bit AS number registry CSV file, or nil.
Used to report the registry block of an AS number."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defcustom net-asn-registry-file-v2 (net-data-file "as-numbers-2.csv")
  "IANA 32-bit AS number registry CSV file, or nil.
Used to report the registry block of an AS number."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defconst net-asn--categories
  '(("isp" . "ISP")
    ("hosting" . "Hosting or cloud")
    ("business" . "Business or non-profit")
    ("education_research" . "Education or research")
    ("government_admin" . "Government or administration"))
  "Human readable AS categories of the as-metadata database.")

(defconst net-asn--roles
  '(("tier1_transit" . "Tier 1 transit")
    ("major_transit" . "Major transit")
    ("midsize_transit" . "Mid-size transit")
    ("access_provider" . "Access provider")
    ("content_network" . "Content network")
    ("stub" . "Stub"))
  "Human readable network roles of the as-metadata database.")

(defvar net-asn--registry-cache nil
  "Alist of (FILE MTIME SIZE . ROWS) for parsed AS registries.")

(defvar net-asn--table nil
  "Cons of (KEY . HASH) with the fully parsed AS metadata database.")

(defvar net-asn--memo nil
  "Alist of (FILE ASN . ENTRY) with recent single-AS lookups.")

;;; Parsing

(defun net-asn--asdot-number (high low)
  "Return the AS number of the ASDOT parts HIGH and LOW, or nil.
A nil LOW keeps HIGH as asplain instead of splitting it."
  (if (null low)
      (string-to-number high)
    (let ((high-value (string-to-number high))
          (low-value (string-to-number low)))
      (when (and (<= high-value 65535) (<= low-value 65535))
        (+ (* high-value 65536) low-value)))))

(defun net-asn-parse (string)
  "Parse STRING as an autonomous system number.
Return a plist with :asn and :text, or nil.  Accept asplain (\"64500\"),
AS notation (\"AS64500\"), AS notation with ASDOT (\"AS1.10\") and bare
asdot (\"1.10\")."
  (when (stringp string)
    (let* ((text (string-trim string))
           (number (cond
                    ((string-match
                      "\\`[Aa][Ss]\\([0-9]+\\)\\(?:\\.\\([0-9]+\\)\\)?\\'"
                      text)
                     (net-asn--asdot-number (match-string 1 text)
                                            (match-string 2 text)))
                    ((string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)\\'"
                                   text)
                     (net-asn--asdot-number (match-string 1 text)
                                            (match-string 2 text)))
                    ((string-match "\\`[0-9]+\\'" text)
                     (string-to-number text)))))
      (when (and number (<= 0 number 4294967295))
        (list :asn number)))))

(defun net-asn-canonical (parsed)
  "Return the canonical string of the parsed AS number PARSED."
  (format "AS%d" (plist-get parsed :asn)))

(defun net-asn-asdot (asn)
  "Return the asdot form of ASN, or nil for 16-bit numbers."
  (when (> asn 65535)
    (format "%d.%d" (/ asn 65536) (% asn 65536))))

(defun net-asn-classification (asn)
  "Return (NAME . RFC) describing the reservation status of ASN."
  (cond
   ((= asn 0) '("Reserved" . "RFC 7607"))
   ((= asn 23456) '("AS_TRANS (4-byte AS transition)" . "RFC 6793"))
   ((<= 64496 asn 64511) '("Documentation" . "RFC 5398"))
   ((<= 64512 asn 65534) '("Private-Use" . "RFC 6996"))
   ((= asn 65535) '("Reserved" . "RFC 7300"))
   ((<= 65536 asn 65551) '("Documentation" . "RFC 5398"))
   ((<= 65552 asn 131071) '("Reserved" . "IANA"))
   ((<= 4200000000 asn 4294967294) '("Private-Use" . "RFC 6996"))
   ((= asn 4294967295) '("Reserved" . "RFC 7300"))
   (t '("Assigned" . "IANA"))))

;;; Registry

(defun net-asn--parse-range (string)
  "Parse the registry range STRING into (START . END), or nil."
  (cond
   ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" string)
    (cons (string-to-number (match-string 1 string))
          (string-to-number (match-string 2 string))))
   ((string-match "\\`[0-9]+\\'" string)
    (cons (string-to-number string) (string-to-number string)))))

(defun net-asn--registry-rows (file)
  "Return the parsed rows of the AS registry FILE, or nil."
  (when (net-data-available-p file)
    (let* ((attributes (file-attributes file))
           (key (list file
                      (file-attribute-modification-time attributes)
                      (file-attribute-size attributes)))
           (cached (assoc key net-asn--registry-cache)))
      (if cached
          (cdr cached)
        (let ((rows nil))
          (dolist (record (cdr (net--read-csv-file file)))
            (let ((range (and (>= (length record) 2)
                              (net-asn--parse-range (nth 0 record)))))
              (when range
                (push (list :range range
                            :description (nth 1 record)
                            :whois (nth 2 record)
                            :rfc (nth 4 record))
                      rows))))
          (setq rows (nreverse rows))
          (setq net-asn--registry-cache
                (cons (cons key rows) net-asn--registry-cache))
          rows)))))

(defun net-asn-registry-row (asn)
  "Return the IANA registry row of ASN, or nil."
  (let* ((file (if (<= asn 65535)
                   net-asn-registry-file
                 net-asn-registry-file-v2))
         (rows (net-asn--registry-rows file)))
    (cl-find-if (lambda (row)
                  (let ((range (plist-get row :range)))
                    (and (<= (car range) asn)
                         (<= asn (cdr range)))))
                rows)))

;;; Metadata

(defun net-asn--database-key ()
  "Return the cache key of `net-asn-database-file', or nil."
  (when (net-data-available-p net-asn-database-file)
    (let ((attributes (file-attributes net-asn-database-file)))
      (list net-asn-database-file
            (file-attribute-modification-time attributes)
            (file-attribute-size attributes)))))

(defun net-asn--scan (asn)
  "Return the metadata alist of ASN by scanning the database file.
The regexp expects \"asn\" as the first key of an object, which is
the shape that as-metadata publishes.  `net-asn-entry' checks that
shape and falls back to the full parse for any other file."
  (when (net-data-available-p net-asn-database-file)
    (with-temp-buffer
      (insert-file-contents net-asn-database-file)
      (goto-char (point-min))
      (let ((pattern (format "{[[:space:]\n]*\"asn\":[[:space:]]*%d[[:space:]]*[,\n}]"
                             asn)))
        (when (re-search-forward pattern nil t)
          (goto-char (match-beginning 0))
          (json-parse-buffer :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object nil))))))

(defun net-asn--scan-shape-p ()
  "Return non-nil when the first object starts with an \"asn\" key."
  (when (net-data-available-p net-asn-database-file)
    (with-temp-buffer
      (insert-file-contents net-asn-database-file nil 0 400)
      (goto-char (point-min))
      (re-search-forward "{[[:space:]\n]*\"asn\"[[:space:]]*:" nil t))))

(defun net-asn--table ()
  "Return the parsed hash table of the AS metadata database, or nil."
  (when-let* ((key (net-asn--database-key)))
    (if (and net-asn--table (equal (car net-asn--table) key))
        (cdr net-asn--table)
      (let ((table (make-hash-table :test #'eql :size 140000)))
        (with-temp-buffer
          (insert-file-contents net-asn-database-file)
          (goto-char (point-min))
          (let ((entries (json-parse-buffer :object-type 'alist
                                            :array-type 'list
                                            :null-object nil
                                            :false-object nil)))
            (dolist (entry entries)
              (puthash (alist-get 'asn entry) entry table))))
        (setq net-asn--table (cons key table))
        table))))

;;;###autoload
(defun net-asn-load-database ()
  "Parse the whole AS metadata database into a hash table.
Use this when you inspect many AS numbers in one session.  The single
lookup path scans the file for one object and needs no hash table."
  (interactive)
  (setq net-asn--memo nil)
  (if (net-asn--table)
      (message "AS database loaded: %d entries"
               (hash-table-count (net-asn--table)))
    (message "AS database is not available")))

(defun net-asn-entry (asn)
  "Return the metadata alist of ASN, or nil."
  (let ((key (net-asn--database-key)))
    (cond
     ((null key) nil)
     ((and net-asn--table (equal (car net-asn--table) key))
      (gethash asn (cdr net-asn--table)))
     ((assoc (list key asn) net-asn--memo)
      (let ((value (cdr (assoc (list key asn) net-asn--memo))))
        (unless (eq value 'missing) value)))
     (t
      (let ((entry (net-asn--scan asn)))
        ;; A file that does not put "asn" first defeats the scan, so a
        ;; miss there needs the full parse.  Keep the scan cheap for
        ;; the published shape, where a miss means "not in the file".
        (unless (or entry (net-asn--scan-shape-p))
          (setq entry (gethash asn (net-asn--table))))
        (setq net-asn--memo
              (cons (cons (list key asn) (or entry 'missing)) net-asn--memo))
        entry)))))

;;; Display

(defun net-asn--insert-identity-section (parsed)
  "Insert the identity fields of PARSED."
  (net-insert-heading "Autonomous System")
  (let* ((asn (plist-get parsed :asn))
         (classification (net-asn-classification asn)))
    (net-insert-field "AS number" asn)
    (net-insert-field "AS notation" (net-asn-canonical parsed))
    (when-let* ((asdot (net-asn-asdot asn)))
      (net-insert-field "ASDOT" asdot))
    (net-insert-field "Class" (if (> asn 65535) "32-bit" "16-bit"))
    (net-insert-field "Status" (car classification))
    (net-insert-field "Reference" (cdr classification))))

(defun net-asn--insert-registry-section (asn)
  "Insert the registry block of ASN."
  (net-insert-heading "Registry")
  (if-let* ((row (net-asn-registry-row asn)))
      (let ((range (plist-get row :range)))
        (net-insert-field "Block" (format "%d-%d" (car range) (cdr range)))
        (net-insert-field "Registry" (plist-get row :description))
        (when-let* ((whois (plist-get row :whois)))
          (when (not (string-empty-p whois))
            (net-insert-field "WHOIS" whois))))
    (net-insert-field "Block" "not in the IANA registry")))

(defun net-asn--insert-metadata-section (entry)
  "Insert the as-metadata fields of ENTRY."
  (let* ((metadata (alist-get 'metadata entry))
         (stats (alist-get 'stats entry)))
    (net-insert-heading "Metadata")
    (if (or (null entry) (null metadata))
        (net-insert-field "Database" "no entry for this AS number")
      (net-insert-field "Handle" (alist-get 'handle metadata))
      (net-insert-field "Description" (alist-get 'description metadata))
      (net-insert-field "Country"
                        (let ((code (alist-get 'countryCode metadata))
                              (name (alist-get 'country metadata)))
                          (cond ((and code name) (format "%s (%s)" name code))
                                (code code)
                                (t nil))))
      (net-insert-field "Origin" (alist-get 'origin metadata))
      (when-let* ((category (alist-get 'category metadata)))
        (net-insert-field "Category"
                          (or (alist-get category net-asn--categories
                                         nil nil #'equal)
                              category)))
      (when-let* ((role (alist-get 'networkRole metadata)))
        (net-insert-field "Network role"
                          (or (alist-get role net-asn--roles nil nil #'equal)
                              role)))
      (net-insert-field "Registered" (alist-get 'registered metadata))
      (net-insert-field "Last modified" (alist-get 'lastModified metadata))
      (net-insert-field "Last announced" (alist-get 'lastAnnounced entry))
      (when stats
        (net-insert-heading "Routing Statistics")
        (dolist (family '((ipv4 . "IPv4") (ipv6 . "IPv6")))
          (when-let* ((data (alist-get (car family) stats)))
            (net-insert-field (format "%s prefixes" (cdr family))
                              (alist-get 'prefixes data))
            (net-insert-field (format "%s aggregated" (cdr family))
                              (alist-get 'prefixesAggregated data))
            (net-insert-field (format "%s largest prefix" (cdr family))
                              (when-let* ((length (alist-get 'largestPrefix data)))
                                (format "/%d" length)))
            (net-insert-field (format "%s addresses" (cdr family))
                              (alist-get 'totalAddresses data))))
        (let ((connectivity (alist-get 'connectivity stats)))
          (when connectivity
            (net-insert-heading "Connectivity")
            (dolist (field '((providers . "Providers")
                             (customers . "Customers")
                             (peers . "Peers")
                             (degree . "Degree")
                             (reach . "Reach (customer cone)")))
              (net-insert-field (cdr field)
                                (alist-get (car field) connectivity)))
            (let ((providers (alist-get 'providerAsns connectivity)))
              (when providers
                (net-insert-link-list "Upstream Providers"
                                      (mapcar (lambda (provider)
                                                (cons 'asn
                                                      (format "AS%d" provider)))
                                              providers))))))))))

(defun net-asn--display ()
  "Render the AS number in the current buffer."
  (let* ((parsed (net-asn-parse net--value))
         (asn (plist-get parsed :asn))
         (classification (net-asn-classification asn))
         (entry (net-asn-entry asn)))
    (net-set-summary (format "AS%d %s" asn (car classification)))
    (net-asn--insert-identity-section parsed)
    (net-asn--insert-registry-section asn)
    (net-asn--insert-metadata-section entry)
    (setq-local net--rdap-type "autnum"
                net--rdap-key (number-to-string asn))))

;;; Mode and entry points

(define-derived-mode net-asn-mode net-mode "Net ASN"
  "Major mode for inspecting one autonomous system number.
\\{net-mode-map}")

;;;###autoload
(defun net-asn-inspect (asn)
  "Inspect the autonomous system number ASN in a `net-asn-mode' buffer."
  (interactive
   (list (or (when-let* ((bounds (bounds-of-thing-at-point 'net-asn)))
               (buffer-substring-no-properties (car bounds) (cdr bounds)))
             (read-string "AS number: "))))
  (let ((parsed (net-asn-parse asn)))
    (unless parsed
      (user-error "Not an AS number: %s" asn))
    (net-display 'asn (net-asn-canonical parsed)
                 #'net-asn-mode #'net-asn--display)))

(defun net-asn--sniff (string)
  "Return the canonical form of STRING when it looks like an AS number.
Only the explicit AS notation qualifies, with or without ASDOT, so a
bare integer or a version-like token stays unclaimed."
  (when (and (stringp string)
             (string-match-p "\\`[Aa][Ss][0-9]+\\(?:\\.[0-9]+\\)?\\'" string))
    (when-let* ((parsed (net-asn-parse string)))
      (net-asn-canonical parsed))))

(net-register-kind 'asn
                   '(:label "ASN"
                     :open net-asn-inspect
                     :sniff net-asn--sniff
                     :priority 45))

(put 'net-asn 'bounds-of-thing-at-point
     (lambda ()
       (net--thing-bounds "0-9AaSs." #'net-asn-parse)))
(put 'net-asn 'thing-at-point
     (lambda ()
       (when-let* ((bounds (bounds-of-thing-at-point 'net-asn)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(provide 'net-asn)
;;; net-asn.el ends here
