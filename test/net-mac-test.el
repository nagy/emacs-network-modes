;;; net-mac-test.el --- ERT tests for net-mac  -*- lexical-binding: t; -*-

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

;; ERT tests for MAC addresses and the IEEE vendor registries.  Shared
;; fixtures live in `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-mac-test-parse ()
  "MAC parsing accepts the common notations."
  (dolist (text '("aa:bb:cc:dd:ee:ff" "AA-BB-CC-DD-EE-FF" "aabb.ccdd.eeff"
                  "aabbccddeeff" "00:11:22:33:44:55:66:77"))
    (should (net-mac-parse text)))
  (should (equal (net-mac-canonical (net-mac-parse "AA-BB-CC-DD-EE-FF"))
                 "aa:bb:cc:dd:ee:ff"))
  (should-not (net-mac-parse "aa:bb:cc:dd:ee"))
  (should-not (net-mac-parse "gg:bb:cc:dd:ee:ff"))
  (should-not (net-mac-parse "aa:bb:cc:dd:ee:ff:")))

(ert-deftest net-mac-test-flags ()
  "The multicast and local bits are decoded."
  (with-current-buffer (net-mac-inspect "ff:ff:ff:ff:ff:ff")
    (should (string-match-p "multicast" (buffer-string)))
    (should (string-match-p "Broadcast" (buffer-string))))
  (with-current-buffer (net-mac-inspect "02:00:00:00:00:01")
    (should (string-match-p "locally administered" (buffer-string))))
  (with-current-buffer (net-mac-inspect "33:33:00:00:00:01")
    (should (string-match-p "IPv6 multicast" (buffer-string)))))

(ert-deftest net-mac-test-ieee ()
  "The IEEE registry lookup covers every assignment length."
  (let ((directory (make-temp-file "net-test-mac" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "oui.csv" directory)
            (insert "Registry,Assignment,Organization Name,Organization Address\n"
                    "MA-L,00000C,\"Cisco Systems, Inc\","
                    "\"170 West Tasman Drive San Jose CA US 95134\"\n"))
          (with-temp-file (expand-file-name "mam.csv" directory)
            (insert "Registry,Assignment,Organization Name,Organization Address\n"
                    "MA-M,1C8776D,Qivivo,\"1 rue de la Paix FR 75002\"\n"))
          (with-temp-file (expand-file-name "oui36.csv" directory)
            (insert "Registry,Assignment,Organization Name,Organization Address\n"
                    "MA-S,0050C2000,T.L.S. Corp.,\"Somewhere US\"\n"))
          (with-temp-file (expand-file-name "iab.csv" directory)
            (insert "Registry,Assignment,Organization Name,Organization Address\n"
                    "IAB,40D8550D0,Icraft Oy,\"Espoo FI\"\n"))
          (with-temp-file (expand-file-name "cid.csv" directory)
            (insert "Registry,Assignment,Organization Name,Organization Address\n"
                    "CID,8A34BC,Fiberworks AS,\"Oslo NO\"\n"))
          (let ((net-mac-registry-directory directory)
                (net-mac--registry-cache nil))
            (let ((vendor (net-mac-ieee-entry (net-mac-parse "00:00:0c:12:34:56"))))
              (should (equal (car vendor) "00000C"))
              (should (equal (plist-get (cdr vendor) :registry) "MA-L"))
              (should (equal (plist-get (cdr vendor) :name) "Cisco Systems, Inc"))
              (should (equal (plist-get (cdr vendor) :address)
                             "170 West Tasman Drive San Jose CA US 95134")))
            (let ((vendor (net-mac-ieee-entry (net-mac-parse "1c:87:76:d1:02:03"))))
              (should (equal (car vendor) "1C8776D"))
              (should (equal (plist-get (cdr vendor) :registry) "MA-M")))
            (let ((vendor (net-mac-ieee-entry (net-mac-parse "00:50:c2:00:01:02"))))
              (should (equal (car vendor) "0050C2000"))
              (should (equal (plist-get (cdr vendor) :registry) "MA-S")))
            (let ((vendor (net-mac-ieee-entry (net-mac-parse "40:d8:55:0d:01:02"))))
              (should (equal (car vendor) "40D8550D0"))
              (should (equal (plist-get (cdr vendor) :registry) "IAB")))
            (let ((vendor (net-mac-ieee-entry (net-mac-parse "8a:34:bc:12:34:56"))))
              (should (equal (car vendor) "8A34BC"))
              (should (equal (plist-get (cdr vendor) :registry) "CID")))
            (should-not (net-mac-ieee-entry (net-mac-parse "02:00:00:00:00:01")))
            (with-current-buffer (net-mac-inspect "00:00:0c:12:34:56")
              (should (string-match-p "Cisco Systems" (buffer-string)))
              (should (string-match-p "MA-L" (buffer-string)))
              (should (string-match-p "00:00:0C/24" (buffer-string)))
              (should (string-match-p "Organization address" (buffer-string))))))
      (delete-directory directory t))))

(ert-deftest net-mac-test-manuf ()
  "The manuf lookup honors exact and masked prefixes."
  (let ((file (make-temp-file "net-test-manuf")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# comment\n"
                    "AA:BB:CC\tShortName\tLong Vendor Name\n"
                    "1C:87:76:D0/28\tQivivo\tQivivo Ltd\n"
                    "00:50:C2:00:00/36\tTLS\tT.L.S. Corp.\n"))
          (let ((net-mac-manuf-file file)
                (net-mac--manuf-cache nil))
            (let ((entry (net-mac-manuf-entry (net-mac-parse "aa:bb:cc:01:02:03"))))
              (should (= (plist-get entry :mask) 24))
              (should (equal (plist-get entry :short) "ShortName"))
              (should (equal (plist-get entry :long) "Long Vendor Name")))
            (let ((entry (net-mac-manuf-entry (net-mac-parse "1c:87:76:d1:02:03"))))
              (should (= (plist-get entry :mask) 28))
              (should (equal (plist-get entry :short) "Qivivo")))
            (let ((entry (net-mac-manuf-entry (net-mac-parse "00:50:c2:00:01:02"))))
              (should (= (plist-get entry :mask) 36))
              (should (equal (plist-get entry :short) "TLS")))
            (should-not (net-mac-manuf-entry (net-mac-parse "02:00:00:00:00:01")))
            (with-current-buffer (net-mac-inspect "1c:87:76:d1:02:03")
              (should (string-match-p "Wireshark manuf" (buffer-string)))
              (should (string-match-p "Qivivo" (buffer-string))))))
      (delete-file file))))

(ert-deftest net-mac-test-eui64 ()
  "The IPv6 interface identifier flips the U/L bit."
  (with-current-buffer (net-mac-inspect "00:00:0c:12:34:56")
    (should (string-match-p "02:00:0c:ff:fe:12:34:56" (buffer-string)))
    (should (string-match-p "fe80::200:cff:fe12:3456" (buffer-string)))))

(provide 'net-mac-test)
;;; net-mac-test.el ends here
