;;; ol-net.el --- Org links to network addresses  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, network, org
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

;; Org link types for network addresses:
;;
;;   [[net-ip:192.0.2.1]]
;;   [[net-cidr:10.0.0.0/8][office network]]
;;   [[net-mac:00:00:0c:12:34:56]]
;;   [[net-asn:AS13335]]
;;   [[net-domain:example.com]]
;;   [[net-vsock:2:22]]
;;
;; A plain `net:' link runs the dispatcher, so the same link type can
;; hold any of the above:
;;
;;   [[net:2001:db8::1]]
;;
;; This module is opt-in:
;;
;;   (with-eval-after-load 'org (require 'ol-net))

;;; Code:

(require 'net-mode)
(require 'ol)

(defconst ol-net-kinds
  '(("net-ip" . ip)
    ("net-cidr" . cidr)
    ("net-mac" . mac)
    ("net-asn" . asn)
    ("net-domain" . domain)
    ("net-vsock" . vsock))
  "Org link types and the network address kinds they hold.")

(defun ol-net--store-link (_interactive-p)
  "Store a network link for the current inspect buffer."
  (when (derived-mode-p 'net-mode)
    (org-link-store-props
     :type (format "net-%s" net--kind)
     :link (format "net-%s:%s" net--kind net--value)
     :description (format "%s" net--value))
    t))

(defun ol-net--export (path description _backend &optional _info)
  "Export a network link as plain text.
PATH is the address, DESCRIPTION is the link text."
  (or description path))

(defun ol-net--configure (type kind)
  "Register the Org link TYPE for addresses of KIND.
KIND is nil for the dispatcher link, which sniffs the path."
  (org-link-set-parameters
   type
   :follow (lambda (path &optional _prefix)
             (if kind
                 (net-open kind path)
               (net-inspect path)))
   :complete (lambda (&optional _)
               (format "%s:%s" type (read-string "Network address: ")))
   :store #'ol-net--store-link
   :export #'ol-net--export))

(ol-net--configure "net" nil)
(dolist (pair ol-net-kinds)
  (let ((type (car pair))
        (kind (cdr pair)))
    (ol-net--configure type kind)))

(provide 'ol-net)
;;; ol-net.el ends here
