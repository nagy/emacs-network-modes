;;; net-vsock-test.el --- ERT tests for net-vsock  -*- lexical-binding: t; -*-

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

;; ERT tests for AF_VSOCK addresses.  Shared fixtures live in
;; `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-vsock-test-parse ()
  "Vsock parsing accepts CID:PORT with optional scheme."
  (should (= (plist-get (net-vsock-parse "2:22") :cid) 2))
  (should (= (plist-get (net-vsock-parse "vsock://2:22") :port) 22))
  (should (= (plist-get (net-vsock-parse "0xFFFFFFFF:0xFFFFFFFF") :cid) 4294967295))
  (should-not (net-vsock-parse "2"))
  (should-not (net-vsock-parse "2:65536:1"))
  (should-not (net-vsock-parse "2:abc")))

(ert-deftest net-vsock-test-buffer ()
  "The vsock buffer names reserved CIDs and shows the struct."
  (with-current-buffer (net-vsock-inspect "vsock://2:22")
    (should (string-match-p "VMADDR_CID_HOST" (buffer-string)))
    (should (string-match-p "svm_cid" (buffer-string)))
    (should (string-match-p "struct sockaddr" (buffer-string))))
  (with-current-buffer (net-vsock-inspect "0:0")
    (should (string-match-p "VMADDR_CID_HYPERVISOR" (buffer-string)))))

(ert-deftest net-vsock-test-services ()
  "The IANA service lookup reports matching ports."
  (net-test--with-file
      (concat "Service Name,Port Number,Transport Protocol,Description,"
              "Assignee,Contact,Registration Date,Modification Date,Reference\n"
              "ssh,22,tcp,The Secure Shell (SSH) Protocol,,,,,,\n"
              ",\"6000-6063\",tcp,Reserved,,,,,,\n")
    (let ((net-vsock-service-file net-test--file)
          (net-vsock--service-cache nil))
      (let ((rows (net-vsock--services 22)))
        (should (= (length rows) 1))
        (should (equal (plist-get (car rows) :name) "ssh")))
      (should (= (length (net-vsock--services 6001)) 1)))
    (let ((net-vsock-service-file nil)
          (net-vsock--service-cache nil))
      (should-not (net-vsock--services 22)))))

(provide 'net-vsock-test)
;;; net-vsock-test.el ends here
