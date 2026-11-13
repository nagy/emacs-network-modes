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
;; The reverse direction, the origin AS of an IP address, needs BGP
;; data: RDAP publishes addresses and entities, not routing.  Two
;; iptoasn range files answer it offline:
;;
;;   net-asn-ip-database-file      iptoasn ip2asn-v4.tsv.gz
;;   net-asn-ip-database-file-v6   iptoasn ip2asn-v6.tsv.gz
;;
;; Each file is a tab separated range table sorted by start address.
;; `net-asn-ip-entry' binary searches the line starts, so one lookup
;; parses about twenty rows instead of the whole file.  The Nix
;; derivation packs the same ranges into a fixed-width table
;; (`tools/pack-network-data.el'), which needs no decompression and no
;; line scan.  A raw TSV or gzip file still works.
;;
;; Entry points:
;;
;;   M-x net-asn-inspect      - inspect an AS number
;;   M-x net-asn-ip-entry     - find the origin AS of an IP address

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'net-mode)

(declare-function net-ip-parse "net-ip")

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

(defcustom net-asn-ip-database-file (net-data-file "asn-ranges-v4.bin")
  "IPv4 to AS number range table, or nil.
The Nix package ships a packed table.  A tab separated file with
start address, end address, AS number, country code and AS
description works too, sorted by start address, and the gzip form
stays compressed.  Download it from https://iptoasn.com."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defcustom net-asn-ip-database-file-v6 (net-data-file "asn-ranges-v6.bin")
  "IPv6 to AS number range table, or nil.
The Nix package ships a packed table.  A tab separated file with
start address, end address, AS number, country code and AS
description works too, sorted by start address, and the gzip form
stays compressed.  Download it from https://iptoasn.com."
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
  (declare (pure t) (side-effect-free t))
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
  (declare (pure t) (side-effect-free t))
  (format "AS%d" (plist-get parsed :asn)))

(defun net-asn-asdot (asn)
  "Return the asdot form of ASN, or nil for 16-bit numbers."
  (declare (pure t) (side-effect-free t))
  (when (> asn 65535)
    (format "%d.%d" (/ asn 65536) (% asn 65536))))

(defun net-asn-classification (asn)
  "Return (NAME . RFC) describing the reservation status of ASN."
  (declare (pure t) (side-effect-free t))
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

;;; IP addresses to AS numbers

(defvar net-asn--range-cache nil
  "Cons of (KEY . TEXT) with the decompressed IP to AS range table.")

(defun net-asn--ip-file (version)
  "Return the IP to AS number range file of VERSION, or nil."
  (if (= version 4)
      net-asn-ip-database-file
    net-asn-ip-database-file-v6))

(defun net-asn--ip-table (version)
  "Return the packed IP to AS range table of VERSION, or nil."
  (when-let* ((file (net-asn--ip-file version)))
    (net--binary-table file (list :width (if (= version 4) 4 16)
                                  :numbers 1
                                  :strings 2))))

(defun net-asn--gzip-file-p (file)
  "Return non-nil when FILE starts with the gzip magic bytes.
The suffix is not trusted, because a Nix file input keeps no
upstream name."
  (when (net-data-available-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil 0 2)
      (equal (buffer-string) (unibyte-string 31 139)))))

(defun net-asn--insert-range-file (file)
  "Insert the range table FILE into the current buffer.
Decompress a gzip file here, so the lookup does not depend on
`auto-compression-mode'.  The gzip magic bytes decide, not the
suffix."
  (if (net-asn--gzip-file-p file)
      (progn
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (zlib-decompress-region (point-min) (point-max))
        (set-buffer-multibyte t))
    (insert-file-contents file)))

(defun net-asn--range-text (file)
  "Return the decompressed text of the range FILE.
Decompress once and reuse the text while the file does not change,
so a later lookup does not pay for the gzip pass again."
  (let* ((attributes (file-attributes file))
         (key (list file
                    (file-attribute-modification-time attributes)
                    (file-attribute-size attributes))))
    (if (and net-asn--range-cache
             (equal (car net-asn--range-cache) key))
        (cdr net-asn--range-cache)
      (let ((text (with-temp-buffer
                    (net-asn--insert-range-file file)
                    (buffer-string))))
        (setq net-asn--range-cache (cons key text))
        text))))

(defun net-asn--range-fields ()
  "Return the fields of the range table row at point."
  (split-string (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))
                "\t"))

(defun net-asn--address-number (text)
  "Return the address integer of TEXT.
Accept a plain number or an address that `net-ip-parse' reads."
  (if (string-match-p "\\`[0-9]+\\'" text)
      (string-to-number text)
    (unless (fboundp 'net-ip-parse)
      (require 'net-ip nil t))
    (when-let* ((parsed (net-ip-parse text)))
      (plist-get parsed :value))))

(defun net-asn--row-start (position)
  "Return the first address of the range table row at POSITION."
  (save-excursion
    (goto-char position)
    (net-asn--address-number (car (net-asn--range-fields)))))

(defun net-asn--before-p (position address)
  "Return non-nil when the range row at POSITION starts at or before ADDRESS."
  (let ((start (net-asn--row-start position)))
    (and start (<= start address))))

(defun net-asn--search-row (address)
  "Return the position of the range table row that can hold ADDRESS.
The current buffer holds a table sorted by start address.  Binary
search the line starts, so a lookup parses about twenty rows."
  (let ((low (point-min))
        (high (point-max))
        (found nil))
    (while (< low high)
      (goto-char (/ (+ low high) 2))
      (forward-line 0)
      (let ((position (point)))
        (cond
         ;; The midpoint fell inside the line that already begins at
         ;; LOW, so take that row into account and step past it.
         ((<= position low)
          (when (net-asn--before-p low address)
            (setq found low))
          (goto-char low)
          (if (zerop (forward-line 1))
              (setq low (point))
            (setq low high)))
         ((net-asn--before-p position address)
          (setq low position
                found position))
         (t
          (setq high position)))))
    found))

;;;###autoload
(defun net-asn-ip-entry (value version)
  "Return the routing entry of the address VALUE of VERSION, or nil.
The entry is a plist with :asn, :country, :description, :start and
:end.  Return nil when the database is missing or holds no covering
range."
  (if-let* ((table (net-asn--ip-table version)))
      (when-let* ((index (net--binary-find table value)))
        (list :asn (net--binary-number table index 0)
              :country (net--binary-string table index 0)
              :description (net--binary-string table index 1)
              :start (net--binary-start table index)
              :end (net--binary-end table index)))
    (let ((file (net-asn--ip-file version)))
      (when (net-data-available-p file)
        (with-temp-buffer
          (insert (net-asn--range-text file))
          (when-let* ((position (net-asn--search-row value)))
            (goto-char position)
            (let* ((fields (net-asn--range-fields))
                   (start (net-asn--address-number (nth 0 fields)))
                   (end (net-asn--address-number (nth 1 fields))))
              (when (and start end (<= start value) (<= value end))
                (list :asn (string-to-number (nth 2 fields))
                      :country (nth 3 fields)
                      :description (nth 4 fields)
                      :start start
                      :end end)))))))))

(defun net-asn-ip-description (file version)
  "Return a one-line description of the range FILE of VERSION."
  (let ((count (plist-get (net-asn--ip-table version) :count)))
    (net-data-description file (and count (format "%s ranges" count)))))

;;; Report

(defun net-asn--report-identity-section (parsed classification)
  "Return the identity section of PARSED and CLASSIFICATION."
  (let* ((asn (plist-get parsed :asn))
         (asdot (net-asn-asdot asn)))
    (list :json :identity
          :heading "Autonomous System"
          :items (delq nil
                       (list '(:field "AS number" :asn)
                             '(:field "AS notation" :notation)
                             (when asdot '(:field "ASDOT" :asdot))
                             '(:field "Class" :class)
                             '(:field "Status" :status)
                             '(:field "Reference" :reference)))
          :asn asn
          :notation (net-asn-canonical parsed)
          :asdot asdot
          :class (if (> asn 65535) "32-bit" "16-bit")
          :status (car classification)
          :reference (cdr classification))))

(defun net-asn--report-registry-section (asn)
  "Return the IANA registry section of ASN."
  (let ((row (net-asn-registry-row asn)))
    (if (null row)
        (list :json :registry
              :heading "Registry"
              :items (list '(:field "Block" :block :blockText))
              :block nil
              :blockText "not in the IANA registry")
      (let* ((range (plist-get row :range))
             (whois (plist-get row :whois))
             (whois (and whois (not (string-empty-p whois)) whois)))
        (list :json :registry
              :heading "Registry"
              :items (delq nil
                           (list '(:field "Block" :block)
                                 '(:field "Registry" :registry)
                                 (when whois '(:field "WHOIS" :whois))))
              :block (format "%d-%d" (car range) (cdr range))
              :registry (plist-get row :description)
              :whois whois)))))

(defun net-asn--report-metadata-section (entry)
  "Return the as-metadata section of ENTRY."
  (let* ((metadata (alist-get 'metadata entry))
         (code (alist-get 'countryCode metadata))
         (name (alist-get 'country metadata))
         (category (alist-get 'category metadata))
         (role (alist-get 'networkRole metadata)))
    (if (or (null entry) (null metadata))
        (list :json :metadata
              :heading "Metadata"
              :items (list '(:text "Database" :database :databaseFile))
              :database "no entry for this AS number"
              :databaseFile net-asn-database-file)
      (list :json :metadata
            :heading "Metadata"
            :items (delq nil
                         (list '(:field "Handle" :handle)
                               '(:field "Description" :description)
                               '(:field "Country" :country :countryText)
                               '(:field "Origin" :origin)
                               (when category
                                 '(:field "Category" :categoryName))
                               (when role '(:field "Network role"
                                                   :networkRoleName))
                               '(:field "Registered" :registered)
                               '(:field "Last modified" :lastModified)
                               '(:field "Last announced" :lastAnnounced)
                               '(:text "Database" :database
                                       :databaseFile)))
            :database (net-data-description net-asn-database-file)
            :databaseFile net-asn-database-file
            :handle (alist-get 'handle metadata)
            :description (alist-get 'description metadata)
            :country name
            :countryCode code
            :countryText (cond ((and code name) (format "%s (%s)" name code))
                               (code code)
                               (t nil))
            :origin (alist-get 'origin metadata)
            :category category
            :categoryName (when category
                            (or (alist-get category net-asn--categories
                                           nil nil #'equal)
                                category))
            :networkRole role
            :networkRoleName (when role
                               (or (alist-get role net-asn--roles nil nil
                                              #'equal)
                                   role))
            :registered (alist-get 'registered metadata)
            :lastModified (alist-get 'lastModified metadata)
            :lastAnnounced (alist-get 'lastAnnounced entry)))))

(defun net-asn--report-statistics-section (stats)
  "Return the routing statistics section of STATS, or nil."
  (when stats
    (let (items values)
      (dolist (family '((ipv4 "IPv4") (ipv6 "IPv6")))
        (let ((data (alist-get (car family) stats)))
          (when data
            (let* ((name (symbol-name (car family)))
                   (label (cadr family))
                   (prefixes (intern (concat ":" name "Prefixes")))
                   (aggregated (intern (concat ":" name "Aggregated")))
                   (largest (intern (concat ":" name "LargestPrefix")))
                   (largest-text
                    (intern (concat ":" name "LargestPrefixText")))
                   (addresses (intern (concat ":" name "Addresses")))
                   (length (alist-get 'largestPrefix data)))
              (setq items
                    (append items
                            (list (list :field (format "%s prefixes" label)
                                        prefixes)
                                  (list :field (format "%s aggregated" label)
                                        aggregated)
                                  (list :field (format "%s largest prefix"
                                                       label)
                                        largest largest-text)
                                  (list :field (format "%s addresses" label)
                                        addresses))))
              (setq values
                    (append values
                            (list prefixes (alist-get 'prefixes data)
                                  aggregated
                                  (alist-get 'prefixesAggregated data)
                                  largest length
                                  largest-text
                                  (when length (format "/%d" length))
                                  addresses
                                  (alist-get 'totalAddresses data))))))))
      (when items
        (append (list :json :routingStatistics
                      :heading "Routing Statistics"
                      :items items)
                values)))))

(defun net-asn--report-connectivity-section (stats)
  "Return the connectivity section of STATS, or nil."
  (when-let* ((connectivity (alist-get 'connectivity stats)))
    (let ((providers (alist-get 'providerAsns connectivity))
          (items nil))
      (dolist (field '((providers . "Providers")
                       (customers . "Customers")
                       (peers . "Peers")
                       (degree . "Degree")
                       (reach . "Reach (customer cone)")))
        (push (list :field (cdr field) (car field)) items))
      (when providers
        (push (list :links "Upstream Providers" 'asn :upstreamProviders
                    :upstreamProviderLinks)
              items))
      (list :json :connectivity
            :heading "Connectivity"
            :items (nreverse items)
            :providers (alist-get 'providers connectivity)
            :customers (alist-get 'customers connectivity)
            :peers (alist-get 'peers connectivity)
            :degree (alist-get 'degree connectivity)
            :reach (alist-get 'reach connectivity)
            :upstreamProviders providers
            :upstreamProviderLinks (mapcar (lambda (provider)
                                             (format "AS%d" provider))
                                           providers)))))

(defun net-asn-report (asn)
  "Return the report of the autonomous system number ASN.
The report holds the fields that the buffer shows and the RDAP
identity of the number."
  (let* ((parsed (net-asn-parse asn))
         (number (plist-get parsed :asn))
         (classification (net-asn-classification number))
         (entry (net-asn-entry number))
         (stats (alist-get 'stats entry)))
    (list
     :summary (format "%s, %s" (car classification) (cdr classification))
     :rdap-type "autnum"
     :rdap-key (number-to-string number)
     :rdap (list :objectClassName "autnum"
                 :startAutnum number
                 :endAutnum number)
     :sections
     (delq nil
           (list (net-asn--report-identity-section parsed classification)
                 (net-asn--report-registry-section number)
                 (net-asn--report-metadata-section entry)
                 (net-asn--report-statistics-section stats)
                 (net-asn--report-connectivity-section stats))))))

(defun net-asn--display ()
  "Render the AS number in the current buffer."
  (net--render-report (net-asn-report net--value)))

;;; Mode and entry points

(define-derived-mode net-asn-mode net-mode "Net ASN"
  "Major mode for inspecting one autonomous system number.
\\{net-mode-map}"
  :interactive nil)

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
                     :report net-asn-report
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
