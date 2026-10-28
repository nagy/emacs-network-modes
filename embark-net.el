;;; embark-net.el --- Embark actions for network addresses  -*- lexical-binding: t; -*-

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

;; Embark integration.  When point is on any supported network address,
;; `embark-act' offers two actions:
;;
;;   RET  inspect the address in its major mode
;;   w    copy the address to the kill ring
;;
;; This module is opt-in:
;;
;;   (require 'embark-net)
;;   (embark-net-mode 1)

;;; Code:

(require 'net-mode)

(defvar embark-keymap-alist)
(defvar embark-target-finders)

(defun embark-net-target-at-point ()
  "Target a network address at point for Embark."
  (when-let* ((bounds (bounds-of-thing-at-point 'net-address))
              (value (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))
              ((net-sniff value)))
    `(net-address ,value ,(car bounds) . ,(cdr bounds))))

(defun embark-net-inspect (value)
  "Inspect the network address VALUE."
  (interactive "sNetwork address: ")
  (let ((kind (net-sniff value)))
    (unless kind
      (user-error "No network mode recognizes %s" value))
    (net-open (car kind) (cdr kind))))

(defun embark-net-copy (value)
  "Copy the network address VALUE to the kill ring."
  (interactive "sNetwork address: ")
  (kill-new value)
  (message "Copied: %s" value))

(defvar-keymap embark-net-map
  :doc "Keymap for Embark network address actions."
  :parent nil
  "RET" #'embark-net-inspect
  "w" #'embark-net-copy)

;; Global minor mode so the registration is explicit and reversible,
;; and so loading this file never touches Embark state on its own.
;;;###autoload
(define-minor-mode embark-net-mode
  "Register network address targets and actions with Embark."
  :global t
  :group 'net
  (if embark-net-mode
      (progn
        (unless (featurep 'embark)
          (setq embark-net-mode nil)
          (user-error "Load Embark before enabling embark-net-mode"))
        (add-hook 'embark-target-finders #'embark-net-target-at-point)
        (add-to-list 'embark-keymap-alist '(net-address . embark-net-map)))
    (remove-hook 'embark-target-finders #'embark-net-target-at-point)
    (setq embark-keymap-alist
          (assq-delete-all 'net-address embark-keymap-alist))))

(provide 'embark-net)
;;; embark-net.el ends here
