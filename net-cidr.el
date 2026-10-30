;;; net-cidr.el --- Inspect CIDR prefixes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, network
;; Package-Requires: ((emacs "31.1"))
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

;; `net-cidr-mode' displays one IPv4 or IPv6 prefix: the network and
;; last address, the netmask and wildcard, the host count, the reverse
;; DNS zone, and the special-purpose blocks that contain the prefix.
;;
;; The special-purpose data comes from the IANA registries that
;; `net-ip-mode' also reads:
;;
;;   iana-ipv4-special-registry-1.csv
;;   iana-ipv6-special-registry-1.csv
;;
;; The Nix package pins both files and points the options at them.
;; Without the files the mode falls back to the built-in table in
;; net-ip.el, so the privacy and documentation classifications keep
;; working offline.
;;
;; Entry points:
;;
;;   M-x net-cidr-inspect      - inspect a prefix

;;; Code:

(require 'cl-lib)
(require 'net-ip)
(require 'net-mode)
(require 'seq)

(defvaralias 'net-cidr-registry-file 'net-ip-registry-file)
(defvaralias 'net-cidr-registry-file-v6 'net-ip-registry-file-v6)

;;; Parsing

(defun net-cidr-parse (string)
  "Parse STRING as a CIDR prefix.
Return a plist with :version, :prefix, :value, :network, :last and
:bits, or nil."
  (when (and (stringp string)
             (string-match "\\`\\([^/[:space:]]+\\)/\\([0-9]+\\)\\'" (string-trim string)))
    (let* ((text (string-trim string))
           (address (match-string 1 text))
           (prefix (string-to-number (match-string 2 text)))
           (parsed (net-ip-parse address))
           (version (plist-get parsed :version))
           (bits (and version (net-ip--bits version))))
      (when (and parsed (<= 0 prefix bits))
        (let* ((host-bits (- bits prefix))
               (mask (ash (1- (ash 1 prefix)) host-bits))
               (network (logand (plist-get parsed :value) mask))
               (size (ash 1 host-bits)))
          (list :version version
                :prefix prefix
                :value (plist-get parsed :value)
                :network network
                :last (+ network (1- size))
                :bits bits))))))

(defun net-cidr-canonical (parsed)
  "Return the canonical string of the parsed prefix PARSED."
  (declare (pure t) (side-effect-free t))
  (format "%s/%d"
          (net-ip-format (plist-get parsed :network)
                         (plist-get parsed :version))
          (plist-get parsed :prefix)))

(defun net-cidr-reverse-zone (network prefix version)
  "Return the reverse DNS zone of NETWORK with PREFIX bits of VERSION.
Return nil when PREFIX is not aligned to a whole label."
  (let* ((step (if (= version 4) 8 4))
         (labels (/ prefix step)))
    (when (and (> labels 0) (zerop (% prefix step)))
      (let* ((full (net-ip-reverse-dns network version))
             ;; Drop the "in-addr.arpa" or "ip6.arpa" tail; the zone
             ;; uses the most significant labels, which sit at the end of
             ;; the reversed list of nibbles or octets.
             (core (butlast (split-string full "\\.") 2))
             (zone (last core labels)))
        (concat (mapconcat #'identity zone ".")
                (if (= version 4) ".in-addr.arpa" ".ip6.arpa"))))))

;;; Registry

(defun net-cidr-registry-entries (version)
  "Return the special-purpose registry entries of VERSION.
Return nil when the matching CSV file is not available."
  (net-ip-registry-entries version))

(defun net-cidr-matching-entries (parsed)
  "Return the registry entries that contain the prefix PARSED.
Use the IANA CSV when it exists and the built-in table otherwise.
The narrowest entry comes first."
  (net-ip-matching-blocks (plist-get parsed :network)
                          (plist-get parsed :version)
                          (plist-get parsed :last)))

;;; Display

(defun net-cidr--insert-address-section (parsed)
  "Insert the address fields of PARSED."
  (net-insert-heading "Prefix")
  (let* ((version (plist-get parsed :version))
         (prefix (plist-get parsed :prefix))
         (bits (plist-get parsed :bits))
         (host-bits (- bits prefix))
         (network (plist-get parsed :network))
         (last (plist-get parsed :last))
         (total (ash 1 host-bits))
         (mask (ash (1- (ash 1 prefix)) host-bits)))
    (net-insert-field "Prefix" (net-cidr-canonical parsed))
    (net-insert-field "Version" (format "IPv%d" version))
    (net-insert-link "Network address" 'ip (net-ip-format network version))
    (net-insert-link "Last address" 'ip (net-ip-format last version))
    (net-insert-field "Netmask"
                      (if (= version 4)
                          (net-ip-format mask 4)
                        (net-ip--format-ipv6-full mask)))
    (when (= version 4)
      (net-insert-field "Wildcard"
                        (net-ip-format (logand (lognot mask) #xffffffff) 4)))
    (net-insert-field "Host bits" host-bits)
    (net-insert-field "Total addresses" total)
    (net-insert-field "Usable hosts"
                      (if (= version 4)
                          (cond ((<= prefix 30) (- total 2))
                                ((= prefix 31) 2)
                                (t 1))
                        total))
    (when (and (= version 4) (<= prefix 30))
      (net-insert-field "Broadcast address" (net-ip-format last 4)))))

(defun net-cidr--insert-classification-section (parsed)
  "Insert the special-purpose classification of PARSED."
  (let* ((version (plist-get parsed :version))
         (matches (net-cidr-matching-entries parsed))
         (csv (net-cidr-registry-entries version)))
    (net-insert-heading "Classification")
    (if (null matches)
        (net-insert-field "Registry" "Global unicast (no special-purpose block)")
      (let ((best (car matches)))
        (net-insert-field "Registry" (plist-get best :name))
        (net-insert-field "Reference" (plist-get best :rfc))
        (when (plist-get best :source)
          (net-insert-field "Valid source" (plist-get best :source))
          (net-insert-field "Valid destination" (plist-get best :destination))
          (net-insert-field "Forwardable" (plist-get best :forwardable))
          (net-insert-field "Globally reachable" (plist-get best :global)))))
    (net-insert-field "Private"
                      (if (net-ip-private-range-p
                           (plist-get parsed :network)
                           (plist-get parsed :last)
                           version)
                          (if (= version 4) "yes (RFC 1918)" "yes (RFC 4193)")
                        "no"))
    (net-insert-text "Data source"
                     (if csv "IANA special-purpose registry CSV"
                       "built-in table (set `net-ip-registry-file' for IANA data)"))
    (when (> (length matches) 1)
      (net-insert-heading "Containing Blocks")
      (dolist (entry matches)
        (net-insert-link (or (plist-get entry :name)
                             (plist-get entry :cidr))
                         'cidr
                         (plist-get entry :cidr))))))

(defun net-cidr--insert-related-section (parsed)
  "Insert the related prefixes of PARSED."
  (let* ((version (plist-get parsed :version))
         (prefix (plist-get parsed :prefix))
         (bits (plist-get parsed :bits))
         (network (plist-get parsed :network))
         (zone (net-cidr-reverse-zone network prefix version))
         (items nil))
    (when (> prefix 0)
      (push (cons (format "Parent /%d" (1- prefix))
                  (cons 'cidr
                        (format "%s/%d" (net-ip-format network version)
                                (1- prefix))))
            items))
    (when (< prefix bits)
      (let ((child-size (ash 1 (1- (- bits prefix)))))
        (push (cons (format "Lower /%d" (1+ prefix))
                    (cons 'cidr
                          (format "%s/%d" (net-ip-format network version)
                                  (1+ prefix))))
              items)
        (push (cons (format "Upper /%d" (1+ prefix))
                    (cons 'cidr
                          (format "%s/%d"
                                  (net-ip-format (+ network child-size) version)
                                  (1+ prefix))))
              items)))
    (when items
      (net-insert-heading "Related")
      (dolist (item (nreverse items))
        (net-insert-link (car item) (cadr item) (cddr item))))
    (net-insert-heading "Reverse DNS")
    (net-insert-field "Zone" (or zone "not aligned to a label boundary"))))

(defun net-cidr--display ()
  "Render the CIDR prefix in the current buffer."
  (let* ((parsed (net-cidr-parse net--value))
         (matches (net-cidr-matching-entries parsed))
         (best (car matches)))
    (net-set-summary (format "IPv%d, %s"
                             (plist-get parsed :version)
                             (if best (plist-get best :name) "global unicast")))
    (net-cidr--insert-address-section parsed)
    (net-cidr--insert-classification-section parsed)
    (net-cidr--insert-related-section parsed)
    (setq-local net--rdap-type "ip"
                net--rdap-key (net-ip-format (plist-get parsed :network)
                                             (plist-get parsed :version)))))

;;; Mode and entry points

(define-derived-mode net-cidr-mode net-mode "Net CIDR"
  "Major mode for inspecting one CIDR prefix.
\\{net-mode-map}")

;;;###autoload
(defun net-cidr-inspect (prefix)
  "Inspect the CIDR PREFIX in a `net-cidr-mode' buffer."
  (interactive
   (list (or (when-let* ((bounds (bounds-of-thing-at-point 'net-cidr)))
               (buffer-substring-no-properties (car bounds) (cdr bounds)))
             (read-string "CIDR prefix: "))))
  (let ((parsed (net-cidr-parse prefix)))
    (unless parsed
      (user-error "Not a CIDR prefix: %s" prefix))
    (net-display 'cidr (net-cidr-canonical parsed)
                 #'net-cidr-mode #'net-cidr--display)))

(defun net-cidr--sniff (string)
  "Return the canonical form of STRING when it is a CIDR prefix."
  (when (and (stringp string) (string-match-p "/" string))
    (when-let* ((parsed (net-cidr-parse string)))
      (net-cidr-canonical parsed))))

(net-register-kind 'cidr
                   '(:label "CIDR"
                     :open net-cidr-inspect
                     :sniff net-cidr--sniff
                     :priority 60))

(put 'net-cidr 'bounds-of-thing-at-point
     (lambda ()
       (net--thing-bounds "0-9A-Fa-f:./" #'net-cidr-parse)))
(put 'net-cidr 'thing-at-point
     (lambda ()
       (when-let* ((bounds (bounds-of-thing-at-point 'net-cidr)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(provide 'net-cidr)
;;; net-cidr.el ends here
