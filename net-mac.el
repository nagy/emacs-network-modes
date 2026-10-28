;;; net-mac.el --- Inspect MAC addresses  -*- lexical-binding: t; -*-

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

;; `net-mac-mode' displays one MAC address (48-bit) or EUI-64
;; identifier (64-bit): the usual notations, the integer value, the
;; multicast and locally administered bits, known link-layer multicast
;; addresses, and the vendor of the assigned prefix.
;;
;; The vendor data comes from the five IEEE registry CSVs:
;;
;;   https://standards-oui.ieee.org/oui/oui.csv       MA-L
;;   https://standards-oui.ieee.org/oui28/mam.csv     MA-M
;;   https://standards-oui.ieee.org/oui36/oui36.csv   MA-S
;;   https://standards-oui.ieee.org/iab/iab.csv       IAB
;;   https://standards-oui.ieee.org/cid/cid.csv       CID
;;
;; The Nix package pins the five files and points
;; `net-mac-registry-directory' at the store copy.  Wireshark's manuf
;; file is an optional second source with short and long vendor names.
;;
;; Entry points:
;;
;;   M-x net-mac-inspect      - inspect a MAC address

;;; Code:

(require 'cl-lib)
(require 'net-ip)
(require 'net-mode)

(defcustom net-mac-registry-directory net-data-directory
  "Directory with the IEEE MAC address registry CSV files, or nil.
The files keep their upstream names: oui.csv, mam.csv, oui36.csv,
iab.csv and cid.csv.  The Nix package points this option at a pinned
copy."
  :type '(choice (const :tag "None" nil) directory)
  :group 'net)

(defcustom net-mac-manuf-file nil
  "Wireshark manuf file, or nil.
Download it from
https://www.wireshark.org/download/automated/data/manuf
The file is optional: the IEEE registries supply vendor names.  The
manuf file adds the eight character short names that Wireshark uses."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defconst net-mac--registry-files
  '((9 "oui36.csv" "iab.csv")
    (7 "mam.csv")
    (6 "oui.csv" "cid.csv"))
  "Registry files to try for each prefix length.
MA-S and IAB share the 36-bit length, and CID shares 24 bits with
MA-L, so the first file with a matching assignment wins.")

(defconst net-mac--special
  '(("ff:ff:ff:ff:ff:ff" . "Broadcast")
    ("01:80:c2:00:00:0e" . "LLDP")
    ("01:80:c2:00:00:03" . "IEEE 802.3x flow control")
    ("01:80:c2:00:00:02" . "LACP (IEEE 802.3ad)")
    ("01:80:c2:00:00:00" . "STP BPDU (IEEE 802.1D)")
    ("01:80:c2" . "IEEE 802.1D link-local")
    ("01:00:0c:cc:cc:cd" . "Cisco PVST+")
    ("01:00:0c:cc:cc:cc" . "Cisco CDP")
    ("01:00:5e" . "IPv4 multicast")
    ("33:33" . "IPv6 multicast"))
  "Known link-layer multicast and broadcast addresses.
The longest matching prefix wins.")

(defvar net-mac--registry-cache nil
  "Alist of (KEY . TEXT) for the IEEE registry files.")

(defvar net-mac--manuf-cache nil
  "Cons of (KEY . TABLE) for the parsed Wireshark manuf file.")

;;; Parsing

(defun net-mac-parse (string)
  "Parse STRING as a MAC address or EUI-64 identifier.
Return a plist with :octets, :bits and :hex, or nil."
  (when (stringp string)
    (let ((text (string-trim string)))
      (when (or (string-match-p "\\`\\([0-9A-Fa-f]\\{2\\}[:-]\\)\\{5\\}[0-9A-Fa-f]\\{2\\}\\'" text)
                (string-match-p "\\`\\([0-9A-Fa-f]\\{2\\}[:-]\\)\\{7\\}[0-9A-Fa-f]\\{2\\}\\'" text)
                (string-match-p "\\`[0-9A-Fa-f]\\{4\\}\\(\\.[0-9A-Fa-f]\\{4\\}\\)\\{2,3\\}\\'" text)
                (string-match-p "\\`[0-9A-Fa-f]\\{12\\}\\'" text)
                (string-match-p "\\`[0-9A-Fa-f]\\{16\\}\\'" text))
        (let* ((hex (replace-regexp-in-string "[^0-9A-Fa-f]" "" text))
               (length (length hex))
               (octets nil)
               (index 0))
          (while (< index length)
            (push (string-to-number (substring hex index (+ index 2)) 16) octets)
            (setq index (+ index 2)))
          (list :octets (nreverse octets)
                :bits (* length 4)
                :hex (upcase hex)))))))

(defun net-mac-hex (parsed)
  "Return the uppercase hex digits of the parsed address PARSED."
  (plist-get parsed :hex))

(defun net-mac--prefix-string (hex count)
  "Format HEX as colon separated groups of up to COUNT digits."
  (let ((groups nil)
        (index 0))
    (while (< index count)
      (push (substring hex index (min count (+ index 2))) groups)
      (setq index (+ index 2)))
    (mapconcat #'identity (nreverse groups) ":")))

(defun net-mac-canonical (parsed)
  "Return the canonical lowercase string of the parsed address PARSED."
  (downcase (net-mac--prefix-string (plist-get parsed :hex)
                                    (length (plist-get parsed :hex)))))

;;; Vendor lookup

(defun net-mac--registry-available-p ()
  "Return non-nil when the registry directory holds oui.csv."
  (and (stringp net-mac-registry-directory)
       (net-data-available-p
        (expand-file-name "oui.csv" net-mac-registry-directory))))

(defun net-mac--registry-text (path)
  "Return the text of the registry file PATH, or nil.
Reload the text when the file changes."
  (when (net-data-available-p path)
    (let* ((attributes (file-attributes path))
           (key (list path
                      (file-attribute-modification-time attributes)
                      (file-attribute-size attributes)))
           (cached (assoc key net-mac--registry-cache)))
      (if cached
          (cdr cached)
        (let ((text (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string))))
          (setq net-mac--registry-cache
                (cons (cons key text) net-mac--registry-cache))
          text)))))

(defun net-mac--registry-row (file assignment)
  "Return the IEEE registry row for FILE at ASSIGNMENT, or nil.
FILE is a name inside `net-mac-registry-directory'."
  (when net-mac-registry-directory
    (when-let* ((path (expand-file-name file net-mac-registry-directory))
                (text (net-mac--registry-text path)))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (when (re-search-forward
               (format "^[^,\n]+,%s," (regexp-quote assignment)) nil t)
          (let ((fields
                 (net--split-csv-line
                  (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position)))))
            (when (>= (length fields) 4)
              (list :file file
                    :registry (nth 0 fields)
                    :prefix (nth 1 fields)
                    :name (nth 2 fields)
                    :address (nth 3 fields)))))))))

(defun net-mac-ieee-entry (parsed)
  "Return (PREFIX . ENTRY) for PARSED from the IEEE registries, or nil.
Try the 36-bit, 28-bit and 24-bit assignment lengths in turn."
  (when (net-mac--registry-available-p)
    (let ((hex (net-mac-hex parsed)))
      (cl-loop for length in '(9 7 6)
               when (>= (length hex) length)
               thereis (cl-loop for file in (cdr (assq length net-mac--registry-files))
                                for entry = (net-mac--registry-row
                                             file (substring hex 0 length))
                                when entry
                                return (cons (substring hex 0 length)
                                             entry))))))

(defun net-mac--manuf-table ()
  "Return (KEY . TABLE) with the parsed manuf file, or nil.
TABLE maps \"BITS:PREFIX\" to a plist with :mask, :short and :long."
  (when (net-data-available-p net-mac-manuf-file)
    (let* ((attributes (file-attributes net-mac-manuf-file))
           (key (list net-mac-manuf-file
                      (file-attribute-modification-time attributes)
                      (file-attribute-size attributes))))
      (if (and net-mac--manuf-cache
               (equal (car net-mac--manuf-cache) key))
          (cdr net-mac--manuf-cache)
        (let ((table (make-hash-table :test #'equal :size 20000)))
          (with-temp-buffer
            (insert-file-contents net-mac-manuf-file)
            (goto-char (point-min))
            (while (not (eobp))
              (let ((line (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))))
                (unless (or (string-empty-p line) (string-prefix-p "#" line))
                  (let ((fields (split-string line "\t")))
                    (when (>= (length fields) 3)
                      (let* ((field (string-trim (nth 0 fields)))
                             (prefix field)
                             (mask nil))
                        (when (string-match
                               "\\`\\([^/]+\\)/\\([0-9]+\\)\\'" field)
                          (setq prefix (match-string 1 field))
                          (setq mask (string-to-number (match-string 2 field))))
                        (let* ((hex (upcase (replace-regexp-in-string
                                             "[^0-9A-Fa-f]" "" prefix)))
                               (bits (or mask (* 4 (length hex))))
                               (length (/ bits 4)))
                          (when (and (> bits 0)
                                     (zerop (% bits 4))
                                     (>= (length hex) length))
                            (puthash
                             (format "%d:%s" bits (substring hex 0 length))
                             (list :mask bits
                                   :short (nth 1 fields)
                                   :long (nth 2 fields))
                             table))))))))
              (forward-line 1)))
          (setq net-mac--manuf-cache (cons key table))
          table)))))

(defun net-mac-manuf-entry (parsed)
  "Return the Wireshark manuf entry of PARSED, or nil."
  (when-let* ((table (net-mac--manuf-table)))
    (let ((hex (net-mac-hex parsed)))
      (cl-loop for length in '(9 7 6)
               for prefix = (and (>= (length hex) length)
                                 (substring hex 0 length))
               for entry = (and prefix
                                (gethash (format "%d:%s" (* length 4) prefix)
                                         table))
               when entry
               return entry))))

;;; Display

(defun net-mac--insert-address-section (parsed)
  "Insert the notation fields of PARSED."
  (net-insert-heading "Address")
  (let* ((octets (plist-get parsed :octets))
         (hex (net-mac-hex parsed))
         (bits (plist-get parsed :bits)))
    (net-insert-field "Normalized" (net-mac-canonical parsed))
    (net-insert-field "Uppercase" (net-mac--prefix-string hex (/ bits 4)))
    (net-insert-field "Hyphenated"
                      (mapconcat #'downcase
                                 (split-string (net-mac-canonical parsed) ":")
                                 "-"))
    (when (= bits 48)
      (net-insert-field "Cisco"
                        (format "%s.%s.%s"
                                (substring hex 0 4)
                                (substring hex 4 8)
                                (substring hex 8 12))))
    (net-insert-field "Bare hex" hex)
    (net-insert-field "Integer"
                      (let ((value 0))
                        (dolist (octet octets value)
                          (setq value (+ (* value 256) octet)))))
    (net-insert-field "Bits" bits)))

(defun net-mac--insert-flags-section (parsed)
  "Insert the bit fields of PARSED."
  (net-insert-heading "Flags")
  (let* ((octets (plist-get parsed :octets))
         (first (car octets))
         (multicast (= 1 (logand first #x01)))
         (local (= 1 (logand (ash first -1) #x01))))
    (net-insert-field "Address type" (if multicast "multicast" "unicast"))
    (net-insert-field "Administration"
                      (if local
                          "locally administered"
                        "universally administered (OUI)"))
    (net-insert-field "I/G bit" (if multicast 1 0))
    (net-insert-field "U/L bit" (if local 1 0))
    (let ((canonical (net-mac-canonical parsed))
          (special nil))
      (dolist (entry net-mac--special)
        (let ((prefix (car entry)))
          (when (and (not special)
                     (or (string= canonical prefix)
                         (string-prefix-p (concat prefix ":") canonical)))
            (setq special (cdr entry)))))
      (when special
        (net-insert-field "Special" special)))))

(defun net-mac--insert-vendor-section (parsed)
  "Insert the assignment fields of PARSED."
  (net-insert-heading "Assignment")
  (if (not (net-mac--registry-available-p))
      (net-insert-text "Database"
                       "unset (customize `net-mac-registry-directory')")
    (let ((vendor (net-mac-ieee-entry parsed)))
      (if (null vendor)
          (net-insert-field "Prefix" "not assigned")
        (let* ((prefix (car vendor))
               (entry (cdr vendor))
               (registry (plist-get entry :registry))
               (address (plist-get entry :address)))
          (net-insert-field "Prefix"
                            (format "%s/%d"
                                    (net-mac--prefix-string prefix
                                                             (length prefix))
                                    (* 4 (length prefix))))
          (net-insert-field "Vendor" (plist-get entry :name))
          (net-insert-field "Registry" registry)
          (net-insert-field "Block size"
                            (pcase registry
                              ("MA-L" "2^24 addresses")
                              ("MA-M" "2^20 addresses")
                              ("MA-S" "2^12 addresses")
                              ("IAB" "2^12 addresses")
                              ("CID" "2^24 addresses (company ID)")
                              (_ "unknown")))
          (when (and address (not (string-empty-p address)))
            (net-insert-field "Organization address" address))
          (net-insert-text "Source" (plist-get entry :file))))))
  (when-let* ((entry (net-mac-manuf-entry parsed)))
    (net-insert-heading "Wireshark manuf")
    (net-insert-field "Short name" (plist-get entry :short))
    (net-insert-field "Long name" (plist-get entry :long))
    (net-insert-field "Mask bits" (plist-get entry :mask))
    (net-insert-text "Source" (file-name-nondirectory net-mac-manuf-file))))

(defun net-mac--insert-eui64-section (parsed)
  "Insert the IPv6 interface identifier of PARSED."
  (when (= (plist-get parsed :bits) 48)
    (let* ((octets (plist-get parsed :octets))
           (first (logxor (nth 0 octets) #x02))
           (identifier (list first (nth 1 octets) (nth 2 octets)
                             #xff #xfe
                             (nth 3 octets) (nth 4 octets) (nth 5 octets)))
           (value (logior (ash #xfe80 112)
                          (let ((result 0))
                            (dolist (octet identifier result)
                              (setq result (logior (ash result 8) octet)))))))
      (net-insert-heading "IPv6")
      (net-insert-field "Modified EUI-64"
                        (mapconcat (lambda (octet) (format "%02x" octet))
                                   identifier ":"))
      (net-insert-link "Link-local address" 'ip (net-ip-format value 6)))))

(defun net-mac--display ()
  "Render the MAC address in the current buffer."
  (let* ((parsed (net-mac-parse net--value))
         (octets (plist-get parsed :octets))
         (first (car octets)))
    (net-set-summary (format "MAC %s, %s"
                             (net-mac-canonical parsed)
                             (if (= 1 (logand first #x01)) "multicast" "unicast")))
    (net-mac--insert-address-section parsed)
    (net-mac--insert-flags-section parsed)
    (net-mac--insert-vendor-section parsed)
    (net-mac--insert-eui64-section parsed)))

;;; Mode and entry points

(define-derived-mode net-mac-mode net-mode "Net MAC"
  "Major mode for inspecting one MAC address.
\\{net-mode-map}")

;;;###autoload
(defun net-mac-inspect (address)
  "Inspect the MAC ADDRESS in a `net-mac-mode' buffer."
  (interactive
   (list (or (when-let* ((bounds (bounds-of-thing-at-point 'net-mac)))
               (buffer-substring-no-properties (car bounds) (cdr bounds)))
             (read-string "MAC address: "))))
  (let ((parsed (net-mac-parse address)))
    (unless parsed
      (user-error "Not a MAC address: %s" address))
    (net-display 'mac (net-mac-canonical parsed)
                 #'net-mac-mode #'net-mac--display)))

(defun net-mac--sniff (string)
  "Return the canonical form of STRING when it is a MAC address."
  (when (and (stringp string)
             (or (string-match-p "[:-]" string)
                 (string-match-p "\\`[0-9A-Fa-f]\\{4\\}\\." string))
             (not (string-match-p "/" string)))
    (when-let* ((parsed (net-mac-parse string)))
      (net-mac-canonical parsed))))

(net-register-kind 'mac
                   '(:label "MAC"
                     :open net-mac-inspect
                     :sniff net-mac--sniff
                     :priority 55))

(put 'net-mac 'bounds-of-thing-at-point
     (lambda ()
       (net--thing-bounds "0-9A-Fa-f:.-" #'net-mac-parse)))
(put 'net-mac 'thing-at-point
     (lambda ()
       (when-let* ((bounds (bounds-of-thing-at-point 'net-mac)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(provide 'net-mac)
;;; net-mac.el ends here
