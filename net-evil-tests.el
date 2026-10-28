;;; net-evil-tests.el --- ERT tests for net-evil  -*- lexical-binding: t; -*-

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
;;
;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ERT tests for the optional evil bindings.  The evil library stays
;; optional, so every test skips itself when evil is absent.

;;; Code:

(require 'ert)
(require 'net-ip)
(require 'net-mode)

(declare-function evil-local-mode "evil" (&optional arg))
(declare-function evil-normal-state "evil" nil)
(declare-function evil-visual-line "evil" (&optional count))
(declare-function evil-next-line "evil" (&optional count))
(declare-function evil-previous-line "evil" (&optional count))
(declare-function evil-goto-first-line "evil" (&optional count))
(declare-function evil-goto-line "evil" (&optional count))
(declare-function evil-scroll-down "evil" (&optional count))
(declare-function evil-search-forward "evil" (string &optional count))
(declare-function evil-search-next "evil" (&optional count))
(declare-function evil-search-previous "evil" (&optional count))
(declare-function evil-forward-word-begin "evil" (&optional count))
(declare-function net-evil-mode "net-evil" (&optional arg))
(declare-function net-evil-local-mode "net-evil" (&optional arg))
(defvar net-evil-keys)
(defvar net-evil-visual-keys)

;;; Helpers

(defun net-evil-test--normal ()
  "Enable evil in the current buffer and enter normal state."
  (evil-local-mode 1)
  (evil-normal-state))

;;; Bindings

(ert-deftest net-evil-normal-keys ()
  "Normal state runs the inspect commands of `net-mode-map'."
  (skip-unless (require 'evil nil t))
  (require 'net-evil)
  (with-temp-buffer
    (net-ip-mode)
    (net-evil-local-mode 1)
    (net-evil-test--normal)
    (dolist (binding net-evil-keys)
      (should (eq (key-binding (key-parse (car binding)))
                  (cdr binding))))))

(ert-deftest net-evil-keeps-motions ()
  "The evil motions survive the bindings of the local minor mode."
  (skip-unless (require 'evil nil t))
  (require 'net-evil)
  (with-temp-buffer
    (net-ip-mode)
    (net-evil-local-mode 1)
    (net-evil-test--normal)
    (should (eq (key-binding (kbd "j")) #'evil-next-line))
    (should (eq (key-binding (kbd "k")) #'evil-previous-line))
    (should (eq (key-binding (kbd "gg")) #'evil-goto-first-line))
    (should (eq (key-binding (kbd "G")) #'evil-goto-line))
    (should (eq (key-binding (kbd "C-d")) #'evil-scroll-down))
    (should (eq (key-binding (kbd "/")) #'evil-search-forward))
    (should (eq (key-binding (kbd "n")) #'evil-search-next))
    (should (eq (key-binding (kbd "N")) #'evil-search-previous))))

(ert-deftest net-evil-visual-keys ()
  "Visual state follows the button at point with RET."
  (skip-unless (require 'evil nil t))
  (require 'net-evil)
  (with-temp-buffer
    (net-ip-mode)
    (net-evil-local-mode 1)
    (evil-local-mode 1)
    (evil-visual-line)
    (dolist (binding net-evil-visual-keys)
      (should (eq (key-binding (key-parse (car binding)))
                  (cdr binding))))))

(ert-deftest net-evil-ret-copies-a-field ()
  "RET on a field button copies its value."
  (skip-unless (require 'evil nil t))
  (require 'net-evil)
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil))
    (net-evil-mode 1)
    (unwind-protect
        (with-current-buffer (net-ip-inspect "192.0.2.1")
          (net-evil-test--normal)
          (goto-char (point-min))
          (forward-button 1)
          (call-interactively (key-binding (kbd "RET")))
          (should (equal (car kill-ring) "192.0.2.1")))
      (net-evil-mode -1))))

;;; Global mode

(ert-deftest net-evil-mode-enables-net-buffers ()
  "The global mode turns on the local mode, and only there."
  (skip-unless (require 'evil nil t))
  (require 'net-evil)
  (unwind-protect
      (progn
        (net-evil-mode 1)
        (with-temp-buffer
          (net-ip-mode)
          (should (bound-and-true-p net-evil-local-mode)))
        (with-temp-buffer
          (fundamental-mode)
          (should-not (bound-and-true-p net-evil-local-mode))))
    (net-evil-mode -1)))

(ert-deftest net-evil-mode-disables-local-mode ()
  "Turning the global mode off gives the buffer back to `net-mode-map'."
  (skip-unless (require 'evil nil t))
  (require 'net-evil)
  (net-evil-mode 1)
  (unwind-protect
      (with-temp-buffer
        (net-ip-mode)
        (net-evil-test--normal)
        (should (bound-and-true-p net-evil-local-mode))
        (net-evil-mode -1)
        (should-not (bound-and-true-p net-evil-local-mode))
        (should (eq (key-binding (kbd "w")) #'evil-forward-word-begin)))
    (net-evil-mode -1)))

(ert-deftest net-evil-mode-covers-existing-buffers ()
  "Turning the global mode on reaches buffers that already exist."
  (skip-unless (require 'evil nil t))
  (require 'net-evil)
  (let ((buffer (get-buffer-create "*net-evil-test-existing*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (net-ip-mode)
            (should-not (bound-and-true-p net-evil-local-mode)))
          (net-evil-mode 1)
          (with-current-buffer buffer
            (should (bound-and-true-p net-evil-local-mode))))
      (net-evil-mode -1)
      (kill-buffer buffer))))

;;; Autoloads

(ert-deftest net-evil-autoloads ()
  "The global mode carries an autoload cookie.
A fresh install reaches `net-evil-mode' without a `require'."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "net-evil.el"))
                  (buffer-string))))
    (should (string-match-p
             "^;;;###autoload\n(define-minor-mode net-evil-mode\\b"
             source))))

(provide 'net-evil-tests)
;;; net-evil-tests.el ends here
