;;; net-geo.el --- Country lookup for IP addresses  -*- lexical-binding: t; -*-

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

;; This file maps an IP address to its country code with a range file.
;; The expected format is three comma separated columns:
;;
;;   ip_range_start, ip_range_end, country_code
;;
;; The ranges can use dotted quads, colon separated IPv6 addresses or
;; plain integers.  The free PDDL files from the `ip-location-db'
;; project use dotted quads and IPv6 text, and they are sorted, which
;; lets `net-geo-country' binary search them after one parse.
;;
;; The Nix package pins the two country files and sets the two
;; options.  Users without Nix can download the files themselves:
;;
;;   https://github.com/sapics/ip-location-db
;;
;; The Nix derivation packs the range files into a fixed-width table
;; (`tools/pack-network-data.py'), so a lookup reads one file and
;; binary searches it.  A raw CSV file from ip-location-db works too:
;; the first lookup parses the whole file once and caches a flat vector
;; of start, end and country code.

;;; Code:

(require 'cl-lib)
(require 'net-mode)

(declare-function net-ip-parse "net-ip")

(defcustom net-geo-database-file (net-data-file "geo-ranges-v4.bin")
  "IPv4 range table for the GeoIP country lookup, or nil.
The Nix package ships a packed table.  A CSV file with start, end and
country code columns works too, and is read on first use."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defcustom net-geo-database-file-v6 (net-data-file "geo-ranges-v6.bin")
  "IPv6 range table for the GeoIP country lookup, or nil.
The Nix package ships a packed table.  A CSV file with start, end and
country code columns works too, and is read on first use."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defvar net-geo--cache nil
  "Alist of (FILE MTIME SIZE . DATA) for parsed range files.
DATA is a plist with :ranges and :count.")

(defun net-geo--file-key (file version)
  "Return the cache key of FILE for addresses of VERSION, or nil."
  (when (net-data-available-p file)
    (let ((attributes (file-attributes file)))
      (list file
            version
            (file-attribute-modification-time attributes)
            (file-attribute-size attributes)))))

(defun net-geo--to-number (string version)
  "Return the integer of address STRING of VERSION.
Plain decimal fields are accepted as well.  Load `net-ip' on demand,
because that file requires this one."
  (cond
   ((string-match-p "\\`[0-9]+\\'" string) (string-to-number string))
   (t
    (unless (fboundp 'net-ip-parse)
      (require 'net-ip nil t))
    (when-let* ((parsed (net-ip-parse string)))
      (when (= version (plist-get parsed :version))
        (plist-get parsed :value))))))

(defun net-geo--parse (file version)
  "Parse the range FILE for addresses of VERSION.
Return a plist with :ranges (a flat vector) and :count."
  (let ((ranges nil)
        (count 0))
    (dolist (record (net--read-csv-file file))
      (unless (string-prefix-p "ip_range_start" (nth 0 record))
        (when (>= (length record) 3)
          (let ((start (net-geo--to-number (nth 0 record) version))
                (end (net-geo--to-number (nth 1 record) version)))
            (when (and start end)
              (push start ranges)
              (push end ranges)
              (push (nth 2 record) ranges)
              (cl-incf count))))))
    (list :ranges (vconcat (nreverse ranges))
          :count count)))

(defun net-geo--table (file version)
  "Return the packed range table of FILE for VERSION, or nil."
  (when file
    (net--binary-table file (list :width (if (= version 4) 4 16)
                                  :numbers 0
                                  :strings 1))))

(defun net-geo--data (file version)
  "Return the parsed CSV range data of FILE for VERSION, or nil.
Parse the file on first use and reuse the result while the file does
not change.  Return nil when FILE is a packed table."
  (when (and (net-data-available-p file)
             (not (net--binary-available-p file)))
    (when-let* ((key (net-geo--file-key file version)))
      (let ((cached (assoc key net-geo--cache)))
        (if cached
            (cdr cached)
          (let ((data (net-geo--parse file version)))
            (setq net-geo--cache (cons (cons key data) net-geo--cache))
            data))))))

(defun net-geo--search (ranges address)
  "Return the country code of RANGES at ADDRESS."
  (declare (pure t) (side-effect-free t))
  (let ((low 0)
        (high (1- (/ (length ranges) 3)))
        result)
    (while (<= low high)
      (let* ((middle (/ (+ low high) 2))
             (start (aref ranges (* 3 middle))))
        (if (> start address)
            (setq high (1- middle))
          (setq low (1+ middle)))))
    (when (> low 0)
      (let ((index (1- low)))
        (when (<= address (aref ranges (1+ (* 3 index))))
          (setq result (aref ranges (+ 2 (* 3 index)))))))
    result))

;;;###autoload
(defun net-geo-country (value version)
  "Return the country code of the address VALUE of VERSION, or nil."
  (let ((file (if (= version 4)
                  net-geo-database-file
                net-geo-database-file-v6)))
    (when (net-data-available-p file)
      (if-let* ((table (net-geo--table file version)))
          (when-let* ((index (net--binary-find table value)))
            (net--binary-string table index 0))
        (when-let* ((data (net-geo--data file version)))
          (net-geo--search (plist-get data :ranges) value))))))

(defun net-geo-description (file version)
  "Return a one-line description of the range FILE of VERSION.
A file in the Nix store has an epoch modification time, so report it
as a pinned copy instead of a meaningless date."
  (let* ((attributes (file-attributes file))
         (time (file-attribute-modification-time attributes))
         (count (or (plist-get (net-geo--table file version) :count)
                    (plist-get (net-geo--data file version) :count)
                    "?"))
         (date (if (time-less-p time (encode-time 86400 0 0 1 1 1980))
                   "pinned copy"
                 (format-time-string "%Y-%m-%d" time))))
    (format "%s, %s ranges, %s" (file-name-nondirectory file) count date)))

(defun net-geo-clear-cache ()
  "Forget every parsed range file."
  (interactive)
  (setq net-geo--cache nil
        net--binary-cache nil))

(provide 'net-geo)
;;; net-geo.el ends here
