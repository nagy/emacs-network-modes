;;; net-geo-test.el --- ERT tests for net-geo  -*- lexical-binding: t; -*-

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

;; ERT tests for the country lookup.  Shared fixtures live in
;; `network-modes-test-helper.el'.

;;; Code:

(require 'network-modes-test-helper)

(ert-deftest net-geo-test-country ()
  "The GeoIP lookup binary searches the range file."
  (net-test--with-file
      (concat "ip_range_start,ip_range_end,country_code\n"
              "1.0.0.0,1.0.0.255,AU\n"
              "1.0.1.0,1.0.3.255,CN\n"
              "192.0.2.0,192.0.2.255,US\n")
    (let ((net-geo-database-file net-test--file)
          (net-geo--cache nil))
      (should (equal (net-geo-country (plist-get (net-ip-parse "1.0.0.5") :value) 4)
                     "AU"))
      (should (equal (net-geo-country (plist-get (net-ip-parse "1.0.2.1") :value) 4)
                     "CN"))
      (should-not (net-geo-country (plist-get (net-ip-parse "1.0.4.0") :value) 4)))))

(ert-deftest net-geo-test-country-binary ()
  "A packed range table answers the GeoIP lookup."
  (net-test--with-binary-file
      (net-test--packed-table
       4 0 1
       '((16777216 16777471 () ("AU"))
         (16777472 16777727 () ("CN"))))
    (let ((net-geo-database-file net-test--file)
          (net--binary-cache nil))
      (should (equal (net-geo-country (net-test--ip-number "1.0.0.5") 4)
                     "AU"))
      (should (equal (net-geo-country (net-test--ip-number "1.0.1.1") 4)
                     "CN"))
      (should-not (net-geo-country (net-test--ip-number "1.0.2.1") 4)))))

(ert-deftest net-geo-test-cache ()
  "The parsed range file is reused and cleared on request."
  (net-test--with-file
      (concat "ip_range_start,ip_range_end,country_code\n"
              "1.0.0.0,1.0.0.255,AU\n")
    (let ((net-geo-database-file net-test--file)
          (net-geo--cache nil))
      (net-geo-country (plist-get (net-ip-parse "1.0.0.1") :value) 4)
      (should (= (length net-geo--cache) 1))
      (net-geo-clear-cache)
      (should-not net-geo--cache))))

(provide 'net-geo-test)
;;; net-geo-test.el ends here
