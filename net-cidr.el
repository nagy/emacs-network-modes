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

;;; Report

(defun net-cidr-report (prefix)
  "Return the report of the CIDR PREFIX.
The report holds the fields that the buffer shows and the RDAP
identity of the prefix.  `net--render-report' renders it, and
`net-json-view' encodes it."
  (let* ((parsed (net-cidr-parse prefix))
         (version (plist-get parsed :version))
         (length (plist-get parsed :prefix))
         (bits (plist-get parsed :bits))
         (network (plist-get parsed :network))
         (last (plist-get parsed :last))
         (host-bits (- bits length))
         (total (ash 1 host-bits))
         (mask (ash (1- (ash 1 length)) host-bits))
         (matches (net-cidr-matching-entries parsed))
         (best (car matches))
         (csv (net-cidr-registry-entries version))
         (private (net-ip-private-range-p network last version))
         (network-text (net-ip-format network version))
         (last-text (net-ip-format last version))
         (zone (net-cidr-reverse-zone network length version))
         (broadcast (and (= version 4) (<= length 30)))
         (related nil))
    (when (> length 0)
      (push (list :items
                  (list (list :link (format "Parent /%d" (1- length))
                              'cidr
                              (format "%s/%d" network-text (1- length))))
                  :json (list :role "parent"
                              :prefix (format "%s/%d" network-text
                                              (1- length))))
            related))
    (when (< length bits)
      (let ((child-size (ash 1 (1- (- bits length)))))
        (push (list :items
                    (list (list :link (format "Lower /%d" (1+ length))
                                'cidr
                                (format "%s/%d" network-text (1+ length))))
                    :json (list :role "lower"
                                :prefix (format "%s/%d" network-text
                                                (1+ length))))
              related)
        (push (list :items
                    (list (list :link (format "Upper /%d" (1+ length))
                                'cidr
                                (format "%s/%d"
                                        (net-ip-format (+ network child-size)
                                                       version)
                                        (1+ length))))
                    :json (list :role "upper"
                                :prefix (format "%s/%d"
                                                (net-ip-format
                                                 (+ network child-size)
                                                 version)
                                                (1+ length))))
              related)))
    (list
     :summary (format "IPv%d, %s" version
                      (if best (plist-get best :name) "global unicast"))
     :rdap-type "ip"
     :rdap-key network-text
     :rdap (list :objectClassName "ip network"
                 :ipVersion (format "v%d" version)
                 :startAddress network-text
                 :endAddress last-text)
     :sections
     (delq nil
           (list
            (list :json :prefix :heading "Prefix"
                  :items (delq nil
                               (list '(:field "Prefix" :cidr)
                                     '(:field "Version" :version)
                                     '(:link "Network address" ip
                                             :networkAddress)
                                     '(:link "Last address" ip :lastAddress)
                                     '(:field "Netmask" :netmask)
                                     (when (= version 4)
                                       '(:field "Wildcard" :wildcard))
                                     '(:field "Host bits" :hostBits)
                                     '(:field "Total addresses"
                                              :totalAddresses)
                                     '(:field "Usable hosts" :usableHosts)
                                     (when broadcast
                                       '(:field "Broadcast address"
                                                :broadcastAddress))))
                  :cidr (net-cidr-canonical parsed)
                  :version (format "IPv%d" version)
                  :networkAddress network-text
                  :lastAddress last-text
                  :netmask (if (= version 4)
                               (net-ip-format mask 4)
                             (net-ip--format-ipv6-full mask))
                  :wildcard (when (= version 4)
                              (net-ip-format
                               (logand (lognot mask) #xffffffff) 4))
                  :hostBits host-bits
                  :totalAddresses total
                  :usableHosts (if (= version 4)
                                   (cond ((<= length 30) (- total 2))
                                         ((= length 31) 2)
                                         (t 1))
                                 total)
                  :broadcastAddress (when broadcast last-text))
            (list :json :classification :heading "Classification"
                  :items
                  (append
                   (if (null matches)
                       (list '(:field "Registry" :name))
                     (append
                      (list '(:field "Registry" :name)
                            '(:field "Reference" :rfc))
                      (when (plist-get best :source)
                        (list '(:field "Valid source" :validSource
                                       :validSourceText)
                              '(:field "Valid destination" :validDestination
                                       :validDestinationText)
                              '(:field "Forwardable" :forwardable
                                       :forwardableText)
                              '(:field "Globally reachable" :globallyReachable
                                       :globallyReachableText)))))
                   (list '(:field "Private" :private :privateText)
                         '(:text "Data source" :source)))
                  :name (if best
                            (plist-get best :name)
                          "Global unicast (no special-purpose block)")
                  :rfc (when best (plist-get best :rfc))
                  :validSource (when best (net--flag (plist-get best :source)))
                  :validSourceText (when best (plist-get best :source))
                  :validDestination (when best
                                      (net--flag
                                       (plist-get best :destination)))
                  :validDestinationText (when best
                                          (plist-get best :destination))
                  :forwardable (when best
                                 (net--flag (plist-get best :forwardable)))
                  :forwardableText (when best (plist-get best :forwardable))
                  :globallyReachable (when best
                                       (net--flag (plist-get best :global)))
                  :globallyReachableText (when best (plist-get best :global))
                  :private (if private t :json-false)
                  :privateText (if private
                                   (if (= version 4)
                                       "yes (RFC 1918)"
                                     "yes (RFC 4193)")
                                 "no")
                  :source (if csv
                              "IANA special-purpose registry CSV"
                            (concat "built-in table (set "
                                    "`net-ip-registry-file' for IANA data)")))
            (when (> (length matches) 1)
              (list :json :containingBlocks :heading "Containing Blocks"
                    :records
                    (mapcar (lambda (entry)
                              (list :items
                                    (list (list :link
                                                (or (plist-get entry :name)
                                                    (plist-get entry :cidr))
                                                'cidr
                                                (plist-get entry :cidr)))
                                    :json (list :name
                                                (plist-get entry :name)
                                                :cidr
                                                (plist-get entry :cidr))))
                            matches)))
            (when related
              (list :json :related :heading "Related"
                    :records (nreverse related)))
            (list :json :reverseDns :heading "Reverse DNS"
                  :items (list '(:field "Zone" :zone :zoneText))
                  :zone zone
                  :zoneText (or zone "not aligned to a label boundary")))))))

(defun net-cidr--display ()
  "Render the CIDR prefix in the current buffer."
  (net--render-report (net-cidr-report net--value)))

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
