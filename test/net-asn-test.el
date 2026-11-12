;;; net-asn-test.el --- ERT tests for net-asn  -*- lexical-binding: t; -*-

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

;; ERT tests for AS numbers and the IP to AS range tables.  Shared
;; fixtures live in `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-asn-test-parse ()
  "AS number parsing handles asplain, AS notation and asdot."
  (should (= (plist-get (net-asn-parse "13335") :asn) 13335))
  (should (= (plist-get (net-asn-parse "AS13335") :asn) 13335))
  (should (= (plist-get (net-asn-parse "as13335") :asn) 13335))
  (should (= (plist-get (net-asn-parse "1.10") :asn) 65546))
  (should (= (plist-get (net-asn-parse "AS1.10") :asn) 65546))
  (should (= (plist-get (net-asn-parse "AS13335") :asn) 13335))
  (should (= (plist-get (net-asn-parse "4294967295") :asn) 4294967295))
  (should-not (net-asn-parse "4294967296"))
  (should-not (net-asn-parse "65536.1")))

(ert-deftest net-asn-test-asdot ()
  "ASDOT rendering starts above 16 bits."
  (should-not (net-asn-asdot 13335))
  (should (equal (net-asn-asdot 65546) "1.10"))
  (should (equal (net-asn-asdot 4200000000) "64086.59904")))

(ert-deftest net-asn-test-classification ()
  "Reservation classes cover the usual ranges."
  (should (equal (car (net-asn-classification 0)) "Reserved"))
  (should (equal (car (net-asn-classification 64512)) "Private-Use"))
  (should (equal (car (net-asn-classification 65534)) "Private-Use"))
  (should (equal (car (net-asn-classification 64496)) "Documentation"))
  (should (equal (car (net-asn-classification 23456))
                 "AS_TRANS (4-byte AS transition)"))
  (should (equal (car (net-asn-classification 4200000001)) "Private-Use"))
  (should (equal (car (net-asn-classification 13335)) "Assigned")))

(ert-deftest net-asn-test-registry ()
  "The IANA registry CSV gives the block of an AS number."
  (net-test--with-file
      (concat "Number,Description,WHOIS,RDAP,Reference,Registration Date\n"
              "1-1876,Assigned by ARIN,whois.arin.net,,,\n"
              "64512-65534,Private Use,,,[RFC 6996],\n")
    (let ((net-asn-registry-file net-test--file)
          (net-asn--registry-cache nil))
      (let ((row (net-asn-registry-row 1000)))
        (should (equal (plist-get row :description) "Assigned by ARIN")))
      (should (equal (plist-get (net-asn-registry-row 65000) :description)
                     "Private Use"))
      (should-not (net-asn-registry-row 5000)))))

(ert-deftest net-asn-test-metadata-pretty ()
  "The metadata lookup finds one object in a pretty printed file."
  (net-test--with-file
      (concat "[{\n"
              "    \"asn\": 1,\n"
              "    \"metadata\": {\"handle\": \"LVLT-1\", \"description\": \"Level 3\"},\n"
              "    \"stats\": null,\n"
              "    \"lastAnnounced\": \"2026-01-01\"\n"
              "  },{\n"
              "    \"asn\": 13335,\n"
              "    \"metadata\": {\"handle\": \"CLOUDFLARENET\", \"description\": \"Cloudflare\"},\n"
              "    \"stats\": {\"ipv4\": {\"prefixes\": 10}},\n"
              "    \"lastAnnounced\": \"2026-02-02\"\n"
              "  }]")
    (let ((net-asn-database-file net-test--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (let ((entry (net-asn-entry 13335)))
        (should (equal (alist-get 'handle (alist-get 'metadata entry))
                       "CLOUDFLARENET")))
      (should-not (net-asn-entry 99999)))))

(ert-deftest net-asn-test-metadata-minified ()
  "The metadata lookup finds one object in a minified file."
  (net-test--with-file
      "[{\"asn\":1,\"metadata\":{\"handle\":\"A\"}},{\"asn\":13335,\"metadata\":{\"handle\":\"CLOUDFLARENET\"}}]"
    (let ((net-asn-database-file net-test--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (should (equal (alist-get 'handle
                                (alist-get 'metadata (net-asn-entry 13335)))
                     "CLOUDFLARENET")))))

(ert-deftest net-asn-test-buffer ()
  "The ASN buffer shows identity and RDAP identity."
  (let ((net-asn-database-file nil)
        (net-asn-registry-file nil)
        (net-asn-registry-file-v2 nil))
    (with-current-buffer (net-asn-inspect "AS64512")
      (should (string-match-p "Private-Use" (buffer-string)))
      (should (string-match-p "RFC 6996" (buffer-string)))
      (should (equal net--rdap-type "autnum"))
      (should (equal net--rdap-key "64512")))))

(ert-deftest net-asn-test-metadata-key-order ()
  "A file that does not put \"asn\" first still resolves through the table."
  (net-test--with-file
      (concat "[{\"metadata\":{\"handle\":\"LATE\"},\"asn\":13335},"
              "{\"metadata\":{\"handle\":\"C\"},\"asn\":174}]")
    (let ((net-asn-database-file net-test--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (should (equal (alist-get 'handle
                                (alist-get 'metadata (net-asn-entry 13335)))
                     "LATE")))))

(ert-deftest net-asn-test-provider-links ()
  "The provider list renders as one wrapping label line."
  (net-test--with-file
      (concat "[{\"asn\":1,\"metadata\":{\"handle\":\"A\"},"
              "\"stats\":{\"connectivity\":{\"providers\":2,"
              "\"providerAsns\":[174,3356]}}}]")
    (let ((net-asn-database-file net-test--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (with-current-buffer (net-asn-inspect "AS1")
        (should (string-match-p "Upstream Providers\\s-+AS174, AS3356"
                                (buffer-string)))))))

(defconst net-test--ip2asn
  (concat "1.0.0.0\t1.0.0.255\t13335\tUS\tCLOUDFLARENET\n"
          "1.0.1.0\t1.0.3.255\t0\tNone\tNot routed\n"
          "192.0.2.0\t192.0.2.255\t64500\tUS\tEXAMPLE-NET\n")
  "Small range table in the iptoasn format.")

(ert-deftest net-asn-test-ip-entry ()
  "The origin AS lookup binary searches a sorted range table."
  (net-test--with-file net-test--ip2asn
    (let ((net-asn-ip-database-file net-test--file))
      (let ((entry (net-asn-ip-entry (net-test--ip-number "1.0.0.5") 4)))
        (should (= (plist-get entry :asn) 13335))
        (should (equal (plist-get entry :country) "US"))
        (should (equal (plist-get entry :description) "CLOUDFLARENET"))
        (should (= (plist-get entry :start) (net-test--ip-number "1.0.0.0")))
        (should (= (plist-get entry :end) (net-test--ip-number "1.0.0.255"))))
      (should (= (plist-get (net-asn-ip-entry
                             (net-test--ip-number "1.0.3.255") 4)
                            :asn)
                 0))
      (should-not (net-asn-ip-entry (net-test--ip-number "1.0.4.0") 4))
      (should-not (net-asn-ip-entry (net-test--ip-number "0.0.0.1") 4)))))

(ert-deftest net-asn-test-ip-entry-gzip ()
  "The lookup gunzips a file by its magic bytes."
  (let ((plain (make-temp-file "net-test" nil ".tsv"))
        (file (make-temp-file "net-test" nil ".tsv.gz")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert net-test--ip2asn)
            (write-region (point-min) (point-max) plain nil 'silent))
          (unless (executable-find "gzip")
            (ert-skip "gzip is missing"))
          (let ((data (with-temp-buffer
                        (set-buffer-multibyte nil)
                        (should (zerop (call-process "gzip" nil t nil
                                                     "-c" plain)))
                        (buffer-string))))
            (let ((coding-system-for-write 'no-conversion))
              (with-temp-file file
                (set-buffer-multibyte nil)
                (insert data))))
          (should (net-asn--gzip-file-p file))
          (let ((net-asn-ip-database-file file)
                (net-asn--range-cache nil))
            (should (= (plist-get (net-asn-ip-entry
                                   (net-test--ip-number "192.0.2.7") 4)
                                  :asn)
                       64500))))
      (delete-file plain)
      (delete-file file))))

(ert-deftest net-asn-test-ip-entry-gzip-suffix ()
  "A gzip suffix alone does not trigger decompression."
  (let ((file (make-temp-file "net-test" nil ".tsv.gz")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert net-test--ip2asn)
            (write-region (point-min) (point-max) file nil 'silent))
          (should (string-suffix-p ".gz" file))
          (let ((net-asn-ip-database-file file)
                (net-asn--range-cache nil))
            (should (= (plist-get (net-asn-ip-entry
                                   (net-test--ip-number "192.0.2.7") 4)
                                  :asn)
                       64500))))
      (delete-file file))))

(ert-deftest net-asn-test-ip-entry-binary ()
  "A packed range table answers the origin AS lookup."
  (net-test--with-binary-file
      (net-test--packed-table
       4 1 2
       '((16777216 16777471 (13335) ("US" "CLOUDFLARENET"))
         (16777472 16777727 (0) ("None" "Not routed"))))
    (let ((net-asn-ip-database-file net-test--file)
          (net--binary-cache nil))
      (let ((entry (net-asn-ip-entry (net-test--ip-number "1.0.0.9") 4)))
        (should (= (plist-get entry :asn) 13335))
        (should (equal (plist-get entry :country) "US"))
        (should (equal (plist-get entry :description) "CLOUDFLARENET"))
        (should (= (plist-get entry :start) 16777216)))
      (should (= (plist-get (net-asn-ip-entry
                             (net-test--ip-number "1.0.1.9") 4)
                            :asn)
                 0))
      (should-not (net-asn-ip-entry (net-test--ip-number "1.0.2.1") 4)))))

(ert-deftest net-asn-test-ip-range-cache ()
  "The decompressed fallback table is reused across lookups."
  (net-test--with-file net-test--ip2asn
    (let ((net-asn-ip-database-file net-test--file)
          (net-asn--range-cache nil))
      (should (= (plist-get (net-asn-ip-entry
                             (net-test--ip-number "1.0.0.5") 4)
                            :asn)
                 13335))
      (let ((text (cdr net-asn--range-cache)))
        (should text)
        (should (= (plist-get (net-asn-ip-entry
                               (net-test--ip-number "192.0.2.7") 4)
                              :asn)
                   64500))
        (should (eq (cdr net-asn--range-cache) text))))))

(ert-deftest net-asn-test-ip-entry-missing ()
  "A missing range file reports no entry."
  (let ((net-asn-ip-database-file nil))
    (should-not (net-asn-ip-entry (net-test--ip-number "1.0.0.1") 4))))

(ert-deftest net-asn-test-ip-buffer-asn ()
  "The IP buffer names the origin AS and the covering prefix."
  (net-test--with-file net-test--ip2asn
    (let ((net-asn-ip-database-file net-test--file)
          (net-geo-database-file nil)
          (net-geo-database-file-v6 nil))
      (with-current-buffer (net-ip-inspect "1.0.0.5")
        (should (string-match-p "Autonomous System" (buffer-string)))
        (should (string-match-p "\\bAS13335\\b" (buffer-string)))
        (should (string-match-p "1\\.0\\.0\\.0/24" (buffer-string))))
      (with-current-buffer (net-ip-inspect "1.0.2.1")
        (should (string-match-p "0 (not routed)" (buffer-string)))))))

(provide 'net-asn-test)
;;; net-asn-test.el ends here
