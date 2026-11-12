;;; net-domain-test.el --- ERT tests for net-domain  -*- lexical-binding: t; -*-

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

;; ERT tests for domain names and the Public Suffix List.  Shared
;; fixtures live in `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-domain-test-punycode ()
  "Punycode encoding matches the RFC 3492 test vectors."
  (should (equal (net-domain-punycode-label "b\u00fccher") "xn--bcher-kva"))
  (should (equal (net-domain-punycode-label "m\u00fcnchen") "xn--mnchen-3ya"))
  (should (equal (net-domain-punycode-label "example") "example"))
  (should (equal (net-domain-punycode-label
                  (decode-coding-string "\344\276\213\345\255\220" 'utf-8))
                 "xn--fsqu00a")))

(ert-deftest net-domain-test-psl-punycode ()
  "The public suffix lookup uses the ASCII form of the name."
  (net-test--with-file
      (concat "// ===BEGIN ICANN DOMAINS===\n"
              "xn--fsqu00a\n"
              "// ===END ICANN DOMAINS===\n")
    (let ((net-domain-psl-file net-test--file)
          (net-domain--psl-cache nil))
      (let ((parsed (net-domain-parse
                     (concat "a."
                             (decode-coding-string "\344\276\213\345\255\220"
                                                   'utf-8)))))
        (should (equal (net-domain-ascii parsed) "a.xn--fsqu00a"))
        (should (= (car (net-domain-public-suffix parsed)) 1))))))

(ert-deftest net-domain-test-parse ()
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

(ert-deftest net-domain-test-psl-lookup ()
  "Public suffix matching handles plain, wildcard and exception rules."
  (net-test--with-file
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
    (let ((net-domain-psl-file net-test--file)
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

(ert-deftest net-domain-test-psl-unicode-rule ()
  "An IDN rule written in Unicode still matches the Punycode name."
  (net-test--with-file
      (concat "// ===BEGIN ICANN DOMAINS===\n"
              (decode-coding-string
               "\345\205\254\345\217\270.cn" 'utf-8)
              "\ncn\n// ===END ICANN DOMAINS===\n")
    (let ((net-domain-psl-file net-test--file)
          (net-domain--psl-cache nil))
      (let ((parsed (net-domain-parse "xn--55qx5d.cn")))
        (should (equal (net-domain-ascii parsed) "xn--55qx5d.cn"))
        (should (= (car (net-domain-public-suffix parsed)) 2))))))

(ert-deftest net-domain-test-section-default ()
  "An unmatched name reports the default rule, not the ICANN section."
  (net-test--with-file
      "// ===BEGIN ICANN DOMAINS===\ncom\n// ===END ICANN DOMAINS===\n"
    (let ((net-domain-psl-file net-test--file)
          (net-domain--psl-cache nil))
      (with-current-buffer (net-domain-inspect "host.zzz")
        (should (string-match-p "Section\\s-+default rule" (buffer-string)))))))

(ert-deftest net-domain-test-label-ascii-case ()
  "An ASCII label never shows a redundant ASCII column."
  (with-temp-buffer
    (net-domain-mode)
    (let ((inhibit-read-only t))
      (net--render-section
       (net-domain--report-label-section (net-domain-parse "Example.COM"))))
    (should-not (string-match-p ", ASCII" (buffer-string)))
    (should (string-match-p "^1\\. COM" (buffer-string)))))

(ert-deftest net-domain-test-buffer ()
  "The domain buffer reports the registrable domain."
  (net-test--with-file
      "// ===BEGIN ICANN DOMAINS===\ncom\nco.uk\n// ===END ICANN DOMAINS===\n"
    (let ((net-domain-psl-file net-test--file)
          (net-domain--psl-cache nil))
      (with-current-buffer (net-domain-inspect "www.example.co.uk")
        (should (string-match-p "^Suffix\\s-+co\\.uk$" (buffer-string)))
        (should (string-match-p "Registrable domain\\s-+example\\.co\\.uk"
                                (buffer-string)))
        (should (equal net--rdap-key "www.example.co.uk"))))))

(provide 'net-domain-test)
;;; net-domain-test.el ends here
