;;; network-modes-test-helper.el --- Shared fixtures for the ERT suite  -*- lexical-binding: t; -*-

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

;; Fixtures that more than one test file uses.  Every `*-test.el' file
;; loads this library, so a fixture lives here only when at least two
;; units share it.  The loader globs `*-test.el' and leaves this file
;; out, so it never runs as a test file.  The file name does not match
;; the glob on purpose.

;;; Code:

(require 'ert)
(require 'network-modes)

(defmacro net-test--with-file (content &rest body)
  "Write CONTENT to a temporary file, bind `net-test--file', run BODY."
  (declare (indent 1))
  `(let ((net-test--file (make-temp-file "net-test" nil ".dat")))
     (unwind-protect
         (progn
           (with-temp-file net-test--file
             (insert ,content))
           ,@body)
       (delete-file net-test--file))))

(defmacro net-test--with-binary-file (bytes &rest body)
  "Write the byte string BYTES to a temporary file, run BODY.
Bind `net-test--file' to the file name."
  (declare (indent 1))
  `(let ((net-test--file (make-temp-file "net-test" nil ".bin")))
     (unwind-protect
         (progn
           (let ((coding-system-for-write 'no-conversion))
             (with-temp-file net-test--file
               (set-buffer-multibyte nil)
               (insert ,bytes)))
           ,@body)
       (delete-file net-test--file))))

(defun net-test--packed-table (width numbers strings rows)
  "Return a packed range table as a unibyte string.
WIDTH, NUMBERS and STRINGS describe the row layout.  ROWS holds
lists of (START END NUMBERS TEXTS).  This mirrors
`tools/pack-network-data.el', so a reader change fails a test."
  (let* ((indexes (make-hash-table :test #'equal))
         (names nil)
         (row-size (+ (* 2 width) (* 4 numbers) (* 4 strings)))
         (count (length rows))
         (strings-offset (+ net--binary-header-size (* count row-size))))
    (dolist (row rows)
      (dolist (text (nth 3 row))
        (unless (gethash text indexes)
          (puthash text (length names) indexes)
          (setq names (append names (list text))))))
    (let* ((table (mapcar (lambda (text)
                            (let ((encoded (encode-coding-string text 'utf-8)))
                              (list (cons 'len (length encoded))
                                    (cons 'text encoded))))
                          names))
           (names-type (net--binary-names-type))
           (names-value (list (cons 'count (length table))
                              (cons 'names table)))
           (total (+ strings-offset
                     (bindat-length names-type names-value)))
           (raw (make-string total 0))
           (type (net--binary-row-type width numbers strings)))
      (bindat-pack net--binary-header-type
                   (list (cons 'magic net--binary-magic)
                         (cons 'version net--binary-version)
                         (cons 'width width)
                         (cons 'numbers numbers)
                         (cons 'strings strings)
                         (cons 'count count)
                         (cons 'strings-offset strings-offset))
                   raw 0)
      (let ((offset net--binary-header-size))
        (dolist (row rows)
          (bindat-pack type
                       (list (cons 'start (nth 0 row))
                             (cons 'end (nth 1 row))
                             (cons 'numbers (vconcat (nth 2 row)))
                             (cons 'strings
                                   (vconcat
                                    (mapcar (lambda (text)
                                              (gethash text indexes))
                                            (nth 3 row)))))
                       raw offset)
          (setq offset (+ offset row-size))))
      (bindat-pack names-type names-value raw strings-offset)
      raw)))

(defvar net-test--file nil
  "Temporary file used by the tests.")

(defun net-test--ip-number (address)
  "Return the integer of ADDRESS."
  (plist-get (net-ip-parse address) :value))

(defun net-test--section (type value)
  "Return the section of TYPE with VALUE, or nil."
  (let (found)
    (magit-map-sections
     (lambda (section)
       (when (and (eq (oref section type) type)
                  (equal (oref section value) value))
         (setq found section))))
    found))

(defun net-test--folded-p (title)
  "Return non-nil when the heading section TITLE is folded."
  (let ((section (net-test--section 'net-section title)))
    (should section)
    (oref section hidden)))

(provide 'network-modes-test-helper)
;;; network-modes-test-helper.el ends here
