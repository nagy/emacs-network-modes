;;; net-tests.el --- ERT test suite for network modes  -*- lexical-binding: t; -*-

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

;; ERT test suite for the network address modes.  Run it with:
;;
;;   emacs -Q --batch -L . -l net-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'net-asn)
(require 'net-cidr)
(require 'net-domain)
(require 'net-geo)
(require 'net-ip)
(require 'net-mac)
(require 'net-mode)
(require 'net-vsock)
(require 'embark-net)
(require 'net-xref)

(defmacro net-tests--with-file (content &rest body)
  "Write CONTENT to a temporary file, bind `net-tests--file', run BODY."
  (declare (indent 1))
  `(let ((net-tests--file (make-temp-file "net-tests" nil ".dat")))
     (unwind-protect
         (progn
           (with-temp-file net-tests--file
             (insert ,content))
           ,@body)
       (delete-file net-tests--file))))

(defvar net-tests--file nil
  "Temporary file used by the tests.")

;;; net-mode

(ert-deftest net-tests-sniff-kinds ()
  "The dispatcher recognizes every kind with the right priority."
  (should (equal (net-sniff "10.0.0.0/8") '(cidr . "10.0.0.0/8")))
  (should (equal (net-sniff "aa:bb:cc:dd:ee:ff") '(mac . "aa:bb:cc:dd:ee:ff")))
  (should (equal (net-sniff "vsock://2:22") '(vsock . "2:22")))
  (should (equal (net-sniff "AS13335") '(asn . "AS13335")))
  (should (equal (net-sniff "AS1.10") '(asn . "AS65546")))
  (should-not (net-sniff "1.10"))
  (should-not (net-sniff "30.1"))
  (should-not (net-sniff "9.9.9.9/33"))
  (should (equal (net-sniff "example.com") '(domain . "example.com")))
  (should (equal (net-sniff "192.0.2.1") '(ip . "192.0.2.1")))
  (should-not (net-sniff "not an address"))
  (should-not (net-sniff "300.1.1.1")))

(ert-deftest net-tests-sniff-ipv6-not-mac ()
  "An IPv6 address stays an IP address even with 12 hex digits."
  (should (equal (net-sniff "::1:2:3:4:5:6") '(ip . "::1:2:3:4:5:6"))))

(ert-deftest net-tests-split-csv ()
  "The CSV splitter honors quotes and doubled quotes."
  (should (equal (net--split-csv-line "a,b,c") '("a" "b" "c")))
  (should (equal (net--split-csv-line "\"a,b\",c") '("a,b" "c")))
  (should (equal (net--split-csv-line "\"\"\"x\"\"\",y") '("\"x\"" "y")))
  (should (equal (net--split-csv-line "a,,c") '("a" "" "c"))))

(ert-deftest net-tests-read-csv-file ()
  "The record reader keeps quoted fields that span lines."
  (net-tests--with-file
      (concat "Number,Description,WHOIS,RDAP,Reference\n"
              "1-1876,Assigned by ARIN,whois.arin.net,"
              "\"https://rdap.arin.net/registry\nhttp://rdap.arin.net/registry\","
              "[RFC 1]\n"
              "1877-1901,Assigned by RIPE NCC,whois.ripe.net,,,\n"
              "\n")
    (let ((records (net--read-csv-file net-tests--file)))
      (should (= (length records) 3))
      (should (equal (car (nth 1 records)) "1-1876"))
      (should (equal (nth 3 (nth 1 records))
                     "https://rdap.arin.net/registry\nhttp://rdap.arin.net/registry"))
      (should (equal (nth 4 (nth 1 records)) "[RFC 1]"))))
  (should-not (net--read-csv-file nil)))

(ert-deftest net-tests-display-reuses-buffer ()
  "Two inspections of the same value share one buffer."
  (let ((first (net-ip-inspect "192.0.2.1"))
        (second (net-ip-inspect "192.0.2.1")))
    (should (eq first second))
    (should (equal (buffer-name first) "*net-ip 192.0.2.1*"))
    (with-current-buffer first
      (should buffer-read-only)
      (should (derived-mode-p 'net-mode))
      (should (equal net--value "192.0.2.1"))
      (should (string-match-p "Private" (buffer-string)))
      (should (string-match-p "11000000\\.00000000\\.00000010\\.00000001"
                              (buffer-string))))))

(ert-deftest net-tests-copy-value ()
  "Copying the inspected value fills the kill ring."
  (with-current-buffer (net-ip-inspect "203.0.113.9")
    (net-copy-value)
    (should (equal (car kill-ring) "203.0.113.9"))))

(ert-deftest net-tests-bookmark-record ()
  "The bookmark record carries the kind and the value."
  (with-current-buffer (net-ip-inspect "198.51.100.7")
    (let ((record (net--bookmark-make-record)))
      (should (eq (alist-get 'handler record) #'net--bookmark-jump))
      (should (eq (alist-get 'kind record) 'ip))
      (should (equal (alist-get 'value record) "198.51.100.7")))))

(ert-deftest net-tests-bookmark-jump ()
  "Jumping to a bookmark record opens the inspect buffer."
  (let* ((record (list (cons 'handler #'net--bookmark-jump)
                       (cons 'kind 'cidr)
                       (cons 'value "10.0.0.0/8")))
         (buffer (net--bookmark-jump record)))
    (should (derived-mode-p 'net-cidr-mode))
    (should (equal (buffer-name buffer) "*net-cidr 10.0.0.0/8*"))))

(ert-deftest net-tests-rdap-url ()
  "The RDAP URL combines the bootstrap URL with type and key."
  (with-temp-buffer
    (setq-local net--rdap-type "ip")
    (setq-local net--rdap-key "192.0.2.1")
    (should (equal (net--rdap-url) "https://rdap.org/ip/192.0.2.1"))
    (should (net-rdap-available-p)))
  (with-temp-buffer
    (should-not (net--rdap-url))
    (should-not (net-rdap-available-p))))

(ert-deftest net-tests-rdap-entity-name ()
  "The vcard fallback reads the formatted name value."
  (let ((entity (list (cons 'handle "HANDLE")
                      (cons 'vcardArray
                            (list "vcard"
                                  (list (list "version" nil "text" "4.0")
                                        (list "fn" nil "text" "Example Org")))))))
    (should (equal (net--rdap-entity-name entity) "HANDLE")))
  (let ((entity (list (cons 'vcardArray
                            (list "vcard"
                                  (list (list "fn" nil "text" "Example Org")))))))
    (should (equal (net--rdap-entity-name entity) "Example Org"))))

(ert-deftest net-tests-rdap-render ()
  "The RDAP renderer writes fields into the inspect buffer."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (let ((inhibit-read-only t))
      (net-insert-heading "RDAP")
      (net--rdap-render
       '((handle . "TEST-NET-1")
         (name . "TEST-NET-1")
         (status "active")
         (events . (((eventAction . "registration")
                     (eventDate . "2010-01-01T00:00:00Z"))))
         (entities . (((handle . "IANA")
                       (roles "registrant")
                       (vcardArray . ("vcard" (("fn" nil "text" "IANA"))))))))))
    (should (string-match-p "TEST-NET-1" (buffer-string)))
    (should (string-match-p "Registration" (buffer-string)))
    (should (string-match-p "IANA" (buffer-string)))))

(ert-deftest net-tests-rdap-callback-appends ()
  "The RDAP section lands after the rendered fields.
The callback must not insert at point, which `net-refresh' leaves at
the start of the buffer."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (should (= (point-min) (point)))
    (net--rdap-callback (current-buffer) '(:error (error "boom")))
    (should (string-match-p "\\`Address" (buffer-string)))
    (let ((rdap (string-match "RDAP" (buffer-string)))
          (reverse-name (string-match "Reverse DNS" (buffer-string))))
      (should rdap)
      (should (> rdap reverse-name)))
    (should net--rdap-start)))

(ert-deftest net-tests-rdap-replaces-section ()
  "A second lookup replaces the earlier RDAP section."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (net--rdap-callback (current-buffer) '(:error (error "first")))
    (net--rdap-callback (current-buffer) '(:error (error "second")))
    (should (= (how-many "^RDAP$" (point-min) (point-max)) 1))
    (should (string-match-p "second" (buffer-string)))
    (should-not (string-match-p "first" (buffer-string)))))

(ert-deftest net-tests-thing-at-point ()
  "The generic thing finds addresses in ordinary buffers."
  (with-temp-buffer
    (insert "route 10.0.0.0/8 via 192.0.2.1 today")
    (goto-char 8)
    (should (equal (thing-at-point 'net-address t) "10.0.0.0/8"))
    (goto-char 25)
    (should (equal (thing-at-point 'net-address t) "192.0.2.1"))))

(ert-deftest net-tests-thing-trailing-punctuation ()
  "Trailing punctuation does not hide an address."
  (dolist (entry '(("see 192.0.2.1." . "192.0.2.1")
                   ("see 10.0.0.0/8." . "10.0.0.0/8")
                   ("see aa:bb:cc:dd:ee:ff." . "aa:bb:cc:dd:ee:ff")
                   ("see AS13335." . "AS13335")
                   ("see 2001:db8::1." . "2001:db8::1")
                   ("see 2:22." . "2:22")))
    (with-temp-buffer
      (insert (car entry))
      (goto-char (1- (point-max)))
      (should (equal (thing-at-point 'net-address t) (cdr entry))))))

(ert-deftest net-tests-thing-zone ()
  "The `net-ip' thing keeps an interface name after the percent sign."
  (with-temp-buffer
    (insert "fe80::1%en0")
    (goto-char (point-min))
    (should (equal (thing-at-point 'net-ip t) "fe80::1%en0"))
    (should (equal (thing-at-point 'net-address t) "fe80::1%en0"))))

(ert-deftest net-tests-inspect-trailing-dot ()
  "The dispatcher resolves an address before a sentence period."
  (with-temp-buffer
    (insert "see AS13335.")
    (goto-char (1- (point-max)))
    (net-inspect)
    (should (derived-mode-p 'net-asn-mode))))

;;; net-ip

(ert-deftest net-tests-ipv4-parse ()
  "IPv4 parsing accepts dotted quads and rejects malformed input."
  (should (= (plist-get (net-ip-parse "10.0.0.1") :value) 167772161))
  (should (= (plist-get (net-ip-parse "0.0.0.0") :value) 0))
  (should (= (plist-get (net-ip-parse "255.255.255.255") :value) 4294967295))
  (should-not (net-ip-parse "256.0.0.1"))
  (should-not (net-ip-parse "1.2.3"))
  (should-not (net-ip-parse "01.2.3.4"))
  (should-not (net-ip-parse "1.2.3.4.5")))

(ert-deftest net-tests-ipv6-parse ()
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

(ert-deftest net-tests-ipv6-format ()
  "IPv6 formatting follows RFC 5952."
  (should (equal (net-ip-format 0 6) "::"))
  (should (equal (net-ip-format 1 6) "::1"))
  (should (equal (net-ip-format (ash 1 112) 6) "1::"))
  (should (equal (net-ip-format (logior (ash #x20010db8 96) 1) 6)
                 "2001:db8::1"))
  (should (equal (net-ip-format (logior (ash 1 112) 1) 6) "1::1"))
  (should (equal (net-ip-format (1- (ash 1 128)) 6)
                 "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")))

(ert-deftest net-tests-ipv6-single-zero-group ()
  "A single zero group stays uncompressed."
  (should (equal (net-ip-format (logior (ash 1 112) (ash 1 96) (ash 1 64)) 6)
                 "1:1:0:1::")))

(ert-deftest net-tests-reverse-dns ()
  "Reverse DNS names for both address families."
  (should (equal (net-ip-reverse-dns 167772161 4) "1.0.0.10.in-addr.arpa"))
  (should (equal (net-ip-reverse-dns (plist-get (net-ip-parse "2001:db8::1") :value) 6)
                 "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")))

(ert-deftest net-tests-ip-classification ()
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

(ert-deftest net-tests-private ()
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

(ert-deftest net-tests-ip-buffer ()
  "The IP buffer lists embedded addresses of transition mechanisms."
  (with-current-buffer (net-ip-inspect "::ffff:192.0.2.1")
    (should (string-match-p "Embedded IPv4" (buffer-string)))
    (should (string-match-p "192.0.2.1" (buffer-string)))
    (should (equal net--rdap-type "ip"))))

;;; net-cidr

(ert-deftest net-tests-cidr-parse ()
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

(ert-deftest net-tests-cidr-reverse-zone ()
  "Reverse zones appear only for aligned prefixes."
  (should (equal (net-cidr-reverse-zone 167772160 8 4) "10.in-addr.arpa"))
  (should (equal (net-cidr-reverse-zone 167772160 16 4) "0.10.in-addr.arpa"))
  (should-not (net-cidr-reverse-zone 167772160 12 4))
  (should (equal (net-cidr-reverse-zone (plist-get (net-ip-parse "2001:db8::") :value)
                                        32 6)
                 "8.b.d.0.1.0.0.2.ip6.arpa")))

(ert-deftest net-tests-cidr-host-counts ()
  "Usable host counts follow IPv4 conventions."
  (with-current-buffer (net-cidr-inspect "192.0.2.0/31")
    (should (string-match-p "Usable hosts" (buffer-string)))
    (should (string-match-p "\\_<2\\_>" (buffer-string))))
  (with-current-buffer (net-cidr-inspect "192.0.2.0/32")
    (should (string-match-p "\\_<1\\_>" (buffer-string)))))

(ert-deftest net-tests-cidr-registry-csv ()
  "The IANA registry CSV narrows the classification."
  (net-tests--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,Reserved-by-Protocol\n"
              "192.0.2.0/24,Documentation,[RFC 5737],2010-01,N/A,"
              "True,False,False,False,False\n")
    (let ((net-cidr-registry-file net-tests--file)
          (net-ip--registry-cache nil))
      (let ((matches (net-cidr-matching-entries (net-cidr-parse "192.0.2.128/25"))))
        (should (= (length matches) 1))
        (should (equal (plist-get (car matches) :name) "Documentation"))
        (should (equal (plist-get (car matches) :source) "True"))
        (should (equal (plist-get (car matches) :global) "False"))))))

(ert-deftest net-tests-cidr-registry-annotations ()
  "Registry rows with footnotes and several blocks still classify."
  (net-tests--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "192.0.0.0/24 [2],IETF Protocol Assignments,[RFC 6890],"
              "2010-01,N/A,False,False,False,False,False\n"
              "\"192.0.0.170/32, 192.0.0.171/32\",NAT64/DNS64 Discovery,"
              "[RFC 8880],2013-02,N/A,False,False,False,False,True\n")
    (let ((net-ip-registry-file net-tests--file)
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

(ert-deftest net-tests-cidr-label-gap ()
  "A long block name keeps a space before its value."
  (let ((net-ip-registry-file nil)
        (net-ip-registry-file-v6 nil))
    (with-current-buffer (net-cidr-inspect "192.0.0.8/32")
      (should (string-match-p "IETF Protocol Assignments 192\\.0\\.0\\.0/24"
                              (buffer-string))))))

(ert-deftest net-tests-ip-registry ()
  "The IANA CSV supplies the classification when it exists."
  (net-tests--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "3fff::/20,Documentation,[RFC 9637],2024-07,N/A,"
              "False,False,False,False,False\n")
    (let ((net-ip-registry-file-v6 net-tests--file)
          (net-ip--registry-cache nil))
      (should (equal (plist-get
                      (car (net-ip-matching-blocks
                            (plist-get (net-ip-parse "3fff::1") :value) 6))
                      :name)
                     "Documentation")))))

(ert-deftest net-tests-ip-multicast-survives-csv ()
  "The built-in multicast rows survive the IANA CSV."
  (net-tests--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "10.0.0.0/8,Private-Use,[RFC 1918],1996-02,N/A,True,True,True,False,False\n")
    (let ((net-ip-registry-file net-tests--file)
          (net-ip--registry-cache nil))
      (should (equal (plist-get
                      (car (net-ip-matching-blocks
                            (plist-get (net-ip-parse "224.0.0.1") :value) 4))
                      :name)
                     "Multicast")))))

(ert-deftest net-tests-cidr-buffer-private ()
  "The CIDR buffer reports private ranges without a registry file."
  (let ((net-cidr-registry-file nil)
        (net-cidr-registry-file-v6 nil))
    (with-current-buffer (net-cidr-inspect "172.16.0.0/12")
      (should (string-match-p "Private-Use" (buffer-string)))
      (should (string-match-p "RFC 1918" (buffer-string)))
      (should (string-match-p "built-in table" (buffer-string))))))

;;; net-mac

(ert-deftest net-tests-mac-parse ()
  "MAC parsing accepts the common notations."
  (dolist (text '("aa:bb:cc:dd:ee:ff" "AA-BB-CC-DD-EE-FF" "aabb.ccdd.eeff"
                  "aabbccddeeff" "00:11:22:33:44:55:66:77"))
    (should (net-mac-parse text)))
  (should (equal (net-mac-canonical (net-mac-parse "AA-BB-CC-DD-EE-FF"))
                 "aa:bb:cc:dd:ee:ff"))
  (should-not (net-mac-parse "aa:bb:cc:dd:ee"))
  (should-not (net-mac-parse "gg:bb:cc:dd:ee:ff"))
  (should-not (net-mac-parse "aa:bb:cc:dd:ee:ff:")))

(ert-deftest net-tests-mac-flags ()
  "The multicast and local bits are decoded."
  (with-current-buffer (net-mac-inspect "ff:ff:ff:ff:ff:ff")
    (should (string-match-p "multicast" (buffer-string)))
    (should (string-match-p "Broadcast" (buffer-string))))
  (with-current-buffer (net-mac-inspect "02:00:00:00:00:01")
    (should (string-match-p "locally administered" (buffer-string))))
  (with-current-buffer (net-mac-inspect "33:33:00:00:00:01")
    (should (string-match-p "IPv6 multicast" (buffer-string)))))

(ert-deftest net-tests-mac-ieee ()
  "The IEEE registry lookup covers every assignment length."
  (let ((directory (make-temp-file "net-tests-mac" t)))
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

(ert-deftest net-tests-mac-manuf ()
  "The manuf lookup honors exact and masked prefixes."
  (let ((file (make-temp-file "net-tests-manuf")))
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

(ert-deftest net-tests-mac-eui64 ()
  "The IPv6 interface identifier flips the U/L bit."
  (with-current-buffer (net-mac-inspect "00:00:0c:12:34:56")
    (should (string-match-p "02:00:0c:ff:fe:12:34:56" (buffer-string)))
    (should (string-match-p "fe80::200:cff:fe12:3456" (buffer-string)))))

;;; net-asn

(ert-deftest net-tests-asn-parse ()
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

(ert-deftest net-tests-asn-asdot ()
  "ASDOT rendering starts above 16 bits."
  (should-not (net-asn-asdot 13335))
  (should (equal (net-asn-asdot 65546) "1.10"))
  (should (equal (net-asn-asdot 4200000000) "64086.59904")))

(ert-deftest net-tests-asn-classification ()
  "Reservation classes cover the usual ranges."
  (should (equal (car (net-asn-classification 0)) "Reserved"))
  (should (equal (car (net-asn-classification 64512)) "Private-Use"))
  (should (equal (car (net-asn-classification 65534)) "Private-Use"))
  (should (equal (car (net-asn-classification 64496)) "Documentation"))
  (should (equal (car (net-asn-classification 23456))
                 "AS_TRANS (4-byte AS transition)"))
  (should (equal (car (net-asn-classification 4200000001)) "Private-Use"))
  (should (equal (car (net-asn-classification 13335)) "Assigned")))

(ert-deftest net-tests-asn-registry ()
  "The IANA registry CSV gives the block of an AS number."
  (net-tests--with-file
      (concat "Number,Description,WHOIS,RDAP,Reference,Registration Date\n"
              "1-1876,Assigned by ARIN,whois.arin.net,,,\n"
              "64512-65534,Private Use,,,[RFC 6996],\n")
    (let ((net-asn-registry-file net-tests--file)
          (net-asn--registry-cache nil))
      (let ((row (net-asn-registry-row 1000)))
        (should (equal (plist-get row :description) "Assigned by ARIN")))
      (should (equal (plist-get (net-asn-registry-row 65000) :description)
                     "Private Use"))
      (should-not (net-asn-registry-row 5000)))))

(ert-deftest net-tests-asn-metadata-pretty ()
  "The metadata lookup finds one object in a pretty printed file."
  (net-tests--with-file
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
    (let ((net-asn-database-file net-tests--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (let ((entry (net-asn-entry 13335)))
        (should (equal (alist-get 'handle (alist-get 'metadata entry))
                       "CLOUDFLARENET")))
      (should-not (net-asn-entry 99999)))))

(ert-deftest net-tests-asn-metadata-minified ()
  "The metadata lookup finds one object in a minified file."
  (net-tests--with-file
      "[{\"asn\":1,\"metadata\":{\"handle\":\"A\"}},{\"asn\":13335,\"metadata\":{\"handle\":\"CLOUDFLARENET\"}}]"
    (let ((net-asn-database-file net-tests--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (should (equal (alist-get 'handle
                                (alist-get 'metadata (net-asn-entry 13335)))
                     "CLOUDFLARENET")))))

(ert-deftest net-tests-asn-buffer ()
  "The ASN buffer shows identity and RDAP identity."
  (let ((net-asn-database-file nil)
        (net-asn-registry-file nil)
        (net-asn-registry-file-v2 nil))
    (with-current-buffer (net-asn-inspect "AS64512")
      (should (string-match-p "Private-Use" (buffer-string)))
      (should (string-match-p "RFC 6996" (buffer-string)))
      (should (equal net--rdap-type "autnum"))
      (should (equal net--rdap-key "64512")))))

;;; net-domain

(ert-deftest net-tests-punycode ()
  "Punycode encoding matches the RFC 3492 test vectors."
  (should (equal (net-domain-punycode-label "b\u00fccher") "xn--bcher-kva"))
  (should (equal (net-domain-punycode-label "m\u00fcnchen") "xn--mnchen-3ya"))
  (should (equal (net-domain-punycode-label "example") "example"))
  (should (equal (net-domain-punycode-label
                  (decode-coding-string "\344\276\213\345\255\220" 'utf-8))
                 "xn--fsqu00a")))

(ert-deftest net-tests-asn-metadata-key-order ()
  "A file that does not put \"asn\" first still resolves through the table."
  (net-tests--with-file
      (concat "[{\"metadata\":{\"handle\":\"LATE\"},\"asn\":13335},"
              "{\"metadata\":{\"handle\":\"C\"},\"asn\":174}]")
    (let ((net-asn-database-file net-tests--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (should (equal (alist-get 'handle
                                (alist-get 'metadata (net-asn-entry 13335)))
                     "LATE")))))

(ert-deftest net-tests-asn-provider-links ()
  "The provider list renders as one wrapping label line."
  (net-tests--with-file
      (concat "[{\"asn\":1,\"metadata\":{\"handle\":\"A\"},"
              "\"stats\":{\"connectivity\":{\"providers\":2,"
              "\"providerAsns\":[174,3356]}}}]")
    (let ((net-asn-database-file net-tests--file)
          (net-asn--table nil)
          (net-asn--memo nil))
      (with-current-buffer (net-asn-inspect "AS1")
        (should (string-match-p "Upstream Providers\\s-+AS174, AS3356"
                                (buffer-string)))))))

(ert-deftest net-tests-psl-punycode ()
  "The public suffix lookup uses the ASCII form of the name."
  (net-tests--with-file
      (concat "// ===BEGIN ICANN DOMAINS===\n"
              "xn--fsqu00a\n"
              "// ===END ICANN DOMAINS===\n")
    (let ((net-domain-psl-file net-tests--file)
          (net-domain--psl-cache nil))
      (let ((parsed (net-domain-parse
                     (concat "a."
                             (decode-coding-string "\344\276\213\345\255\220"
                                                   'utf-8)))))
        (should (equal (net-domain-ascii parsed) "a.xn--fsqu00a"))
        (should (= (car (net-domain-public-suffix parsed)) 1))))))

(ert-deftest net-tests-domain-parse ()
  "Domain parsing validates labels and lengths."
  (should (net-domain-parse "example.com"))
  (should (net-domain-parse "example.com."))
  (should (net-domain-parse "localhost"))
  (should-not (net-domain-parse "-example.com"))
  (should-not (net-domain-parse "example-.com"))
  (should-not (net-domain-parse (concat (make-string 64 ?a) ".com")))
  (let ((parsed (net-domain-parse "Example.COM.")))
    (should (equal (net-domain-canonical parsed) "example.com"))
    (should (plist-get parsed :trailing-dot))))

(ert-deftest net-tests-psl-lookup ()
  "Public suffix matching handles plain, wildcard and exception rules."
  (net-tests--with-file
      (concat "// ===BEGIN ICANN DOMAINS===\n"
              "com\n"
              "uk\n"
              "co.uk\n"
              "*.ck\n"
              "!www.ck\n"
              "// ===END ICANN DOMAINS===\n"
              "// ===BEGIN PRIVATE DOMAINS===\n"
              "blogspot.com\n"
              "// ===END PRIVATE DOMAINS===\n")
    (let ((net-domain-psl-file net-tests--file)
          (net-domain--psl-cache nil))
      (let ((parsed (net-domain-parse "www.example.co.uk")))
        (should (= (car (net-domain-public-suffix parsed)) 2)))
      (let ((parsed (net-domain-parse "WWW.Example.CO.UK")))
        (should (= (car (net-domain-public-suffix parsed)) 2)))
      (let ((parsed (net-domain-parse "a.b.blogspot.com")))
        (let ((match (net-domain-public-suffix parsed)))
          (should (= (car match) 2))
          (should (eq (cdr match) 'private))))
      (let ((parsed (net-domain-parse "foo.ck")))
        (should (= (car (net-domain-public-suffix parsed)) 2)))
      (let ((parsed (net-domain-parse "www.ck")))
        (should (= (car (net-domain-public-suffix parsed)) 1)))
      (let ((parsed (net-domain-parse "example.com")))
        (should (= (car (net-domain-public-suffix parsed)) 1))))))

(ert-deftest net-tests-psl-unicode-rule ()
  "An IDN rule written in Unicode still matches the Punycode name."
  (net-tests--with-file
      (concat "// ===BEGIN ICANN DOMAINS===\n"
              (decode-coding-string
               "\345\205\254\345\217\270.cn" 'utf-8)
              "\ncn\n// ===END ICANN DOMAINS===\n")
    (let ((net-domain-psl-file net-tests--file)
          (net-domain--psl-cache nil))
      (let ((parsed (net-domain-parse "xn--55qx5d.cn")))
        (should (equal (net-domain-ascii parsed) "xn--55qx5d.cn"))
        (should (= (car (net-domain-public-suffix parsed)) 2))))))

(ert-deftest net-tests-domain-section-default ()
  "An unmatched name reports the default rule, not the ICANN section."
  (net-tests--with-file
      "// ===BEGIN ICANN DOMAINS===\ncom\n// ===END ICANN DOMAINS===\n"
    (let ((net-domain-psl-file net-tests--file)
          (net-domain--psl-cache nil))
      (with-current-buffer (net-domain-inspect "host.zzz")
        (should (string-match-p "Section\\s-+default rule" (buffer-string)))))))

(ert-deftest net-tests-domain-label-ascii-case ()
  "An ASCII label never shows a redundant ASCII column."
  (with-temp-buffer
    (net-domain-mode)
    (let ((inhibit-read-only t))
      (net-domain--insert-label-section (net-domain-parse "Example.COM")))
    (should-not (string-match-p ", ASCII" (buffer-string)))
    (should (string-match-p "^1\\. COM" (buffer-string)))))

(ert-deftest net-tests-domain-buffer ()
  "The domain buffer reports the registrable domain."
  (net-tests--with-file
      "// ===BEGIN ICANN DOMAINS===\ncom\nco.uk\n// ===END ICANN DOMAINS===\n"
    (let ((net-domain-psl-file net-tests--file)
          (net-domain--psl-cache nil))
      (with-current-buffer (net-domain-inspect "www.example.co.uk")
        (should (string-match-p "^Suffix\\s-+co\\.uk$" (buffer-string)))
        (should (string-match-p "Registrable domain\\s-+example\\.co\\.uk"
                                (buffer-string)))
        (should (equal net--rdap-key "www.example.co.uk"))))))

;;; net-vsock

(ert-deftest net-tests-vsock-parse ()
  "Vsock parsing accepts CID:PORT with optional scheme."
  (should (= (plist-get (net-vsock-parse "2:22") :cid) 2))
  (should (= (plist-get (net-vsock-parse "vsock://2:22") :port) 22))
  (should (= (plist-get (net-vsock-parse "0xFFFFFFFF:0xFFFFFFFF") :cid) 4294967295))
  (should-not (net-vsock-parse "2"))
  (should-not (net-vsock-parse "2:65536:1"))
  (should-not (net-vsock-parse "2:abc")))

(ert-deftest net-tests-vsock-buffer ()
  "The vsock buffer names reserved CIDs and shows the struct."
  (with-current-buffer (net-vsock-inspect "vsock://2:22")
    (should (string-match-p "VMADDR_CID_HOST" (buffer-string)))
    (should (string-match-p "svm_cid" (buffer-string)))
    (should (string-match-p "struct sockaddr" (buffer-string))))
  (with-current-buffer (net-vsock-inspect "0:0")
    (should (string-match-p "VMADDR_CID_HYPERVISOR" (buffer-string)))))

(ert-deftest net-tests-vsock-services ()
  "The IANA service lookup reports matching ports."
  (net-tests--with-file
      (concat "Service Name,Port Number,Transport Protocol,Description,"
              "Assignee,Contact,Registration Date,Modification Date,Reference\n"
              "ssh,22,tcp,The Secure Shell (SSH) Protocol,,,,,,\n"
              ",\"6000-6063\",tcp,Reserved,,,,,,\n")
    (let ((net-vsock-service-file net-tests--file)
          (net-vsock--service-cache nil))
      (let ((rows (net-vsock--services 22)))
        (should (= (length rows) 1))
        (should (equal (plist-get (car rows) :name) "ssh")))
      (should (= (length (net-vsock--services 6001)) 1)))
    (let ((net-vsock-service-file nil)
          (net-vsock--service-cache nil))
      (should-not (net-vsock--services 22)))))

;;; net-geo

(ert-deftest net-tests-geo-country ()
  "The GeoIP lookup binary searches the range file."
  (net-tests--with-file
      (concat "ip_range_start,ip_range_end,country_code\n"
              "1.0.0.0,1.0.0.255,AU\n"
              "1.0.1.0,1.0.3.255,CN\n"
              "192.0.2.0,192.0.2.255,US\n")
    (let ((net-geo-database-file net-tests--file)
          (net-geo--cache nil))
      (should (equal (net-geo-country (plist-get (net-ip-parse "1.0.0.5") :value) 4)
                     "AU"))
      (should (equal (net-geo-country (plist-get (net-ip-parse "1.0.2.1") :value) 4)
                     "CN"))
      (should-not (net-geo-country (plist-get (net-ip-parse "1.0.4.0") :value) 4)))))

(ert-deftest net-tests-geo-cache ()
  "The parsed range file is reused and cleared on request."
  (net-tests--with-file
      (concat "ip_range_start,ip_range_end,country_code\n"
              "1.0.0.0,1.0.0.255,AU\n")
    (let ((net-geo-database-file net-tests--file)
          (net-geo--cache nil))
      (net-geo-country (plist-get (net-ip-parse "1.0.0.1") :value) 4)
      (should (= (length net-geo--cache) 1))
      (net-geo-clear-cache)
      (should-not net-geo--cache))))

;;; Integrations

(ert-deftest net-tests-xref-backend ()
  "The xref backend claims net addresses only."
  (with-temp-buffer
    (insert "10.0.0.1")
    (goto-char (point-min))
    (should (eq (net-xref-backend-function) 'net-xref)))
  (with-temp-buffer
    (insert "nothing here")
    (goto-char (point-min))
    (should-not (net-xref-backend-function))))

(ert-deftest net-tests-embark-target ()
  "The Embark target finder returns the kind and the bounds."
  (with-temp-buffer
    (insert "gw 192.0.2.1")
    (goto-char (point-max))
    (let ((target (embark-net-target-at-point)))
      (should (eq (car target) 'net-address))
      (should (equal (cadr target) "192.0.2.1")))))

(provide 'net-tests)
;;; net-tests.el ends here
