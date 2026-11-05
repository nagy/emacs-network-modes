;;; pack-network-data.el --- Pack the range databases  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, network
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

;; Pack the GeoIP and origin AS range databases into the fixed-width
;; tables that `net--binary-table' reads.  The build runs it with the
;; command below; the same command works by hand:
;;
;;   Emacs --batch -L . -l tools/pack-network-data.el -- \
;;     --geo-v4 user-country-ipv4.csv \
;;     --geo-v6 user-country-ipv6.csv \
;;     --asn-v4 ip2asn-v4.tsv.gz \
;;     --asn-v6 ip2asn-v6.tsv.gz \
;;     --out-dir result
;;
;; The layout lives in `net--binary-header-type' and
;; `net--binary-row-type', so `bindat' reads and writes with one
;; description.  A raw upstream CSV or TSV file stays readable at run
;; time, which is why the readers keep a fallback.

;;; Code:

(require 'bindat)
(require 'cl-lib)
(require 'net-ip)

(defun net-pack--gzip-p (file)
  "Return non-nil when FILE starts with the gzip magic bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 2)
    (equal (buffer-string) (unibyte-string 31 139))))

(defun net-pack--text (file)
  "Return the text of FILE, decompressed when it is a gzip file."
  (with-temp-buffer
    (if (net-pack--gzip-p file)
        (progn
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (zlib-decompress-region (point-min) (point-max))
          (set-buffer-multibyte t))
      (insert-file-contents file))
    (buffer-string)))

(defun net-pack--geo (file)
  "Return the packed table data of the GeoIP CSV FILE.
The value is a plist with :count, :names and :value, where :value maps
a row index to (START END NUMBERS STRINGS)."
  (let ((table (make-hash-table :test #'equal))
        (names (make-vector 64 nil))
        (name-count 0)
        (count 0)
        (rows nil))
    (cl-labels ((intern-name (text)
                  (or (gethash text table)
                      (let ((index name-count))
                        (when (= name-count (length names))
                          (setq names (vconcat names
                                               (make-vector name-count nil))))
                        (aset names name-count text)
                        (puthash text name-count table)
                        (setq name-count (1+ name-count))
                        index))))
      (dolist (record (net--read-csv-file file))
        (unless (string-prefix-p "ip_range_start" (nth 0 record))
          (when (>= (length record) 3)
            (let ((start (net-ip-parse (nth 0 record)))
                  (end (net-ip-parse (nth 1 record))))
              (when (and start end)
                (push (plist-get start :value) rows)
                (push (plist-get end :value) rows)
                (push (intern-name (nth 2 record)) rows)
                (setq count (1+ count))))))))
    (let ((values (vconcat (nreverse rows))))
      (list :count count
            :names (cl-subseq names 0 name-count)
            :value (lambda (index)
                     (list (aref values (* 3 index))
                           (aref values (+ 1 (* 3 index)))
                           []
                           (vector (aref values (+ 2 (* 3 index))))))))))

(defun net-pack--asn (file)
  "Return the packed table data of the iptoasn TSV FILE.
The value is a plist with :count, :names and :value, where :value maps
a row index to (START END NUMBERS STRINGS)."
  (let ((table (make-hash-table :test #'equal))
        (names (make-vector 128 nil))
        (name-count 0)
        (count 0)
        (rows nil))
    (cl-labels ((intern-name (text)
                  (or (gethash text table)
                      (let ((index name-count))
                        (when (= name-count (length names))
                          (setq names (vconcat names
                                               (make-vector name-count nil))))
                        (aset names name-count text)
                        (puthash text name-count table)
                        (setq name-count (1+ name-count))
                        index))))
      (dolist (line (split-string (net-pack--text file) "\n"))
        (let ((fields (split-string line "\t")))
          (when (>= (length fields) 5)
            (let ((start (net-ip-parse (nth 0 fields)))
                  (end (net-ip-parse (nth 1 fields))))
              (when (and start end)
                (push (plist-get start :value) rows)
                (push (plist-get end :value) rows)
                (push (string-to-number (nth 2 fields)) rows)
                (push (intern-name (nth 3 fields)) rows)
                (push (intern-name (nth 4 fields)) rows)
                (setq count (1+ count))))))))
    (let ((values (vconcat (nreverse rows))))
      (list :count count
            :names (cl-subseq names 0 name-count)
            :value (lambda (index)
                     (list (aref values (* 5 index))
                           (aref values (+ 1 (* 5 index)))
                           (vector (aref values (+ 2 (* 5 index))))
                           (vector (aref values (+ 3 (* 5 index)))
                                   (aref values (+ 4 (* 5 index))))))))))

(defun net-pack--write (path width numbers strings data)
  "Write the packed range table PATH from DATA.
WIDTH is the address width in bytes, NUMBERS and STRINGS are the
column counts, and DATA comes from a reader such as `net-pack--geo'."
  (let* ((count (plist-get data :count))
         (value (plist-get data :value))
         (encoded (mapcar (lambda (text) (encode-coding-string text 'utf-8))
                          (append (plist-get data :names) nil)))
         (names (mapcar (lambda (text)
                          (list (cons 'len (length text))
                                (cons 'text text)))
                        encoded))
         (row-size (+ (* 2 width) (* 4 numbers) (* 4 strings)))
         (strings-offset (+ net--binary-header-size (* count row-size)))
         (names-size (+ 4 (cl-loop for text in encoded
                                   sum (+ 2 (length text)))))
         (total (+ strings-offset names-size))
         (raw (make-string total 0))
         (type (net--binary-row-type width numbers strings))
         (offset net--binary-header-size)
         (index 0))
    (bindat-pack net--binary-header-type
                 (list (cons 'magic net--binary-magic)
                       (cons 'version net--binary-version)
                       (cons 'width width)
                       (cons 'numbers numbers)
                       (cons 'strings strings)
                       (cons 'count count)
                       (cons 'strings-offset strings-offset))
                 raw 0)
    (while (< index count)
      (let ((row (funcall value index)))
        (bindat-pack type
                     (list (cons 'start (nth 0 row))
                           (cons 'end (nth 1 row))
                           (cons 'numbers (nth 2 row))
                           (cons 'strings (nth 3 row)))
                     raw offset))
      (setq offset (+ offset row-size))
      (setq index (1+ index)))
    (bindat-pack (net--binary-names-type)
                 (list (cons 'count (length names))
                       (cons 'names names))
                 raw strings-offset)
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-file path
        (set-buffer-multibyte nil)
        (insert raw)))
    (princ (format "%s: %d rows, %d strings, %d bytes\n"
                   (file-name-nondirectory path) count (length names)
                   total))))

(defun net-pack--options ()
  "Return the command line options as an alist."
  (let ((args command-line-args-left)
        (options nil))
    (setq command-line-args-left nil)
    ;; Emacs leaves the option separator in place.
    (when (equal (car args) "--") (pop args))
    (while args
      (let ((argument (pop args)))
        (unless (string-prefix-p "--" argument)
          (error "Unexpected argument: %s" argument))
        (push (cons (intern (substring argument 2)) (pop args)) options)))
    options))

(defun net-pack--option (name options)
  "Return the value of command line option NAME in OPTIONS."
  (or (cdr (assq name options))
      (error "Missing option --%s" name)))

(defun net-pack-main ()
  "Pack the range tables named on the command line."
  (let* ((options (net-pack--options))
         (out-dir (net-pack--option 'out-dir options))
         (specs '((geo-v4 "geo-ranges-v4.bin" 4 0 1 net-pack--geo)
                  (geo-v6 "geo-ranges-v6.bin" 16 0 1 net-pack--geo)
                  (asn-v4 "asn-ranges-v4.bin" 4 1 2 net-pack--asn)
                  (asn-v6 "asn-ranges-v6.bin" 16 1 2 net-pack--asn))))
    (make-directory out-dir t)
    (dolist (spec specs)
      (let* ((file (net-pack--option (nth 0 spec) options))
             (name (nth 1 spec))
             (width (nth 2 spec))
             (numbers (nth 3 spec))
             (strings (nth 4 spec))
             (reader (nth 5 spec)))
        (net-pack--write (expand-file-name name out-dir)
                         width numbers strings
                         (funcall reader file))))))

(net-pack-main)

(provide 'pack-network-data)
;;; pack-network-data.el ends here
