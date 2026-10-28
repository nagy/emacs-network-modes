;;; net-xref.el --- Xref backend for network addresses  -*- lexical-binding: t; -*-

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

;; Xref backend for network addresses.  With point on any supported
;; address in any buffer, `xref-find-definitions' opens the buffer:
;;
;;   10.0.0.1          -> `net-ip-mode'
;;   10.0.0.0/8        -> `net-cidr-mode'
;;   aa:bb:cc:dd:ee:ff -> `net-mac-mode'
;;   AS13335           -> `net-asn-mode'
;;   example.com       -> `net-domain-mode'
;;   2:22              -> `net-vsock-mode'
;;
;; The backend only claims an identifier when `net-sniff' recognizes
;; it, so it does not interfere with other xref backends.
;;
;; This module is opt-in:
;;
;;   (require 'net-xref)

;;; Code:

(require 'net-mode)
(require 'xref)

(defun net-xref--identifier ()
  "Return the network address at point, or nil."
  (when-let* ((bounds (bounds-of-thing-at-point 'net-address))
              (value (buffer-substring-no-properties
                      (car bounds) (cdr bounds))))
    (when (net-sniff value)
      value)))

(defun net-xref-backend-function ()
  "Return the `net-xref' backend when point is on an address."
  (when (net-xref--identifier)
    'net-xref))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql net-xref)))
  "Return the network address at point."
  (net-xref--identifier))

(cl-defmethod xref-backend-definitions ((_backend (eql net-xref)) identifier)
  "Return the inspect buffer of IDENTIFIER as an xref.
The xref command does the window switch, so suppress the one inside
`net-open' and hand back the buffer location instead."
  (when-let* ((kind (net-sniff identifier)))
    (let ((buffer (save-selected-window (net-open (car kind) (cdr kind)))))
      (list (xref-make identifier
                       (xref-make-buffer-location buffer (point-min)))))))

(cl-defmethod xref-backend-identifier-completion-table
  ((_backend (eql net-xref)))
  "Return no completion candidates for network addresses."
  nil)

(add-hook 'xref-backend-functions #'net-xref-backend-function)

(provide 'net-xref)
;;; net-xref.el ends here
