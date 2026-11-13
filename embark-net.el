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
;; When point is on a database row of an inspect buffer, `embark-act'
;; offers the file actions, so `RET' opens the database file and `d'
;; lists its directory.  The row prints a short name only, so the
;; target reads the path from the `net-file' text property.
;;
;; When point is on a section heading, `TAB' folds or unfolds that
;; section, the same key that the buffer itself gives it.
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

(defun embark-net-target-database-file ()
  "Target the database file of the row at point for Embark."
  (when-let* ((file (get-text-property (point) 'net-file)))
    (let* ((end (next-single-property-change (point) 'net-file
                                             nil (point-max)))
           (beg (or (previous-single-property-change end 'net-file
                                                     nil (point-min))
                    (point-min))))
      `(file ,(abbreviate-file-name file) ,beg . ,end))))

(defun embark-net--inspect (value)
  "Return the inspect buffer of the network address VALUE."
  (let ((kind (net-sniff value)))
    (unless kind
      (user-error "No network mode recognizes %s" value))
    (net-open (car kind) (cdr kind))))

(defun embark-net-inspect (value)
  "Inspect the network address VALUE."
  (interactive "sNetwork address: ")
  (embark-net--inspect value))

(defun embark-net-copy (value)
  "Copy the network address VALUE to the kill ring."
  (interactive "sNetwork address: ")
  (kill-new value)
  (message "Copied: %s" value))

(defun embark-net-json-view (value)
  "Inspect the network address VALUE and show its JSON report."
  (interactive "sNetwork address: ")
  (with-current-buffer (embark-net--inspect value)
    (net-json-view)))

(defun embark-net-rdap (value)
  "Inspect the network address VALUE and fetch its RDAP data.
The command never runs by itself, so a buffer stays offline until the
reader acts on it."
  (interactive "sNetwork address: ")
  (with-current-buffer (embark-net--inspect value)
    (net-rdap)))

(defun embark-net-target-heading ()
  "Target the section heading of an inspect buffer at point for Embark."
  (when-let* ((title (get-text-property (line-beginning-position)
                                        'net-heading)))
    `(net-heading ,title ,(line-beginning-position)
                  . ,(line-end-position))))

(defun embark-net-toggle-section (title)
  "Fold or unfold the section titled TITLE."
  (interactive "sSection: ")
  (let ((section (net--section-by-heading title)))
    (unless section
      (user-error "No section titled %s" title))
    (net-toggle-section section)))

(defvar-keymap embark-net-map
  :doc "Keymap for Embark network address actions."
  :parent nil
  "RET" #'embark-net-inspect
  "w" #'embark-net-copy
  "J" #'embark-net-json-view
  "b" #'embark-net-rdap)

(defvar-keymap embark-net-heading-map
  :doc "Keymap for Embark section actions on an inspect buffer."
  :parent nil
  "TAB" #'embark-net-toggle-section)

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
        (add-hook 'embark-target-finders
                  #'embark-net-target-database-file)
        (add-hook 'embark-target-finders #'embark-net-target-heading)
        (add-to-list 'embark-keymap-alist '(net-address . embark-net-map))
        (add-to-list 'embark-keymap-alist
                     '(net-heading . embark-net-heading-map)))
    (remove-hook 'embark-target-finders #'embark-net-target-at-point)
    (remove-hook 'embark-target-finders #'embark-net-target-database-file)
    (remove-hook 'embark-target-finders #'embark-net-target-heading)
    (setq embark-keymap-alist
          (assq-delete-all 'net-heading
                           (assq-delete-all 'net-address
                                            embark-keymap-alist)))))

(provide 'embark-net)
;;; embark-net.el ends here
