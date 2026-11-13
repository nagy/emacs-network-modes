;;; net-ip.el --- Inspect IP addresses  -*- lexical-binding: t; -*-

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

;; `net-ip-mode' displays one IPv4 or IPv6 address: its integer value,
;; its canonical forms, its special-purpose classification, its reverse
;; DNS name, the embedded address of transition mechanisms, the country
;; of the covering prefix when the GeoIP database is available, and the
;; origin autonomous system when the iptoasn database is available.
;;
;; The parser and formatter in this file are also the foundation of
;; `net-cidr-mode': prefixes use bignums, so the same arithmetic works
;; for 32-bit and 128-bit address families.
;;
;; Entry points:
;;
;;   M-x net-ip-inspect      - inspect an address
;;   M-x net-ip-mode         - inspect the address in the buffer name

;;; Code:

(require 'cl-lib)
(require 'net-asn)
(require 'net-geo)
(require 'net-mode)
(require 'seq)

(defconst net-ip--ipv4-bits 32
  "Number of bits in an IPv4 address.")

(defconst net-ip--ipv6-bits 128
  "Number of bits in an IPv6 address.")

(defconst net-ip--builtin-blocks
  '((:cidr "0.0.0.0/8" :name "This network" :rfc "RFC 791" :private nil)
    (:cidr "0.0.0.0/32" :name "This host on this network" :rfc "RFC 1122" :private nil)
    (:cidr "10.0.0.0/8" :name "Private-Use" :rfc "RFC 1918" :private t)
    (:cidr "100.64.0.0/10" :name "Shared Address Space" :rfc "RFC 6598" :private t)
    (:cidr "127.0.0.0/8" :name "Loopback" :rfc "RFC 1122" :private t)
    (:cidr "169.254.0.0/16" :name "Link Local" :rfc "RFC 3927" :private t)
    (:cidr "172.16.0.0/12" :name "Private-Use" :rfc "RFC 1918" :private t)
    (:cidr "192.0.0.0/24" :name "IETF Protocol Assignments" :rfc "RFC 6890" :private nil)
    (:cidr "192.0.0.0/29" :name "IPv4 Service Continuity Prefix" :rfc "RFC 7335" :private nil)
    (:cidr "192.0.0.8/32" :name "IPv4 dummy address" :rfc "RFC 7600" :private nil)
    (:cidr "192.0.0.9/32" :name "Port Control Protocol Anycast" :rfc "RFC 7723" :private nil)
    (:cidr "192.0.0.10/32" :name "Traversal Using Relays around NAT Anycast" :rfc "RFC 8155" :private nil)
    (:cidr "192.0.0.170/32" :name "NAT64/DNS64 Discovery" :rfc "RFC 8880" :private nil)
    (:cidr "192.0.0.171/32" :name "NAT64/DNS64 Discovery" :rfc "RFC 8880" :private nil)
    (:cidr "192.0.2.0/24" :name "Documentation (TEST-NET-1)" :rfc "RFC 5737" :private nil)
    (:cidr "192.31.196.0/24" :name "AS112-v4" :rfc "RFC 7535" :private nil)
    (:cidr "192.52.193.0/24" :name "AMT" :rfc "RFC 7450" :private nil)
    (:cidr "192.168.0.0/16" :name "Private-Use" :rfc "RFC 1918" :private t)
    (:cidr "192.175.48.0/24" :name "Direct Delegation AS112 Service" :rfc "RFC 7534" :private nil)
    (:cidr "198.18.0.0/15" :name "Benchmarking" :rfc "RFC 2544" :private nil)
    (:cidr "198.51.100.0/24" :name "Documentation (TEST-NET-2)" :rfc "RFC 5737" :private nil)
    (:cidr "203.0.113.0/24" :name "Documentation (TEST-NET-3)" :rfc "RFC 5737" :private nil)
    (:cidr "224.0.0.0/4" :name "Multicast" :rfc "RFC 5771" :private nil :always t)
    (:cidr "240.0.0.0/4" :name "Reserved" :rfc "RFC 1112" :private nil)
    (:cidr "255.255.255.255/32" :name "Limited Broadcast" :rfc "RFC 919" :private nil)
    (:cidr "::/128" :name "Unspecified Address" :rfc "RFC 4291" :private nil)
    (:cidr "::1/128" :name "Loopback Address" :rfc "RFC 4291" :private nil)
    (:cidr "::ffff:0:0/96" :name "IPv4-mapped Address" :rfc "RFC 4291" :private nil)
    (:cidr "64:ff9b::/96" :name "IPv4-IPv6 Translation" :rfc "RFC 6052" :private nil)
    (:cidr "64:ff9b:1::/48" :name "Local-Use IPv4/IPv6 Translation" :rfc "RFC 8215" :private t)
    (:cidr "100::/64" :name "Discard-Only Address Block" :rfc "RFC 6666" :private nil)
    (:cidr "100:0:0:1::/64" :name "Dummy IPv6 Prefix" :rfc "RFC 9780" :private nil)
    (:cidr "2001::/23" :name "IETF Protocol Assignments" :rfc "RFC 2928" :private nil)
    (:cidr "2001::/32" :name "TEREDO" :rfc "RFC 4380" :private nil)
    (:cidr "2001:1::1/128" :name "Port Control Protocol Anycast" :rfc "RFC 7723" :private nil)
    (:cidr "2001:1::2/128" :name "Traversal Using Relays around NAT Anycast" :rfc "RFC 8155" :private nil)
    (:cidr "2001:1::3/128" :name "DNS-SD Service Registration Protocol Anycast" :rfc "RFC 9665" :private nil)
    (:cidr "2001:2::/48" :name "Benchmarking" :rfc "RFC 5180" :private nil)
    (:cidr "2001:3::/32" :name "AMT" :rfc "RFC 7450" :private nil)
    (:cidr "2001:4:112::/48" :name "AS112-v6" :rfc "RFC 7535" :private nil)
    (:cidr "2001:10::/28" :name "Deprecated (previously ORCHID)" :rfc "RFC 4843" :private nil)
    (:cidr "2001:20::/28" :name "ORCHIDv2" :rfc "RFC 7343" :private nil)
    (:cidr "2001:30::/28" :name "Drone Remote ID Protocol Entity Tags (DETs) Prefix" :rfc "RFC 9374" :private nil)
    (:cidr "2001:db8::/32" :name "Documentation" :rfc "RFC 3849" :private nil)
    (:cidr "2002::/16" :name "6to4" :rfc "RFC 3056" :private nil)
    (:cidr "2620:4f:8000::/48" :name "Direct Delegation AS112 Service" :rfc "RFC 7534" :private nil)
    (:cidr "3fff::/20" :name "Documentation" :rfc "RFC 9637" :private nil)
    (:cidr "5f00::/16" :name "Segment Routing (SRv6) SIDs" :rfc "RFC 9602" :private nil)
    (:cidr "fc00::/7" :name "Unique-Local" :rfc "RFC 4193" :private t)
    (:cidr "fe80::/10" :name "Link-Local Unicast" :rfc "RFC 4291" :private t)
    (:cidr "ff00::/8" :name "Multicast" :rfc "RFC 4291" :private nil :always t))
  "Built-in special-purpose address blocks.
Used when the IANA registry CSV files are not available.  The CSV
wins when it exists, because IANA updates it.  The rows marked with
:always stay in force either way, because the special-purpose
registries leave multicast to RFC 5771 and RFC 4291.")

;;; Parsing

(defun net-ip--parse-ipv4 (string)
  "Parse STRING as a dotted-quad IPv4 address.
Return a plist or nil.  Leading zeros are rejected to avoid the
octal ambiguity of `inet_aton'."
  (let ((parts (split-string string "\\.")))
    (when (and (= (length parts) 4)
               (cl-every (lambda (part)
                           (and (string-match-p "\\`\\(0\\|[1-9][0-9]\\{0,2\\}\\)\\'" part)
                                (<= (string-to-number part) 255)))
                         parts))
      (let ((value 0))
        (dolist (part parts)
          (setq value (+ (* value 256) (string-to-number part))))
        (list :version 4 :value value :zone nil)))))

(defun net-ip--parse-groups (string allow-ipv4)
  "Parse colon separated hexadecimal groups in STRING.
Return (OK . GROUPS).  When ALLOW-IPV4 is non-nil, the final group
can be a dotted quad and expands to two 16-bit groups."
  (let ((parts (if (string-empty-p string) nil (split-string string ":")))
        (groups nil)
        (ok t))
    (while (and parts ok)
      (let ((part (pop parts)))
        (cond
         ((and allow-ipv4 (null parts) (string-match-p "\\." part))
          (let ((v4 (net-ip--parse-ipv4 part)))
            (if v4
                (let ((value (plist-get v4 :value)))
                  (push (ash value -16) groups)
                  (push (logand value #xffff) groups))
              (setq ok nil))))
         ((string-match-p "\\`[0-9A-Fa-f]\\{1,4\\}\\'" part)
          (push (string-to-number part 16) groups))
         (t (setq ok nil)))))
    (if ok (cons t (nreverse groups)) (cons nil nil))))

(defun net-ip--groups-value (groups)
  "Return the integer value of the 16-bit GROUPS."
  (declare (pure t) (side-effect-free t))
  (let ((value 0))
    (dolist (group groups value)
      (setq value (logior (ash value 16) group)))))

(defun net-ip--parse-ipv6 (string)
  "Parse STRING as an IPv6 address.  Return a plist or nil."
  (let ((zone nil)
        (text string))
    (when (string-match "%\\([^%[:space:]/]+\\)\\'" text)
      (setq zone (match-string 1 text)
            text (substring text 0 (match-beginning 0))))
    (when (and (not (string-empty-p text))
               (string-match-p ":" text)
               (not (string-match-p ":::" text)))
      (let* ((double (string-match "::" text))
             (head-text (if double (substring text 0 double) text))
             (tail-text (when double (substring text (+ double 2))))
             (head-result (net-ip--parse-groups head-text (not double)))
             (tail-result (if double
                              (net-ip--parse-groups (or tail-text "") t)
                            (cons t nil)))
             (head (cdr head-result))
             (tail (cdr tail-result)))
        (cond
         ((not double)
          (when (and (car head-result) (= (length head) 8))
            (list :version 6 :value (net-ip--groups-value head) :zone zone)))
         ((and (car head-result)
               (car tail-result)
               (<= (+ (length head) (length tail)) 7))
          (let ((groups (append head
                                (make-list (- 8 (length head) (length tail)) 0)
                                tail)))
            (list :version 6 :value (net-ip--groups-value groups) :zone zone))))))))

;;;###autoload
(defun net-ip-parse (string)
  "Parse STRING as an IPv4 or IPv6 address.
Return a plist with :version, :value and :zone, or nil."
  (when (and (stringp string) (not (string-empty-p (string-trim string))))
    (let ((text (string-trim string)))
      (cond
       ((string-match-p ":" text) (net-ip--parse-ipv6 text))
       ((string-match-p "\\." text) (net-ip--parse-ipv4 text))))))

;;; Formatting

(defun net-ip--format-ipv4 (value)
  "Return the dotted-quad form of the IPv4 integer VALUE."
  (declare (pure t) (side-effect-free t))
  (mapconcat (lambda (shift)
               (number-to-string (logand (ash value (- shift)) #xff)))
             '(24 16 8 0)
             "."))

(defun net-ip--groups (value)
  "Return the eight 16-bit groups of the IPv6 integer VALUE."
  (declare (pure t) (side-effect-free t))
  (let (groups)
    (dotimes (index 8)
      (push (logand (ash value (- (* 16 (- 7 index)))) #xffff) groups))
    (nreverse groups)))

(defun net-ip--format-ipv6 (value)
  "Return the compressed lowercase form of the IPv6 integer VALUE.
The longest run of at least two zero groups becomes \"::\", as
RFC 5952 requires."
  (declare (pure t) (side-effect-free t))
  (let* ((groups (net-ip--groups value))
         (index 0)
         (best-start nil)
         (best-length 0))
    (while (< index 8)
      (if (zerop (nth index groups))
          (let ((start index))
            (while (and (< index 8) (zerop (nth index groups)))
              (cl-incf index))
            (when (> (- index start) best-length)
              (setq best-start start
                    best-length (- index start))))
        (cl-incf index)))
    (when (< best-length 2)
      (setq best-start nil))
    (if (null best-start)
        (mapconcat (lambda (group) (format "%x" group)) groups ":")
      (concat (mapconcat (lambda (group) (format "%x" group))
                         (seq-take groups best-start)
                         ":")
              "::"
              (mapconcat (lambda (group) (format "%x" group))
                         (seq-drop groups (+ best-start best-length))
                         ":")))))

(defun net-ip--format-ipv6-full (value)
  "Return the fully expanded IPv6 form of the integer VALUE."
  (declare (pure t) (side-effect-free t))
  (mapconcat (lambda (group) (format "%04x" group))
             (net-ip--groups value)
             ":"))

(defun net-ip-format (value version)
  "Format the integer VALUE as an address of VERSION."
  (declare (pure t) (side-effect-free t))
  (if (= version 4)
      (net-ip--format-ipv4 value)
    (net-ip--format-ipv6 value)))

(defun net-ip-canonical (parsed)
  "Return the canonical string of the parsed address PARSED."
  (declare (pure t) (side-effect-free t))
  (let ((text (net-ip-format (plist-get parsed :value)
                             (plist-get parsed :version))))
    (if-let* ((zone (plist-get parsed :zone)))
        (concat text "%" zone)
      text)))

(defun net-ip-reverse-dns (value version)
  "Return the reverse DNS name of the address VALUE of VERSION."
  (if (= version 4)
      (concat (mapconcat #'identity
                         (nreverse (split-string (net-ip--format-ipv4 value) "\\."))
                         ".")
              ".in-addr.arpa")
    (let ((hex (format "%032x" value)))
      (concat (mapconcat #'identity
                         (nreverse (mapcar #'char-to-string (string-to-list hex)))
                         ".")
              ".ip6.arpa"))))

;;; Blocks

(defun net-ip--block (cidr)
  "Return the parsed block of CIDR as a plist.
The plist holds :version, :prefix, :start and :last."
  (when (and (stringp cidr) (string-match "\\`\\([^/]+\\)/\\([0-9]+\\)\\'" cidr))
    (let* ((address (match-string 1 cidr))
           (prefix (string-to-number (match-string 2 cidr)))
           (parsed (net-ip-parse address))
           (bits (and parsed (net-ip--bits (plist-get parsed :version)))))
      (when (and parsed (<= 0 prefix bits))
        (let* ((host-bits (- bits prefix))
               (mask (ash (1- (ash 1 prefix)) host-bits))
               (start (logand (plist-get parsed :value) mask))
               (size (ash 1 host-bits)))
          (list :version (plist-get parsed :version)
                :prefix prefix
                :start start
                :last (+ start (1- size))))))))

(defun net-ip--bits (version)
  "Return the number of address bits of VERSION."
  (declare (pure t) (side-effect-free t))
  (if (= version 4) net-ip--ipv4-bits net-ip--ipv6-bits))

(defun net-ip-in-block-p (value version block)
  "Return non-nil when VALUE of VERSION falls inside BLOCK.
BLOCK is a plist as returned by `net-ip--block'."
  (declare (pure t) (side-effect-free t))
  (and block
       (= version (plist-get block :version))
       (<= (plist-get block :start) value)
       (<= value (plist-get block :last))))

(defconst net-ip--private-blocks
  '("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "fc00::/7")
  "Blocks that the RFCs reserve for private use.
RFC 1918 covers the IPv4 blocks and RFC 4193 covers the IPv6 block.")

(defun net-ip-private-range-p (start last version)
  "Return non-nil when START to LAST of VERSION is entirely private.
Private means inside an RFC 1918 IPv4 block or inside the RFC 4193
unique-local IPv6 block."
  (cl-some (lambda (cidr)
             (let ((block (net-ip--block cidr)))
               (and block
                    (= version (plist-get block :version))
                    (<= (plist-get block :start) start)
                    (<= last (plist-get block :last)))))
           net-ip--private-blocks))

(defun net-ip-private-p (value version)
  "Return non-nil when VALUE of VERSION is a private address."
  (net-ip-private-range-p value value version))

;;; Registry

(defcustom net-ip-registry-file (net-data-file "iana-ipv4-special-registry.csv")
  "IANA IPv4 special-purpose registry CSV file, or nil.
Download it from
https://www.iana.org/assignments/iana-ipv4-special-registry/
The `net-cidr-registry-file` alias names the same option."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defcustom net-ip-registry-file-v6 (net-data-file "iana-ipv6-special-registry.csv")
  "IANA IPv6 special-purpose registry CSV file, or nil.
Download it from
https://www.iana.org/assignments/iana-ipv6-special-registry/
The `net-cidr-registry-file-v6` alias names the same option."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defvar net-ip--registry-cache nil
  "Alist of (FILE MTIME SIZE . ENTRIES) for parsed registry files.")

(defun net-ip--registry-blocks (field)
  "Return the address blocks of the registry FIELD.
The field can hold several comma separated blocks and a footnote
marker such as \" [2]\"."
  (let ((blocks nil))
    (dolist (part (split-string field ","))
      (let ((block (string-trim
                    (replace-regexp-in-string
                     "[[:space:]]*\\[[0-9]+\\][[:space:]]*\\'" ""
                     part))))
        (when (string-match-p "/" block)
          (push block blocks))))
    (nreverse blocks)))

(defun net-ip--registry-entries (file)
  "Return the parsed registry entries of FILE, or nil."
  (when (net-data-available-p file)
    (let* ((attributes (file-attributes file))
           (key (list file
                      (file-attribute-modification-time attributes)
                      (file-attribute-size attributes)))
           (cached (assoc key net-ip--registry-cache)))
      (if cached
          (cdr cached)
        (let ((entries nil))
          (dolist (record (cdr (net--read-csv-file file)))
            (when (>= (length record) 9)
              (let ((name (nth 1 record))
                    (rfc (nth 2 record))
                    (source (nth 5 record))
                    (destination (nth 6 record))
                    (forwardable (nth 7 record))
                    (global (nth 8 record)))
                (dolist (block (net-ip--registry-blocks (nth 0 record)))
                  (push (list :cidr block
                              :name name
                              :rfc rfc
                              :source source
                              :destination destination
                              :forwardable forwardable
                              :global global)
                        entries)))))
          (setq entries (nreverse entries))
          (setq net-ip--registry-cache
                (cons (cons key entries) net-ip--registry-cache))
          entries)))))

(defun net-ip-registry-entries (version)
  "Return the special-purpose registry entries of VERSION.
Return nil when the matching CSV file is not available."
  (net-ip--registry-entries
   (if (= version 4) net-ip-registry-file net-ip-registry-file-v6)))

(defun net-ip--builtin-entries (version)
  "Return the built-in special-purpose entries of VERSION."
  (let ((entries nil))
    (dolist (entry net-ip--builtin-blocks)
      (let ((block (net-ip--block (plist-get entry :cidr))))
        (when (and block (= version (plist-get block :version)))
          (push (list :cidr (plist-get entry :cidr)
                      :name (plist-get entry :name)
                      :rfc (plist-get entry :rfc)
                      :private (plist-get entry :private)
                      :always (plist-get entry :always)
                      :builtin t)
                entries))))
    (nreverse entries)))

(defun net-ip-matching-blocks (value version &optional last)
  "Return the special-purpose blocks that cover VALUE of VERSION.
LAST defaults to VALUE and widens the test to a whole address range,
which `net-cidr-mode' uses for a prefix.  The most specific block
comes first.  The IANA registry CSV wins over the built-in table
when it exists.  The built-in multicast rows stay in force, because
the special-purpose registries leave multicast to RFC 5771 and
RFC 4291."
  (let* ((end (or last value))
         (entries (net-ip--classification-entries version))
         (matches nil))
    (dolist (entry entries)
      (let ((block (net-ip--block (plist-get entry :cidr))))
        (when (and block
                   (= version (plist-get block :version))
                   (<= (plist-get block :start) value)
                   (<= end (plist-get block :last)))
          (push (append entry (list :block block)) matches))))
    (sort matches
          (lambda (a b)
            (> (plist-get (plist-get a :block) :prefix)
               (plist-get (plist-get b :block) :prefix))))))

(defun net-ip--classification-entries (version)
  "Return the classification entries of VERSION.
Take the IANA registry CSV when it exists and the built-in table
otherwise.  Add the built-in rows that the CSV cannot repeat, so the
multicast blocks stay classified."
  (let ((csv (net-ip-registry-entries version))
        (builtin (net-ip--builtin-entries version)))
    (if (null csv)
        builtin
      (append csv
              (seq-filter (lambda (entry) (plist-get entry :always))
                          builtin)))))

;;; Report

(defun net-ip--binary-string (value)
  "Return the dotted binary form of the IPv4 VALUE."
  (declare (pure t) (side-effect-free t))
  (mapconcat (lambda (octet)
               (let ((bits nil))
                 (dotimes (index 8)
                   (push (if (zerop (logand (ash octet (- (- 7 index))) 1))
                             ?0 ?1)
                         bits))
                 (apply #'string (nreverse bits))))
             (list (logand (ash value -24) #xff)
                   (logand (ash value -16) #xff)
                   (logand (ash value -8) #xff)
                   (logand value #xff))
             "."))

(defun net-ip--range-prefix (start end version)
  "Return the prefix text of the address range START to END of VERSION.
Return nil when the range is not exactly one aligned prefix block."
  (declare (pure t) (side-effect-free t))
  (let* ((size (1+ (- end start)))
         (bits (if (= version 4) net-ip--ipv4-bits net-ip--ipv6-bits))
         (value size)
         (shift 0))
    (while (and (> value 1) (zerop (logand value 1)))
      (setq value (ash value -1))
      (cl-incf shift))
    (let ((length (- bits shift)))
      (when (and (= value 1)
                 (>= length 0)
                 (zerop (logand start (1- size))))
        (format "%s/%d" (net-ip-format start version) length)))))

(defun net-ip--report-address-section (parsed)
  "Return the address section of PARSED."
  (let* ((value (plist-get parsed :value))
         (version (plist-get parsed :version)))
    (list :json :address
          :heading "Address"
          :items (list '(:field "Address" :address)
                       '(:field "Version" :version)
                       '(:field "Integer" :integer)
                       '(:field "Hex" :hex)
                       (if (= version 4)
                           '(:field "Binary" :binary)
                         '(:field "Expanded" :expanded)))
          :address (net-ip-canonical parsed)
          :version (format "IPv%d" version)
          :integer value
          :hex (format "0x%x" value)
          :binary (when (= version 4) (net-ip--binary-string value))
          :expanded (when (= version 6)
                      (net-ip--format-ipv6-full value)))))

(defun net-ip--report-classification-section (parsed matches)
  "Return the classification section of PARSED and MATCHES."
  (let* ((value (plist-get parsed :value))
         (version (plist-get parsed :version))
         (best (car matches))
         (block (plist-get best :block))
         (private (net-ip-private-p value version)))
    (list :json :classification
          :heading "Classification"
          :items (append
                  (if best
                      (list '(:field "Class" :class)
                            '(:field "Registry" :rfc)
                            '(:field "Block" :block))
                    (list '(:field "Class" :class)))
                  (list '(:field "Private" :private :privateText)))
          :class (if best
                     (plist-get best :name)
                   "Global unicast (no special-purpose block)")
          :rfc (when best (plist-get best :rfc))
          :block (when block
                   (format "%s/%d"
                           (net-ip-format (plist-get block :start) version)
                           (plist-get block :prefix)))
          :private (if private t :json-false)
          :privateText (if private
                           (if (= version 4) "yes (RFC 1918)" "yes (RFC 4193)")
                         "no"))))

(defun net-ip--report-special-section (matches version)
  "Return the special-purpose block section of MATCHES of VERSION.
Return nil when one block suffices, because the classification
section already names it."
  (when (> (length matches) 1)
    (list :json :specialPurposeBlocks
          :heading "All Special-Purpose Blocks"
          :records
          (mapcar (lambda (entry)
                    (let ((cidr (format "%s/%d"
                                        (net-ip-format
                                         (plist-get (plist-get entry :block)
                                                    :start)
                                         version)
                                        (plist-get (plist-get entry :block)
                                                   :prefix))))
                      (list :items (list (list :link
                                               (plist-get entry :name)
                                               'cidr cidr))
                            :json (list :name (plist-get entry :name)
                                        :cidr cidr))))
                  matches))))

(defun net-ip--related-record (label role kind value)
  "Return one related address record.
LABEL names the row, ROLE names it in the JSON, KIND names the
address kind of VALUE."
  (declare (pure t) (side-effect-free t))
  (list :items (list (list :link label kind value))
        :json (list :role role :kind (if (eq kind 'cidr) "cidr" "ip")
                    :value value)))

(defun net-ip--report-related-section (parsed)
  "Return the related address section of PARSED."
  (let* ((value (plist-get parsed :value))
         (version (plist-get parsed :version))
         (text (net-ip-canonical parsed))
         (host-prefix (if (= version 4) 32 128))
         (records
          (list (net-ip--related-record
                 "Host prefix" "hostPrefix" 'cidr
                 (format "%s/%d" text host-prefix)))))
    (when (and (= version 6)
               (net-ip-in-block-p value 6 (net-ip--block "::ffff:0:0/96")))
      (setq records
            (append records
                    (list (net-ip--related-record
                           "Embedded IPv4" "embeddedIpv4" 'ip
                           (net-ip--format-ipv4 (logand value #xffffffff)))))))
    (when (and (= version 6)
               (net-ip-in-block-p value 6 (net-ip--block "2002::/16")))
      (setq records
            (append records
                    (list (net-ip--related-record
                           "6to4 embedded IPv4" "sixToFourEmbeddedIpv4" 'ip
                           (net-ip--format-ipv4
                            (logand (ash value -80) #xffffffff)))))))
    (when (and (= version 6)
               (net-ip-in-block-p value 6 (net-ip--block "2001::/32")))
      (setq records
            (append records
                    (list (net-ip--related-record
                           "Teredo server IPv4" "teredoServerIpv4" 'ip
                           (net-ip--format-ipv4 (logand (ash value -64)
                                                        #xffffffff)))
                          (net-ip--related-record
                           "Teredo client IPv4" "teredoClientIpv4" 'ip
                           (net-ip--format-ipv4
                            (logand (lognot (logand value #xffffffff))
                                    #xffffffff)))))))
    (when (and (= version 4)
               (not (net-ip-in-block-p value 4 (net-ip--block "224.0.0.0/4"))))
      (setq records
            (append records
                    (list (net-ip--related-record
                           "IPv4-mapped IPv6" "ipv4MappedIpv6" 'ip
                           (net-ip--format-ipv6
                            (logior (ash #xffff 32) value)))))))
    (list :json :related
          :heading "Related"
          :records records)))

(defun net-ip--report-reverse-section (parsed)
  "Return the reverse DNS section of PARSED."
  (list :json :reverseDns
        :heading "Reverse DNS"
        :items (list '(:field "Name" :name))
        :name (net-ip-reverse-dns (plist-get parsed :value)
                                  (plist-get parsed :version))))

(defun net-ip--report-geo-section (parsed)
  "Return the GeoIP section of PARSED, or nil without a database."
  (let* ((version (plist-get parsed :version))
         (file (if (= version 4)
                   net-geo-database-file
                 net-geo-database-file-v6)))
    (when (net-data-available-p file)
      (let ((country (net-geo-country (plist-get parsed :value) version)))
        (list :json :geoip
              :heading "GeoIP"
              :items (list '(:field "Country" :country :countryText)
                           '(:text "Database" :source :sourceFile))
              :country country
              :countryText (or country "no match")
              :source (net-geo-description file version)
              :sourceFile file)))))

(defun net-ip--report-asn-section (parsed)
  "Return the origin AS section of PARSED, or nil without a database."
  (let* ((version (plist-get parsed :version))
         (value (plist-get parsed :value))
         (file (if (= version 4)
                   net-asn-ip-database-file
                 net-asn-ip-database-file-v6)))
    (when (net-data-available-p file)
      (let* ((entry (net-asn-ip-entry value version))
             (asn (plist-get entry :asn))
             (start (plist-get entry :start))
             (end (plist-get entry :end))
             (country (plist-get entry :country))
             (prefix (and entry (net-ip--range-prefix start end version)))
             (routed (and entry (/= asn 0)))
             (items nil))
        (cond
         ((null entry)
          (setq items (list '(:field "AS" :asn :asnText))))
         ((zerop asn)
          (setq items (list '(:field "AS" :asn :asnText))))
         (t
          (setq items (list (list :link "AS" 'asn :asn :asnText)
                            (list :field "Country" :country)
                            (list :field "Organisation" :organisation)
                            (if prefix
                                (list :link "Prefix" 'cidr :prefix)
                              (list :field "Range" :range))))))
        (list :json :originAs
              :heading "Autonomous System"
              :items (append items
                             (list '(:text "Database" :source :sourceFile)))
              :asn asn
              :asnText (cond ((null entry) "no match")
                             ((zerop asn) "0 (not routed)")
                             (t (format "AS%d" asn)))
              :country (and routed (unless (equal country "None") country))
              :organisation (and routed (plist-get entry :description))
              :prefix (and routed prefix)
              :range (and routed
                          (format "%s - %s"
                                  (net-ip-format start version)
                                  (net-ip-format end version)))
              :source (net-asn-ip-description file version)
              :sourceFile file)))))

(defun net-ip-report (address)
  "Return the report of the IP ADDRESS.
The report holds the fields that the buffer shows and the RDAP
identity of the address.  `net--render-report' renders it, and
`net-json-view' encodes it."
  (let* ((parsed (net-ip-parse address))
         (value (plist-get parsed :value))
         (version (plist-get parsed :version))
         (matches (net-ip-matching-blocks value version))
         (best (car matches))
         (text (net-ip-format value version)))
    (list
     :summary (format "IPv%d, %s" version
                      (if best (plist-get best :name) "global unicast"))
     :rdap-type "ip"
     :rdap-key text
     :rdap (list :objectClassName "ip network"
                 :ipVersion (format "v%d" version)
                 :startAddress text
                 :endAddress text)
     :sections
     (delq nil
           (list (net-ip--report-address-section parsed)
                 (net-ip--report-classification-section parsed matches)
                 (net-ip--report-special-section matches version)
                 (net-ip--report-reverse-section parsed)
                 (net-ip--report-related-section parsed)
                 (net-ip--report-geo-section parsed)
                 (net-ip--report-asn-section parsed))))))

(defun net-ip--display ()
  "Render the IP address in the current buffer."
  (net--render-report (net-ip-report net--value)))

;;; Mode and entry points

(define-derived-mode net-ip-mode net-mode "Net IP"
  "Major mode for inspecting one IP address.
\\{net-mode-map}"
  :interactive nil)

;;;###autoload
(defun net-ip-inspect (address)
  "Inspect the IP ADDRESS in a `net-ip-mode' buffer."
  (interactive
   (list (or (when-let* ((bounds (bounds-of-thing-at-point 'net-ip)))
               (buffer-substring-no-properties (car bounds) (cdr bounds)))
             (read-string "IP address: "))))
  (let ((parsed (net-ip-parse address)))
    (unless parsed
      (user-error "Not an IP address: %s" address))
    (net-display 'ip (net-ip-canonical parsed)
                 #'net-ip-mode #'net-ip--display)))

(defun net-ip--sniff (string)
  "Return the canonical form of STRING when it is an IP address."
  (when-let* ((parsed (net-ip-parse string)))
    (net-ip-canonical parsed)))

(net-register-kind 'ip
                   '(:label "IP"
                     :open net-ip-inspect
                     :report net-ip-report
                     :sniff net-ip--sniff
                     :priority 40))

;; The zone identifier follows a percent sign and holds an interface
;; name, so the character set needs every letter, not only a-f.
(put 'net-ip 'bounds-of-thing-at-point
     (lambda ()
       (net--thing-bounds "0-9A-Za-z:.%_-" #'net-ip-parse)))
(put 'net-ip 'thing-at-point
     (lambda ()
       (when-let* ((bounds (bounds-of-thing-at-point 'net-ip)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(provide 'net-ip)
;;; net-ip.el ends here
