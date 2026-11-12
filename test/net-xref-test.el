;;; net-xref-test.el --- ERT tests for net-xref  -*- lexical-binding: t; -*-

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

;; ERT tests for the optional xref backend.  Shared fixtures live in
;; `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)
(require 'net-xref)

(ert-deftest net-xref-test-backend ()
  "The xref backend claims net addresses only."
  (with-temp-buffer
    (insert "10.0.0.1")
    (goto-char (point-min))
    (should (eq (net-xref-backend-function) 'net-xref)))
  (with-temp-buffer
    (insert "nothing here")
    (goto-char (point-min))
    (should-not (net-xref-backend-function))))

(provide 'net-xref-test)
;;; net-xref-test.el ends here
