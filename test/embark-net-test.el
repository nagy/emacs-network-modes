;;; embark-net-test.el --- ERT tests for embark-net  -*- lexical-binding: t; -*-

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

;; ERT tests for the optional Embark targets.  Shared fixtures live in
;; `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)
(require 'embark-net)

;; The Embark targets and keymaps come from embark-net.el.  The byte
;; compiler reads neither file's definitions, so name them here.

(defvar embark-keymap-alist)

(defvar embark-target-finders)

(defvar embark-net-map)

(defvar embark-net-heading-map)

(ert-deftest net-embark-test-heading ()
  "The Embark heading target names the section of point."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (goto-char (point-min))
    (re-search-forward "^Classification")
    (let ((target (embark-net-target-heading)))
      (should (eq (car target) 'net-heading))
      (should (equal (cadr target) "Classification")))))

(ert-deftest net-embark-test-actions ()
  "The Embark keymaps reach the JSON view, RDAP and the fold."
  (should (eq (lookup-key embark-net-map (kbd "RET")) #'embark-net-inspect))
  (should (eq (lookup-key embark-net-map (kbd "J")) #'embark-net-json-view))
  (should (eq (lookup-key embark-net-map (kbd "b")) #'embark-net-rdap))
  (should (eq (lookup-key embark-net-heading-map (kbd "TAB"))
              #'embark-net-toggle-section)))

(ert-deftest net-embark-test-mode-registers ()
  "The minor mode registers the targets and the keymaps, and removes them."
  (skip-unless (require 'embark nil t))
  (unwind-protect
      (progn
        (embark-net-mode 1)
        (should (memq #'embark-net-target-heading embark-target-finders))
        (should (assq 'net-address embark-keymap-alist))
        (should (assq 'net-heading embark-keymap-alist)))
    (embark-net-mode -1)
    (should-not (memq #'embark-net-target-heading embark-target-finders))
    (should-not (assq 'net-heading embark-keymap-alist))))

(ert-deftest net-embark-test-target ()
  "The Embark target finder returns the kind and the bounds."
  (with-temp-buffer
    (insert "gw 192.0.2.1")
    (goto-char (point-max))
    (let ((target (embark-net-target-at-point)))
      (should (eq (car target) 'net-address))
      (should (equal (cadr target) "192.0.2.1")))))

(provide 'embark-net-test)
;;; embark-net-test.el ends here
