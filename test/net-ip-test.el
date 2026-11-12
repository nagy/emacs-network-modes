;;; net-ip-test.el --- ERT tests for net-ip  -*- lexical-binding: t; -*-

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

;; ERT tests for IP addresses and the special-purpose registry.
;; Shared fixtures live in `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-ip-test-ipv4-parse ()
  "IPv4 parsing accepts dotted quads and rejects malformed input."
  (should (= (plist-get (net-ip-parse "10.0.0.1") :value) 167772161))
  (should (= (plist-get (net-ip-parse "0.0.0.0") :value) 0))
  (should (= (plist-get (net-ip-parse "255.255.255.255") :value) 4294967295))
  (should-not (net-ip-parse "256.0.0.1"))
  (should-not (net-ip-parse "1.2.3"))
  (should-not (net-ip-parse "01.2.3.4"))
  (should-not (net-ip-parse "1.2.3.4.5")))

(ert-deftest net-ip-test-ipv6-parse ()
  "IPv6 parsing handles compression, IPv4 tails and zones."
  (should (= (plist-get (net-ip-parse "::") :value) 0))
  (should (= (plist-get (net-ip-parse "::1") :value) 1))
  (should (= (plist-get (net-ip-parse "1::") :value) (ash 1 112)))
  (should (= (plist-get (net-ip-parse "::ffff:1.2.3.4") :value)
             (logior (ash #xffff 32) #x01020304)))
  (should (= (plist-get (net-ip-parse "2001:db8::1") :value)
             (logior (ash #x20010db8 96) 1)))
  (should-not (net-ip-parse "1:2:3:4:5:6:7"))
  (should-not (net-ip-parse "1:2:3:4:5:6:7:8:9"))
  (should-not (net-ip-parse "1:::2"))
  (should-not (net-ip-parse "12345::"))
  ;; A slash ends the zone, so a prefix does not parse as one address.
  (should-not (net-ip-parse "fe80::1%eth0/64"))
  (should (equal (plist-get (net-ip-parse "fe80::1%eth0") :zone) "eth0")))

(ert-deftest net-ip-test-ipv6-format ()
  "IPv6 formatting follows RFC 5952."
  (should (equal (net-ip-format 0 6) "::"))
  (should (equal (net-ip-format 1 6) "::1"))
  (should (equal (net-ip-format (ash 1 112) 6) "1::"))
  (should (equal (net-ip-format (logior (ash #x20010db8 96) 1) 6)
                 "2001:db8::1"))
  (should (equal (net-ip-format (logior (ash 1 112) 1) 6) "1::1"))
  (should (equal (net-ip-format (1- (ash 1 128)) 6)
                 "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")))

(ert-deftest net-ip-test-canonical-round-trip ()
  "A canonical string parses back to the same kind and value."
  (dolist (text '("0.0.0.0" "192.0.2.1" "255.255.255.255"
                  "::" "::1" "2001:db8::1" "fe80::1%eth0"
                  "::ffff:1.2.3.4" "AS13335" "AS1.10" "10.0.0.0/8"
                  "192.0.2.0/24" "0.0.0.0/0" "2001:db8::/32"
                  "aa:bb:cc:dd:ee:ff" "01:00:5e:00:00:01"))
    (let* ((first (net-sniff text))
           (canonical (cdr first))
           (again (net-sniff canonical)))
      (should first)
      (should (equal (car again) (car first)))
      (should (equal (cdr again) canonical)))))

(ert-deftest net-ip-test-ipv6-single-zero-group ()
  "A single zero group stays uncompressed."
  (should (equal (net-ip-format (logior (ash 1 112) (ash 1 96) (ash 1 64)) 6)
                 "1:1:0:1::")))

(ert-deftest net-ip-test-reverse-dns ()
  "Reverse DNS names for both address families."
  (should (equal (net-ip-reverse-dns 167772161 4) "1.0.0.10.in-addr.arpa"))
  (should (equal (net-ip-reverse-dns (plist-get (net-ip-parse "2001:db8::1") :value) 6)
                 "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")))

(ert-deftest net-ip-test-classification ()
  "Special-purpose blocks classify addresses."
  (should (equal (plist-get (car (net-ip-matching-blocks 167772161 4)) :name)
                 "Private-Use"))
  (should (equal (plist-get (car (net-ip-matching-blocks 3232235521 4)) :name)
                 "Private-Use"))
  (should (equal (plist-get (car (net-ip-matching-blocks 1 6)) :name)
                 "Loopback Address"))
  (should (equal (plist-get (car (net-ip-matching-blocks
                                  (plist-get (net-ip-parse "2001:db8::1") :value) 6))
                            :name)
                 "Documentation")))

(ert-deftest net-ip-test-private ()
  "The private predicate covers only RFC 1918 and RFC 4193 blocks."
  (should (net-ip-private-p 167772161 4))
  (should (net-ip-private-p (plist-get (net-ip-parse "172.20.0.1") :value) 4))
  (should (net-ip-private-p (plist-get (net-ip-parse "192.168.1.1") :value) 4))
  (should (net-ip-private-p (plist-get (net-ip-parse "fd00::1") :value) 6))
  (should-not (net-ip-private-p (plist-get (net-ip-parse "1.0.1.1") :value) 4))
  (should-not (net-ip-private-p (plist-get (net-ip-parse "100.64.0.1") :value) 4))
  (should-not (net-ip-private-p (plist-get (net-ip-parse "2001:db8::1") :value) 6))
  (should (net-ip-private-range-p 167772160 184549375 4))
  (should-not (net-ip-private-range-p 0 4294967295 4)))

(ert-deftest net-ip-test-buffer ()
  "The IP buffer lists embedded addresses of transition mechanisms."
  (with-current-buffer (net-ip-inspect "::ffff:192.0.2.1")
    (should (string-match-p "Embedded IPv4" (buffer-string)))
    (should (string-match-p "192.0.2.1" (buffer-string)))
    (should (equal net--rdap-type "ip"))))

(ert-deftest net-ip-test-registry ()
  "The IANA CSV supplies the classification when it exists."
  (net-test--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "3fff::/20,Documentation,[RFC 9637],2024-07,N/A,"
              "False,False,False,False,False\n")
    (let ((net-ip-registry-file-v6 net-test--file)
          (net-ip--registry-cache nil))
      (should (equal (plist-get
                      (car (net-ip-matching-blocks
                            (plist-get (net-ip-parse "3fff::1") :value) 6))
                      :name)
                     "Documentation")))))

(ert-deftest net-ip-test-multicast-survives-csv ()
  "The built-in multicast rows survive the IANA CSV."
  (net-test--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "10.0.0.0/8,Private-Use,[RFC 1918],1996-02,N/A,True,True,True,False,False\n")
    (let ((net-ip-registry-file net-test--file)
          (net-ip--registry-cache nil))
      (should (equal (plist-get
                      (car (net-ip-matching-blocks
                            (plist-get (net-ip-parse "224.0.0.1") :value) 4))
                      :name)
                     "Multicast")))))

(ert-deftest net-ip-test-range-prefix ()
  "Only an aligned single-prefix range becomes a prefix."
  (should (equal (net-ip--range-prefix (net-test--ip-number "1.1.1.0")
                                       (net-test--ip-number "1.1.1.255") 4)
                 "1.1.1.0/24"))
  (should (equal (net-ip--range-prefix 0 (1- (ash 1 32)) 4) "0.0.0.0/0"))
  (should (equal (net-ip--range-prefix 1 1 4) "0.0.0.1/32"))
  (should-not (net-ip--range-prefix (net-test--ip-number "1.1.1.0")
                                    (net-test--ip-number "1.1.2.0") 4)))

(provide 'net-ip-test)
;;; net-ip-test.el ends here
