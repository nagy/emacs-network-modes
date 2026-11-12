;;; net-cidr-test.el --- ERT tests for net-cidr  -*- lexical-binding: t; -*-

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

;; ERT tests for CIDR prefixes.  Shared fixtures live in
;; `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-cidr-test-parse ()
  "CIDR parsing computes network and last addresses."
  (let ((parsed (net-cidr-parse "10.0.0.0/8")))
    (should (= (plist-get parsed :network) 167772160))
    (should (= (plist-get parsed :last) 184549375)))
  (let ((parsed (net-cidr-parse "192.0.2.130/25")))
    (should (equal (net-cidr-canonical parsed) "192.0.2.128/25"))
    (should (= (plist-get parsed :last) 3221226239)))
  (should (equal (net-cidr-canonical (net-cidr-parse "0.0.0.0/0")) "0.0.0.0/0"))
  (should (equal (net-cidr-canonical (net-cidr-parse "::/0")) "::/0"))
  (should-not (net-cidr-parse "10.0.0.0/33"))
  (should-not (net-cidr-parse "2001:db8::/129"))
  (should-not (net-cidr-parse "10.0.0.0")))

(ert-deftest net-cidr-test-reverse-zone ()
  "Reverse zones appear only for aligned prefixes."
  (should (equal (net-cidr-reverse-zone 167772160 8 4) "10.in-addr.arpa"))
  (should (equal (net-cidr-reverse-zone 167772160 16 4) "0.10.in-addr.arpa"))
  (should-not (net-cidr-reverse-zone 167772160 12 4))
  (should (equal (net-cidr-reverse-zone (plist-get (net-ip-parse "2001:db8::") :value)
                                        32 6)
                 "8.b.d.0.1.0.0.2.ip6.arpa")))

(ert-deftest net-cidr-test-host-counts ()
  "Usable host counts follow IPv4 conventions."
  (with-current-buffer (net-cidr-inspect "192.0.2.0/31")
    (should (string-match-p "Usable hosts" (buffer-string)))
    (should (string-match-p "\\_<2\\_>" (buffer-string))))
  (with-current-buffer (net-cidr-inspect "192.0.2.0/32")
    (should (string-match-p "\\_<1\\_>" (buffer-string)))))

(ert-deftest net-cidr-test-registry-csv ()
  "The IANA registry CSV narrows the classification."
  (net-test--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,Reserved-by-Protocol\n"
              "192.0.2.0/24,Documentation,[RFC 5737],2010-01,N/A,"
              "True,False,False,False,False\n")
    (let ((net-cidr-registry-file net-test--file)
          (net-ip--registry-cache nil))
      (let ((matches (net-cidr-matching-entries (net-cidr-parse "192.0.2.128/25"))))
        (should (= (length matches) 1))
        (should (equal (plist-get (car matches) :name) "Documentation"))
        (should (equal (plist-get (car matches) :source) "True"))
        (should (equal (plist-get (car matches) :global) "False"))))))

(ert-deftest net-cidr-test-registry-annotations ()
  "Registry rows with footnotes and several blocks still classify."
  (net-test--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "192.0.0.0/24 [2],IETF Protocol Assignments,[RFC 6890],"
              "2010-01,N/A,False,False,False,False,False\n"
              "\"192.0.0.170/32, 192.0.0.171/32\",NAT64/DNS64 Discovery,"
              "[RFC 8880],2013-02,N/A,False,False,False,False,True\n")
    (let ((net-ip-registry-file net-test--file)
          (net-ip--registry-cache nil))
      (should (equal (plist-get
                      (car (net-ip-matching-blocks
                            (plist-get (net-ip-parse "192.0.0.1") :value) 4))
                      :name)
                     "IETF Protocol Assignments"))
      (dolist (address '("192.0.0.170" "192.0.0.171"))
        (should (equal (plist-get
                        (car (net-ip-matching-blocks
                              (plist-get (net-ip-parse address) :value) 4))
                        :name)
                       "NAT64/DNS64 Discovery")))
      (let ((parsed (net-cidr-parse "192.0.0.0/24")))
        (should (equal (plist-get (car (net-cidr-matching-entries parsed))
                                  :name)
                       "IETF Protocol Assignments"))))))

(ert-deftest net-cidr-test-label-gap ()
  "A long block name keeps a space before its value."
  (let ((net-ip-registry-file nil)
        (net-ip-registry-file-v6 nil))
    (with-current-buffer (net-cidr-inspect "192.0.0.8/32")
      (should (string-match-p "IETF Protocol Assignments 192\\.0\\.0\\.0/24"
                              (buffer-string))))))

(ert-deftest net-cidr-test-buffer-private ()
  "The CIDR buffer reports private ranges without a registry file."
  (let ((net-cidr-registry-file nil)
        (net-cidr-registry-file-v6 nil))
    (with-current-buffer (net-cidr-inspect "172.16.0.0/12")
      (should (string-match-p "Private-Use" (buffer-string)))
      (should (string-match-p "RFC 1918" (buffer-string)))
      (should (string-match-p "built-in table" (buffer-string))))))

(provide 'net-cidr-test)
;;; net-cidr-test.el ends here
