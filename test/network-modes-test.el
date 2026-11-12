;;; network-modes-test.el --- ERT tests for the entry library  -*- lexical-binding: t; -*-

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

;; ERT tests for the entry library, which loads every mode.  Shared
;; fixtures live in `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-entry-test-library ()
  "The entry library loads every mode and provides its feature.
`use-package network-modes' and its `:ensure' form need the feature
to match the package name, and a bare require must register every
kind for `net-inspect'."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "network-modes.el"))
                  (buffer-string))))
    (should (string-match-p "^;;; network-modes\\.el --- " source))
    (should (string-match-p
             "^;; Package-Requires: ((emacs \"31\\.1\"))$" source))
    (dolist (feature (cons 'net-mode net--kind-features))
      (should (string-match-p
               (format "^(require '%s)$" (regexp-quote (symbol-name feature)))
               source)))
    (should (string-match-p "^(provide 'network-modes)$" source)))
  (should (featurep 'network-modes))
  (dolist (kind '(ip cidr mac asn domain vsock))
    (should (net-kind-property kind :open))))

(provide 'network-modes-test)
;;; network-modes-test.el ends here
