;;; net-mode-test.el --- ERT tests for net-mode  -*- lexical-binding: t; -*-

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

;; ERT tests for the shared base mode: the kind registry, rendering,
;; bookmarks, RDAP, the JSON view, point keeping, folding and text
;; links.  Shared fixtures live in `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-mode-test-sniff-kinds ()
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

(ert-deftest net-mode-test-sniff-ipv6-not-mac ()
  "An IPv6 address stays an IP address even with 12 hex digits."
  (should (equal (net-sniff "::1:2:3:4:5:6") '(ip . "::1:2:3:4:5:6"))))

(ert-deftest net-mode-test-split-csv ()
  "The CSV splitter honors quotes and doubled quotes."
  (should (equal (net--split-csv-line "a,b,c") '("a" "b" "c")))
  (should (equal (net--split-csv-line "\"a,b\",c") '("a,b" "c")))
  (should (equal (net--split-csv-line "\"\"\"x\"\"\",y") '("\"x\"" "y")))
  (should (equal (net--split-csv-line "a,,c") '("a" "" "c"))))

(ert-deftest net-mode-test-read-csv-file ()
  "The record reader keeps quoted fields that span lines."
  (net-test--with-file
      (concat "Number,Description,WHOIS,RDAP,Reference\n"
              "1-1876,Assigned by ARIN,whois.arin.net,"
              "\"https://rdap.arin.net/registry\nhttp://rdap.arin.net/registry\","
              "[RFC 1]\n"
              "1877-1901,Assigned by RIPE NCC,whois.ripe.net,,,\n"
              "\n")
    (let ((records (net--read-csv-file net-test--file)))
      (should (= (length records) 3))
      (should (equal (car (nth 1 records)) "1-1876"))
      (should (equal (nth 3 (nth 1 records))
                     "https://rdap.arin.net/registry\nhttp://rdap.arin.net/registry"))
      (should (equal (nth 4 (nth 1 records)) "[RFC 1]"))))
  (should-not (net--read-csv-file nil)))

(ert-deftest net-mode-test-read-csv-file-crlf ()
  "The record reader accepts CRLF line endings."
  (net-test--with-file "a,b\r\nc,d\r\n"
    (should (equal (net--read-csv-file net-test--file)
                   '(("a" "b") ("c" "d"))))))

(ert-deftest net-mode-test-binary-table ()
  "The packed table reader binary searches fixed-width rows."
  (net-test--with-binary-file
      (net-test--packed-table
       4 0 1
       '((0 255 () ("LO"))
         (256 511 () ("HI"))
         (4096 4351 () ("TOP"))))
    (let ((net--binary-cache nil))
      (should (net--binary-available-p net-test--file))
      (let ((table (net--binary-table net-test--file
                                      '(:width 4 :numbers 0 :strings 1))))
        (should (= (plist-get table :count) 3))
        (should (eq table (net--binary-table
                           net-test--file
                           '(:width 4 :numbers 0 :strings 1))))
        (should (= (net--binary-find table 0) 0))
        (should (= (net--binary-find table 255) 0))
        (should (= (net--binary-find table 256) 1))
        (should (= (net--binary-find table 4351) 2))
        (should-not (net--binary-find table 512))
        (should-not (net--binary-find table 4352))
        (should (equal (net--binary-string table 1 0) "HI"))
        (should (= (net--binary-start table 2) 4096))
        (should (= (net--binary-end table 2) 4351))))))

(ert-deftest net-mode-test-binary-table-layout ()
  "A packed table with the wrong layout signals an error."
  (net-test--with-binary-file
      (net-test--packed-table 4 0 1 '((0 255 () ("LO"))))
    (let ((net--binary-cache nil))
      (should-error (net--binary-table net-test--file
                                       '(:width 4 :numbers 1 :strings 1)))
      (should-error (net--binary-table net-test--file
                                       '(:width 16 :numbers 0 :strings 1))))))

(ert-deftest net-mode-test-binary-table-ipv6 ()
  "A 16 byte address decodes to the same integer as `net-ip-parse'."
  (let* ((start (plist-get (net-ip-parse "2001:db8::") :value))
         (end (plist-get (net-ip-parse "2001:db8::ffff") :value)))
    (net-test--with-binary-file
        (net-test--packed-table 16 1 2
                                 (list (list start end (list 65000)
                                             '("US" "EXAMPLE"))))
      (let ((net--binary-cache nil)
            (table (net--binary-table
                    net-test--file
                    '(:width 16 :numbers 1 :strings 2))))
        (should (= (net--binary-number table 0 0) 65000))
        (should (equal (net--binary-string table 0 1) "EXAMPLE"))
        (should (= (net--binary-find table start) 0))
        (should (= (net--binary-find table end) 0))
        (should-not (net--binary-find table (1+ end)))))))

(ert-deftest net-mode-test-csv-not-binary ()
  "A CSV file is not mistaken for a packed table."
  (net-test--with-file "1.0.0.0,1.0.0.255,AU\n"
    (should-not (net--binary-available-p net-test--file))
    (should-not (net--binary-table net-test--file))))

(ert-deftest net-mode-test-display-reuses-buffer ()
  "Two inspections of the same value share one buffer."
  (let ((first (net-ip-inspect "192.0.2.1"))
        (second (net-ip-inspect "192.0.2.1")))
    (should (eq first second))
    (should (equal (buffer-name first) "*net-ip 192.0.2.1*"))
    (with-current-buffer first
      (should buffer-read-only)
      (should (derived-mode-p 'net-mode))
      (should-not (buffer-modified-p))
      (should (equal net--value "192.0.2.1"))
      (should (string-match-p "Private" (buffer-string)))
      (should (string-match-p "11000000\\.00000000\\.00000010\\.00000001"
                              (buffer-string))))))

(ert-deftest net-mode-test-modes-drop-the-project-directory ()
  "Every inspect mode starts its buffer in variable `temporary-file-directory'.
The rendered data comes from the network, not from a file, so the
buffer joins no project and no version-controlled tree."
  (let ((temporary-file-directory "/tmp/"))
    (dolist (mode '(net-mode net-ip-mode net-cidr-mode net-mac-mode
                    net-asn-mode net-domain-mode net-vsock-mode))
      (with-temp-buffer
        (setq default-directory "/some/project/")
        (funcall mode)
        (should (equal default-directory "/tmp/"))))))

(ert-deftest net-mode-test-inspect-buffer-drops-the-project-directory ()
  "An opened inspect buffer starts in variable `temporary-file-directory'.
Opening an address from a project must not put the buffer in it."
  (let ((temporary-file-directory "/tmp/")
        (default-directory "/some/project/"))
    (with-current-buffer (net-ip-inspect "192.0.2.1")
      (should (equal default-directory "/tmp/")))))

(ert-deftest net-mode-test-copy-value ()
  "Copying the inspected value fills the kill ring."
  (with-current-buffer (net-ip-inspect "203.0.113.9")
    (net-copy-value)
    (should (equal (car kill-ring) "203.0.113.9"))))

(ert-deftest net-mode-test-bookmark-record ()
  "The bookmark record carries the kind and the value."
  (with-current-buffer (net-ip-inspect "198.51.100.7")
    (let ((record (net--bookmark-make-record)))
      (should (eq (alist-get 'handler record) #'net--bookmark-jump))
      (should (eq (alist-get 'kind record) 'ip))
      (should (equal (alist-get 'value record) "198.51.100.7")))))

(ert-deftest net-mode-test-mode-line-value ()
  "The mode line names the inspected value."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (should (equal mode-line-process '(" 192.0.2.1")))))

(ert-deftest net-mode-test-bookmark-target ()
  "A bookmark records the row of point and lands on it again."
  (let ((buffer (net-ip-inspect "198.51.100.7")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^Class ")
          (beginning-of-line)
          (let* ((record (net--bookmark-make-record))
                 (target (alist-get 'target record)))
            (should (equal (plist-get target :identity) '(field . "Class")))
            (kill-buffer buffer)
            (let ((jumped (net--bookmark-jump record)))
              (unwind-protect
                  (with-current-buffer jumped
                    (should (looking-at-p "Class ")))
                (kill-buffer jumped)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest net-mode-test-bookmark-jump ()
  "Jumping to a bookmark record opens the inspect buffer."
  (let* ((record (list (cons 'handler #'net--bookmark-jump)
                       (cons 'kind 'cidr)
                       (cons 'value "10.0.0.0/8")))
         (buffer (net--bookmark-jump record)))
    (should (derived-mode-p 'net-cidr-mode))
    (should (equal (buffer-name buffer) "*net-cidr 10.0.0.0/8*"))))

(ert-deftest net-mode-test-rdap-url ()
  "The RDAP URL combines the bootstrap URL with type and key."
  (with-temp-buffer
    (setq-local net--rdap-type "ip")
    (setq-local net--rdap-key "192.0.2.1")
    (should (equal (net--rdap-url) "https://rdap.org/ip/192.0.2.1"))
    (should (net-rdap-available-p)))
  (with-temp-buffer
    (should-not (net--rdap-url))
    (should-not (net-rdap-available-p))))

(ert-deftest net-mode-test-rdap-entity-name ()
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

(ert-deftest net-mode-test-rdap-render ()
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

(ert-deftest net-mode-test-rdap-callback-appends ()
  "The RDAP section lands after the rendered fields.
The callback must not insert at point, which `net-refresh' leaves at
the start of the buffer."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (should (= (point-min) (point)))
    (net--rdap-callback (current-buffer) '(:error (error "Boom")))
    (should (string-match-p "\\`Address" (buffer-string)))
    (let ((rdap (string-match "RDAP" (buffer-string)))
          (reverse-name (string-match "Reverse DNS" (buffer-string))))
      (should rdap)
      (should (> rdap reverse-name)))
    (should net--rdap-start)))

(ert-deftest net-mode-test-buffer-unmodified ()
  "Rendering and RDAP leave the read-only buffer unmodified."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (should-not (buffer-modified-p))
    (set-buffer-modified-p t)
    (net-refresh)
    (should-not (buffer-modified-p))
    (net--rdap-callback (current-buffer) '(:error (error "Boom")))
    (should-not (buffer-modified-p))))

(ert-deftest net-mode-test-rdap-replaces-section ()
  "A second lookup replaces the earlier RDAP section."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (net--rdap-callback (current-buffer) '(:error (error "First")))
    (net--rdap-callback (current-buffer) '(:error (error "Second")))
    (should (= (how-many "^RDAP$" (point-min) (point-max)) 1))
    (should (string-match-p "Second" (buffer-string)))
    (should-not (string-match-p "First" (buffer-string)))))

(ert-deftest net-mode-test-rdap-render-error ()
  "An RDAP error object renders its code, title and description."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (let ((inhibit-read-only t))
      (net--rdap-begin-section)
      (net--rdap-render '((errorCode . 404)
                          (title . "Not Found")
                          (description . ("no such object")))))
    (should (string-match-p "RDAP error 404" (buffer-string)))
    (should (string-match-p "Not Found" (buffer-string)))
    (should (string-match-p "no such object" (buffer-string)))
    (should-not (string-match-p "unknown" (buffer-string)))))

(ert-deftest net-mode-test-rdap-callback-http-error ()
  "An HTTP error without a JSON body renders the status code."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (let ((target (current-buffer))
          (response (generate-new-buffer " *http test*")))
      (unwind-protect
          (progn
            (with-current-buffer response
              (insert "HTTP/1.1 500 Oops\n\n")
              (setq-local url-http-end-of-headers (point-max))
              (setq-local url-http-response-status 500)
              (net--rdap-callback target '()))
            (should (string-match-p "HTTP 500" (buffer-string))))
        (when (buffer-live-p response)
          (kill-buffer response))))))

(ert-deftest net-mode-test-rdap-timeout ()
  "A timeout clears the in-flight flag and renders a warning."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (setq-local net--rdap-in-flight t)
    (net--rdap-abandon (current-buffer))
    (should-not net--rdap-in-flight)
    (should (string-match-p "timed out" (buffer-string)))
    (should (string-match-p "RDAP" (buffer-string)))
    (should net--rdap-start)))

(ert-deftest net-mode-test-imenu-index ()
  "The rendered headings become an Imenu index."
  (with-current-buffer (net-ip-inspect "192.0.2.1")
    (let ((index (net--imenu-index)))
      (should (equal (car (car index)) "Address"))
      (should (member "Classification" (mapcar #'car index)))
      (dolist (entry index)
        (should (markerp (cdr entry)))
        (should (string-match-p
                 (regexp-quote (car entry))
                 (buffer-substring (cdr entry) (point-max))))))))

(ert-deftest net-mode-test-thing-at-point ()
  "The generic thing finds addresses in ordinary buffers."
  (with-temp-buffer
    (insert "route 10.0.0.0/8 via 192.0.2.1 today")
    (goto-char 8)
    (should (equal (thing-at-point 'net-address t) "10.0.0.0/8"))
    (goto-char 25)
    (should (equal (thing-at-point 'net-address t) "192.0.2.1"))))

(ert-deftest net-mode-test-thing-inside-url ()
  "The thing finds a host or an address inside a URL."
  (dolist (entry '(("http://1.2.3.4/x" . "1.2.3.4")
                   ("https://example.com/a?b=c" . "example.com")
                   ("https://example.org:8443/p" . "example.org")
                   ("http://[2001:db8::1]/x" . "2001:db8::1")))
    (with-temp-buffer
      (insert (car entry))
      (goto-char (1+ (string-match (regexp-quote (cdr entry))
                                   (car entry))))
      (should (equal (thing-at-point 'net-address t) (cdr entry))))))

(ert-deftest net-mode-test-thing-trailing-punctuation ()
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

(ert-deftest net-mode-test-thing-zone ()
  "The `net-ip' thing keeps an interface name after the percent sign."
  (with-temp-buffer
    (insert "fe80::1%en0")
    (goto-char (point-min))
    (should (equal (thing-at-point 'net-ip t) "fe80::1%en0"))
    (should (equal (thing-at-point 'net-address t) "fe80::1%en0"))))

(ert-deftest net-mode-test-inspect-trailing-dot ()
  "The dispatcher resolves an address before a sentence period."
  (with-temp-buffer
    (insert "see AS13335.")
    (goto-char (1- (point-max)))
    (net-inspect)
    (should (derived-mode-p 'net-asn-mode))))

(ert-deftest net-mode-test-data-description ()
  "A database description names the file, an optional count and a date."
  (net-test--with-file "x"
    (should (equal (net-data-description net-test--file "7 ranges")
                   (format "%s, 7 ranges, %s"
                           (file-name-nondirectory net-test--file)
                           (format-time-string "%Y-%m-%d"))))
    (should (equal (net-data-description net-test--file)
                   (format "%s, %s"
                           (file-name-nondirectory net-test--file)
                           (format-time-string "%Y-%m-%d"))))))

(ert-deftest net-mode-test-data-row-ffap ()
  "A data row resolves through ffap without printing the full path."
  (net-test--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "192.0.2.0/24,Documentation,[RFC 5737],2010-01,N/A,"
              "True,False,False,False,False\n")
    (let ((net-cidr-registry-file net-test--file)
          (net-ip--registry-cache nil))
      (with-current-buffer (net-cidr-inspect "192.0.2.0/24")
        (should (local-variable-p 'ffap-alist))
        ;; The row names the file without printing its path.
        (should (string-match-p "IANA special-purpose registry CSV"
                                (buffer-string)))
        (should-not (string-search net-test--file (buffer-string)))
        (goto-char (point-min))
        (let ((case-fold-search nil))
          (search-forward "registry CSV"))
        (backward-char)
        (should (equal (get-text-property (point) 'net-file)
                       net-test--file))
        ;; `ffap' may return the bare name when the fixture sits in the
        ;; buffer's default directory, so compare expanded paths.
        (should (equal (expand-file-name (ffap-file-at-point))
                       net-test--file))
        (should (equal (expand-file-name (ffap-guesser))
                       net-test--file))
        (should (equal (cadr (embark-net-target-database-file))
                       net-test--file))
        (let* ((report (net-cidr-report "192.0.2.0/24"))
               (section (seq-find
                         (lambda (candidate)
                           (eq (plist-get candidate :json) :classification))
                         (plist-get report :sections))))
          (should (equal (plist-get section :sourceFile)
                         net-test--file)))))))

(ert-deftest net-mode-test-data-row-opens-file ()
  "RET on a data row opens the database file."
  (net-test--with-file
      (concat "Address Block,Name,RFC,Allocation Date,Termination Date,"
              "Source,Destination,Forwardable,Globally Reachable,"
              "Reserved-by-Protocol\n"
              "192.0.2.0/24,Documentation,[RFC 5737],2010-01,N/A,"
              "True,False,False,False,False\n")
    (let ((net-cidr-registry-file net-test--file)
          (net-ip--registry-cache nil))
      (with-current-buffer (net-cidr-inspect "192.0.2.0/24")
        (goto-char (point-min))
        (let ((case-fold-search nil))
          (search-forward "registry CSV"))
        (backward-char)
        (let ((button (button-at (point))))
          (should (eq (button-get button 'action) #'net--open-file-button))
          (unwind-protect
              (progn
                (net--open-file-button button)
                (should (equal (buffer-file-name) net-test--file)))
            (kill-buffer (current-buffer))))
        (kill-buffer (current-buffer))))))

(defun net-test--kill-json-buffers ()
  "Kill the JSON view buffers that a test made."
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\`\\*net-.*\\* JSON\\'" (buffer-name buffer))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-report-keys ()
  "A report holds typed values under JSON keys."
  (let* ((report (net-cidr-report "192.0.2.0/24"))
         (rdap (plist-get report :rdap))
         (sections (plist-get report :sections))
         (prefix (car sections))
         (classification (cadr sections)))
    (should (equal (plist-get rdap :objectClassName) "ip network"))
    (should (equal (plist-get rdap :ipVersion) "v4"))
    (should (= (plist-get prefix :totalAddresses) 256))
    (should (= (plist-get prefix :usableHosts) 254))
    (should (eq (plist-get classification :private) :json-false))
    (should (equal (plist-get report :rdap-type) "ip"))))

(ert-deftest net-mode-test-report-every-kind ()
  "Every mode builds a report without a buffer."
  (dolist (form '((net-ip-report "192.0.2.1")
                  (net-cidr-report "192.0.2.0/24")
                  (net-mac-report "00:00:5e:00:53:01")
                  (net-asn-report "AS13335")
                  (net-domain-report "example.com")
                  (net-vsock-report "2:1024")))
    (let ((report (eval form t)))
      (should (or (null (plist-get report :summary))
                  (stringp (plist-get report :summary))))
      (should (plist-get report :sections))
      (dolist (section (plist-get report :sections))
        (should (keywordp (plist-get section :json)))
        (should (stringp (plist-get section :heading)))))))

(ert-deftest net-mode-test-report-rdap-identity ()
  "RDAP identities use the object class names of the registry."
  (should (equal (plist-get (plist-get (net-ip-report "192.0.2.1") :rdap)
                            :objectClassName)
                 "ip network"))
  (should (equal (plist-get (plist-get (net-asn-report "AS13335") :rdap)
                            :objectClassName)
                 "autnum"))
  (should (equal (plist-get (plist-get (net-domain-report "example.com")
                                      :rdap)
                            :objectClassName)
                 "domain"))
  (should-not (plist-get (net-mac-report "00:00:5e:00:53:01") :rdap))
  (should-not (plist-get (net-vsock-report "2:1024") :rdap)))

(ert-deftest net-mode-test-json-view-buffer ()
  "The JSON view is a read-only second buffer."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (should (eq major-mode 'net-json-mode))
          (should buffer-read-only)
          (should (string-match-p "\"schema\": 1" (buffer-string)))
          (should (string-match-p "\"kind\": \"ip\"" (buffer-string)))
          (should (string-match-p "\"objectClassName\": \"ip network\""
                                  (buffer-string)))
          (should (equal (buffer-name)
                         "*net-ip 192.0.2.1* JSON")))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-shared ()
  "A second call switches to the buffer it made before."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (let ((first (current-buffer)))
            (with-current-buffer buffer
              (net-json-view)
              (should (eq (current-buffer) first)))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-redraw ()
  "A refresh of the report buffer redraws the JSON buffer."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (let ((json (current-buffer)))
            (with-current-buffer buffer
              (setq net--value "192.0.2.2")
              (net-refresh))
            (with-current-buffer json
              (should (string-match-p "\"192.0.2.2\"" (buffer-string))))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-revert ()
  "Reverting the JSON buffer renders the report again."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (let ((json (current-buffer)))
            (with-current-buffer buffer
              (setq net--value "192.0.2.3"))
            (with-current-buffer json
              (revert-buffer)
              (should (string-match-p "\"192.0.2.3\"" (buffer-string))))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-rdap-answer ()
  "The parsed RDAP answer joins the report under its own key."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (let ((json (current-buffer)))
            (with-current-buffer buffer
              (setq-local net--rdap-raw
                          "{\"handle\":\"TEST-1\",\"status\":[\"active\"]}")
              (net--json-redraw))
            (with-current-buffer json
              (should (string-match-p "\"rdapAnswer\"" (buffer-string)))
              (should (string-match-p "\"handle\": \"TEST-1\""
                                      (buffer-string))))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-big-integer ()
  "An integer beyond 2^53 leaves the JSON as a string."
  (let ((buffer (net-ip-inspect "2001:db8::1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (let ((value (plist-get (net-ip-parse "2001:db8::1") :value)))
            (should (string-match-p
                     (concat "\"integer\": \"" (number-to-string value) "\"")
                     (buffer-string)))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-flags ()
  "Booleans reach the JSON as true and false."
  (let ((buffer (net-mac-inspect "aa:bb:cc:dd:ee:ff")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (should (string-match-p "\"multicast\": false" (buffer-string)))
          (should (string-match-p "\"local\": true" (buffer-string))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-read-address ()
  "The prompt announces a category and annotates the kind."
  (let ((net-inspect-history '("192.0.2.1" "AS13335")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection _predicate _require _initial _hist)
                 (should (equal collection '("192.0.2.1" "AS13335")))
                 (should (eq (plist-get completion-extra-properties :category)
                             'net-address))
                 "AS13335")))
      (should (equal (net-read-address) "AS13335")))
    (should (equal (net--address-annotation "AS13335") "  ASN"))
    (should (equal (net--address-annotation "192.0.2.0/24") "  CIDR"))
    (should-not (net--address-annotation "not an address"))))

(ert-deftest net-mode-test-read-address-default ()
  "Empty input answers the address at point."
  (with-temp-buffer
    (insert "see 192.0.2.1 here")
    (goto-char 8)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _collection _predicate _require initial _hist)
                 (should (equal initial "192.0.2.1"))
                 "")))
      (should (equal (net-read-address) "192.0.2.1")))))

(ert-deftest net-mode-test-json-view-keys ()
  "The JSON view quits, redraws and returns to its source."
  (should (eq (lookup-key net-json-mode-map (kbd "q")) #'quit-window))
  (should (eq (lookup-key net-json-mode-map (kbd "g r")) #'net--json-revert))
  (should (eq (lookup-key net-json-mode-map (kbd "J")) #'net--json-show-source)))

(ert-deftest net-mode-test-json-view-imenu ()
  "The imenu of the JSON view lists the sections and not the leaves."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (let ((index (net--json-imenu-index)))
            (should (assoc "rdap" index))
            (should (assoc "classification" index))
            (should-not (assoc "schema" index))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-source ()
  "The JSON view returns to the buffer that it reports on."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (should (eq (net--json-show-source) buffer))
          (should (eq (current-buffer) buffer)))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-side-window ()
  "The option moves the JSON view to the right edge."
  (let ((buffer (net-ip-inspect "192.0.2.1"))
        (net-json-side-window t))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (let ((window (get-buffer-window net--json-buffer t)))
            (should window)
            (should (eq (window-parameter window 'window-side) 'right))
            (should (eq (window-buffer (selected-window)) buffer))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-parent ()
  "The JSON view takes the parent mode that the machine can serve.
A machine without the JSON tree-sitter grammar cannot activate
`json-ts-mode', which signals an error, so the view falls back to
`js-json-mode'."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (should (eq major-mode 'net-json-mode))
          (should (if (net--json-ts-available-p)
                      (derived-mode-p 'json-ts-mode)
                    (derived-mode-p 'js-json-mode))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-json-view-refuses-other-buffers ()
  "The JSON view belongs to network inspect buffers only."
  (with-temp-buffer
    (should-error (net-json-view) :type 'user-error)))

(defun net-test--line-text ()
  "Return the text of the current line without properties."
  (buffer-substring-no-properties (line-beginning-position)
                                  (line-end-position)))

(ert-deftest net-mode-test-point-record-field ()
  "A named row records its label and not its buffer position."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^Class ")
          (beginning-of-line)
          (let ((record (net--point-record)))
            (should (equal (plist-get record :identity) '(field . "Class")))
            (should (zerop (plist-get record :offset)))
            (should (integerp (plist-get record :column)))))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-point-record-heading ()
  "A heading row records its title."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (search-forward "Reverse DNS")
          (beginning-of-line)
          (should (equal (plist-get (net--point-record) :identity)
                         '(heading . "Reverse DNS"))))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-point-record-text ()
  "A line without a name records its text and its ordinal."
  (with-temp-buffer
    (insert "one\nsame\nsame\nsame\n")
    (goto-char (point-min))
    (forward-line 2)
    (should (equal (plist-get (net--point-record) :identity)
                   '(text . ("same" . 1))))
    (net--goto-text '("same" . 2))
    (should (equal (net-test--line-text) "same"))
    (should (= 4 (line-number-at-pos)))))

(ert-deftest net-mode-test-point-record-blank-line ()
  "A blank line leans on the named line above it."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^Name ")
          (beginning-of-line)
          (forward-line 1)
          (should (looking-at-p "^$"))
          (let ((record (net--point-record)))
            (should (equal (plist-get record :identity) '(field . "Name")))
            (should (= 1 (plist-get record :offset)))))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-refresh-keeps-point ()
  "A refresh keeps point on the row that it was on.
The row moves down, because the value of the buffer grew, so the
label of the row keeps the place and not its line number."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^Class ")
          (beginning-of-line)
          (let ((column 20))
            (move-to-column column)
            (setq net--value "2001:db8::1")
            (net-refresh)
            (should (string-prefix-p "Class " (net-test--line-text)))
            (should (= (current-column) column))))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-refresh-keeps-window-point ()
  "A refresh keeps the line of a window that does not hold point."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((other (split-window)))
            (unwind-protect
                (progn
                  (set-window-buffer other buffer)
                  (with-selected-window other
                    (goto-char (point-min))
                    (re-search-forward "^Class ")
                    (beginning-of-line))
                  (setq net--value "2001:db8::1")
                  (net-refresh)
                  (with-selected-window other
                    (should (looking-at "Class"))))
              (delete-window other))))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-json-render-keeps-point ()
  "A redraw of the JSON view keeps point on the same member."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (net-json-view)
          (goto-char (point-min))
          (search-forward "\"kind\"")
          (beginning-of-line)
          (let ((line (net-test--line-text)))
            (net--json-revert)
            (should (equal (net-test--line-text) line))))
      (kill-buffer buffer)
      (net-test--kill-json-buffers))))

(ert-deftest net-mode-test-rdap-section-keeps-point ()
  "An RDAP section keeps the line of point when it arrives."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^Class ")
          (beginning-of-line)
          (net--rdap-draw-section
           (lambda () (net-insert-field "Handle" "TEST-1")))
          (should (looking-at "Class"))
          (should (string-match-p "TEST-1" (buffer-string)))
          ;; A second answer replaces the section and keeps the line.
          (net--rdap-draw-section
           (lambda () (net-insert-field "Handle" "TEST-2")))
          (should (looking-at "Class"))
          (should (string-match-p "TEST-2" (buffer-string)))
          (should-not (string-match-p "TEST-1" (buffer-string))))
      (kill-buffer buffer))))

(defun net-test--heading-invisible-p (title)
  "Return non-nil when the body of the section TITLE is folded."
  (save-excursion
    (goto-char (net--heading-position title))
    (outline-invisible-p (line-end-position))))

(ert-deftest net-mode-test-section-toggle ()
  "A toggle folds the section around point and unfolds it again."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (should outline-minor-mode)
          (goto-char (point-min))
          (re-search-forward "^Class ")
          (net-toggle-section)
          (should (net-test--heading-invisible-p "Classification"))
          (should-not (net-test--heading-invisible-p "Reverse DNS"))
          (net-toggle-section)
          (should-not (net-test--heading-invisible-p "Classification")))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-section-toggle-outside ()
  "A buffer without a heading refuses to fold."
  (with-temp-buffer
    (insert "plain text\n")
    (net-mode)
    (goto-char (point-min))
    (should-not (net--enclosing-heading))
    (should-error (net-toggle-section) :type 'user-error)))

(ert-deftest net-mode-test-section-fold-survives-refresh ()
  "A refresh keeps the sections that the reader folded."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^Class ")
          (net-toggle-section)
          (net-refresh)
          (should (net-test--heading-invisible-p "Classification"))
          (should-not (net-test--heading-invisible-p "Address")))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-section-fold-keeps-final-newline ()
  "A fold never hides the newline that ends the buffer.
`outline-hide-subtree' reaches `point-max' when the folded section
ends the buffer, and Emacs then drops that line break, so a later
RDAP section would draw on the row of the folded heading."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^Host prefix")
          (net-toggle-section)
          (should (net-test--heading-invisible-p "Related"))
          (let ((end (point-max)))
            (dolist (overlay (overlays-in (1- end) end))
              (should (< (overlay-end overlay) end))))
          (net--rdap-draw-section
           (lambda () (net-insert-field "Handle" "TEST-1")))
          (should (equal (get-text-property (net--heading-position "RDAP")
                                            'net-heading)
                         "RDAP")))
      (kill-buffer buffer))))

(defun net-test--buttons ()
  "Return the (KIND VALUE) pairs of every button of the buffer."
  (let (result
        (position (point-min)))
    (while (setq position (next-button position))
      (push (list (button-get position 'net-kind)
                  (button-get position 'net-value))
            result)
      (setq position (1+ position)))
    (nreverse result)))

(ert-deftest net-mode-test-text-links-addresses ()
  "Every address inside a text row becomes a button."
  (with-temp-buffer
    (net-mode)
    (let ((inhibit-read-only t))
      (net-insert-text "Note" "see 192.0.2.1 and 2001:db8::/32 for details"))
    (should (equal (net-test--buttons)
                   '((ip "192.0.2.1") (cidr "2001:db8::/32"))))))

(ert-deftest net-mode-test-text-links-none ()
  "A text row without an address carries no button."
  (with-temp-buffer
    (net-mode)
    (let ((inhibit-read-only t))
      (net-insert-text "Note" "IANA special-purpose registry CSV"))
    (should-not (net-test--buttons))))

(ert-deftest net-mode-test-text-links-file-row ()
  "A row that names an unreadable file keeps its file name plain.
A file name such as as-ranges-v4.bin reads as a domain name, and the
row is not a link when the file is missing."
  (with-temp-buffer
    (net-mode)
    (let ((inhibit-read-only t))
      (net--render-item '(:text "Source" :source :sourceFile)
                        '(:source "as-ranges-v4.bin"
                          :sourceFile "/nonexistent/as-ranges-v4.bin")))
    (should-not (net-test--buttons))))

(ert-deftest net-mode-test-text-links-url ()
  "The mode links the URLs of its text through `goto-address-mode'."
  (with-temp-buffer
    (net-mode)
    (should goto-address-mode)
    (let ((inhibit-read-only t))
      (net-insert-text "Note" "see https://example.org/path please"))
    (goto-address-fontify)
    (should (seq-some (lambda (overlay)
                        (overlay-get overlay 'goto-address))
                      (overlays-in (point-min) (point-max))))))

(ert-deftest net-mode-test-text-links-remark ()
  "An RDAP remark links the address and the mail address it names."
  (let ((buffer (net-ip-inspect "192.0.2.1")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (net--rdap-render
             '((remarks . (((description . ("Report abuse to
abuse@example.net or inspect 198.51.100.7 for details"))))))))
          (should (member '(domain "example.net") (net-test--buttons)))
          (should (member '(ip "198.51.100.7") (net-test--buttons)))
          (should (string-match-p "abuse@example\\.net" (buffer-string))))
      (kill-buffer buffer))))

(ert-deftest net-mode-test-pure-helpers ()
  "The side effect free helpers keep both properties."
  (dolist (symbol '(net-ip--groups-value net-ip--groups net-ip--bits
                    net-ip-in-block-p net-ip--format-ipv4
                    net-ip--format-ipv6 net-ip--format-ipv6-full
                    net-ip-format net-ip-canonical net-ip--range-prefix
                    net-cidr-canonical net-domain--punycode-digit
                    net-domain--punycode-adapt
                    net-domain--punycode-encode net-mac-hex
                    net-mac--prefix-string net-asn--asdot-number
                    net-asn-canonical net-asn-asdot
                    net-asn-classification net-vsock-canonical
                    net-geo--search net--split-csv-line))
    (should (get symbol 'pure))
    (should (get symbol 'side-effect-free))))

(provide 'net-mode-test)
;;; net-mode-test.el ends here
