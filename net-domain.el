;;; net-domain.el --- Inspect domain names  -*- lexical-binding: t; -*-

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

;; `net-domain-mode' displays one domain name: its labels, the ASCII
;; (Punycode) form of internationalized labels, the public suffix that
;; the Public Suffix List reports, and the registrable domain.
;;
;; Two optional data sources add detail:
;;
;;   net-domain-psl-file   the Public Suffix List
;;
;; Download the list from https://publicsuffix.org/list/public_suffix_list.dat
;; or let the Nix package point the option at the nixpkgs copy.  Without
;; it the mode still describes the labels and the TLD.
;;
;; The Punycode encoder is local.  Emacs does not bundle `punycode.el'
;; by default, and the IDNA normalization step only lowercases, so a
;; label with compatibility characters can differ from a full IDNA
;; implementation.  The mode says so in the buffer when that applies.
;;
;; Entry points:
;;
;;   M-x net-domain-inspect      - inspect a domain name

;;; Code:

(require 'cl-lib)
(require 'net-mode)
(require 'seq)

(defcustom net-domain-psl-file (net-data-file "public_suffix_list.dat")
  "Public Suffix List file, or nil.
Download it from https://publicsuffix.org/list/public_suffix_list.dat.
The Nix package points this option at the nixpkgs copy."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defvar net-domain--psl-cache nil
  "Alist of (FILE MTIME SIZE . DATA) for parsed Public Suffix Lists.")

;;; Punycode

(defun net-domain--punycode-digit (digit)
  "Return the Punycode character of DIGIT."
  (declare (pure t) (side-effect-free t))
  (if (< digit 26)
      (+ digit ?a)
    (+ (- digit 26) ?0)))

(defun net-domain--punycode-adapt (delta numpoints first)
  "Return the adapted bias for DELTA, NUMPOINTS and FIRST."
  (declare (pure t) (side-effect-free t))
  (setq delta (if first (/ delta 700) (/ delta 2)))
  (setq delta (+ delta (/ delta numpoints)))
  (let ((k 0))
    (while (> delta 455)
      (setq delta (/ delta 35)
            k (+ k 36)))
    (+ k (/ (* 36 delta) (+ delta 38)))))

(defun net-domain--punycode-encode (string)
  "Return the Punycode encoding of STRING without the xn-- prefix.
This implements RFC 3492.  The caller adds the prefix."
  (declare (pure t) (side-effect-free t))
  (let* ((chars (string-to-list string))
         (length (length chars))
         (basic (cl-remove-if-not (lambda (char) (< char 128)) chars))
         (output (mapconcat #'char-to-string basic ""))
         (handled (length basic))
         (n 128)
         (delta 0)
         (bias 72)
         (h handled))
    (when (and (> handled 0) (< handled length))
      (setq output (concat output "-")))
    (while (< h length)
      (let ((m (cl-reduce #'min
                          (cl-remove-if-not (lambda (char) (>= char n)) chars))))
        (setq delta (+ delta (* (- m n) (1+ h)))
              n m)
        (dolist (char chars)
          (cond
           ((< char n)
            (cl-incf delta))
           ((= char n)
            (let ((q delta)
                  (k 36))
              (catch 'digit-done
                (while t
                  (let ((threshold (cond ((<= k bias) 1)
                                         ((>= k (+ bias 26)) 26)
                                         (t (- k bias)))))
                    (when (< q threshold)
                      (throw 'digit-done nil))
                    (setq output
                          (concat output
                                  (char-to-string
                                   (net-domain--punycode-digit
                                    (+ threshold (% (- q threshold)
                                                    (- 36 threshold)))))))
                    (setq q (/ (- q threshold) (- 36 threshold))
                          k (+ k 36)))))
              (setq output (concat output
                                  (char-to-string
                                   (net-domain--punycode-digit q))))
              (setq bias (net-domain--punycode-adapt delta (1+ h) (= h handled))
                    delta 0
                    h (1+ h))))))
        (setq delta (1+ delta)
              n (1+ n))))
    output))

(defun net-domain-punycode-label (label)
  "Return the ASCII form of LABEL.
ASCII labels come back unchanged.  Other labels get the xn-- prefix."
  (if (string-match-p "\\`[[:ascii:]]+\\'" label)
      label
    (concat "xn--" (net-domain--punycode-encode label))))

;;; Parsing

(defun net-domain-parse (string)
  "Parse STRING as a domain name.
Return a plist with :labels, :text, :trailing-dot and :unicode, or nil."
  (when (and (stringp string) (not (string-empty-p (string-trim string))))
    (let* ((input (string-trim string))
           (trailing (string-suffix-p "." input))
           (text (string-trim-right input "[.]"))
           (labels (split-string text "\\.")))
      (when (and (not (string-empty-p text))
                 (cl-every (lambda (label)
                             (and (<= 1 (length label) 63)
                                  (string-match-p "\\`[[:alnum:]_-]+\\'" label)
                                  (not (string-prefix-p "-" label))
                                  (not (string-suffix-p "-" label))))
                           labels)
                 (<= (length text) 253))
        (list :labels labels
              :text text
              :trailing-dot trailing
              :unicode (string-match-p "[^[:ascii:]]" text))))))

(defun net-domain-ascii (parsed)
  "Return the ASCII (Punycode) form of the parsed domain PARSED."
  (declare (pure t) (side-effect-free t))
  (mapconcat #'net-domain-punycode-label
             (plist-get parsed :labels)
             "."))

(defun net-domain-canonical (parsed)
  "Return the canonical lowercase form of the parsed domain PARSED.
Internationalized labels stay in their Unicode form; the ASCII form
is a separate field."
  (declare (pure t) (side-effect-free t))
  (downcase (plist-get parsed :text)))

;;; Public Suffix List

(defun net-domain--psl-punycode (rule)
  "Return the Punycode alias of the PSL RULE, or nil for an ASCII rule.
The Public Suffix List writes IDN rules in Unicode, but the lookup
uses the Punycode form of the name, so the loader adds this alias."
  (let* ((bang (and (string-prefix-p "!" rule) "!"))
         (body (if bang (substring rule 1) rule))
         (ascii (mapconcat (lambda (label)
                             (if (string-prefix-p "*" label)
                                 label
                               (net-domain-punycode-label
                                (downcase label))))
                           (split-string body "\\.")
                           "."))
         (text (concat bang ascii)))
    (unless (equal text rule)
      text)))

(defun net-domain--psl-load (file)
  "Parse the Public Suffix List FILE.
Return a plist with :icann and :private hash tables.  Each hash value
is the section symbol `icann' or `private'."
  (let* ((attributes (file-attributes file))
         (key (list file
                    (file-attribute-modification-time attributes)
                    (file-attribute-size attributes)))
         (cached (assoc key net-domain--psl-cache)))
    (if cached
        (cdr cached)
      (let ((icann (make-hash-table :test #'equal :size 10000))
            (private (make-hash-table :test #'equal :size 2000))
            (section nil))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (not (eobp))
            (let ((line (string-trim
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))))
              (cond
               ((string-match-p "BEGIN ICANN DOMAINS" line)
                (setq section 'icann))
               ((string-match-p "BEGIN PRIVATE DOMAINS" line)
                (setq section 'private))
               ((or (string-empty-p line) (string-prefix-p "//" line))
                nil)
               (section
                (let ((table (if (eq section 'icann) icann private))
                      (rule (downcase line)))
                  (puthash rule section table)
                  (when-let* ((alias (net-domain--psl-punycode rule)))
                    (unless (gethash alias table)
                      (puthash alias section table))))))
            (forward-line 1)))
        (let ((data (list :icann icann :private private)))
          (setq net-domain--psl-cache
                (cons (cons key data) net-domain--psl-cache))
          data))))))

(defun net-domain--psl-match (labels tables)
  "Find the public suffix of LABELS in the PSL TABLES.
LABELS is a list with the rightmost label first.  Return
\(SUFFIX-LENGTH . SECTION) or nil when no rule matches."
  (declare (pure t) (side-effect-free t))
  (let* ((count (length labels))
         (icann (plist-get tables :icann))
         (private (plist-get tables :private))
         (suffix (lambda (size)
                   (mapconcat #'identity
                              (reverse (seq-take labels size))
                              ".")))
         (lookup (lambda (rule)
                   (or (gethash rule icann)
                       (gethash rule private))))
         (exception nil)
         (exception-section nil)
         (size count))
    ;; Exception rules win and shorten the suffix by one label.
    (while (and (>= size 2) (not exception))
      (let ((section (funcall lookup (concat "!" (funcall suffix size)))))
        (when section
          (setq exception (1- size)
                exception-section section)))
      (cl-decf size))
    (if exception
        (cons exception exception-section)
      (let ((best 1)
            (section nil)
            (size 1))
        (while (<= size count)
          (when-let* ((found (funcall lookup (funcall suffix size))))
            (setq best size
                  section found))
          (when (>= size 2)
            (when-let* ((found (funcall lookup
                                        (concat "*."
                                                (funcall suffix (1- size))))))
              (setq best size
                    section found)))
          (cl-incf size))
        (cons best section)))))

(defun net-domain-public-suffix (parsed)
  "Return (SUFFIX-LENGTH . TABLE) of the parsed domain PARSED.
Return nil when the Public Suffix List is not available.  The list
keeps IDN rules in Unicode and the lookup uses the Punycode form of
the name, so the loader adds a Punycode alias for every IDN rule."
  (when (net-data-available-p net-domain-psl-file)
    (let* ((tables (net-domain--psl-load net-domain-psl-file))
           (labels (reverse (split-string (downcase (net-domain-ascii parsed))
                                          "\\."))))
      (net-domain--psl-match labels tables))))

;;; Report

(defun net-domain--hostname-p (labels)
  "Return non-nil when LABELS form a valid hostname.
RFC 1123 forbids underscores.  Leading and trailing hyphens are
rejected during parsing."
  (cl-every (lambda (label)
              (not (string-match-p "_" label)))
            labels))

(defun net-domain--psl-fields (parsed)
  "Return the Public Suffix List fields of PARSED as a plist.
Return nil when the list file is not available.  The plist holds
`:suffix', `:labels', `:section' and `:registrable'."
  (when (net-data-available-p net-domain-psl-file)
    (let* ((labels (plist-get parsed :labels))
           (count (length labels))
           (match (net-domain-public-suffix parsed))
           (length (if match (car match) 1))
           (table (cdr match))
           (suffix (mapconcat #'identity (last labels length) "."))
           (registrable (when (< length count)
                          (mapconcat #'identity
                                     (last labels (1+ length))
                                     "."))))
      (list :suffix suffix
            :labels length
            :section (cond ((eq table 'private) "private")
                           ((eq table 'icann) "ICANN")
                           (t "default rule (no match)"))
            :registrable registrable))))

(defun net-domain--report-name-section (parsed ascii)
  "Return the name section of PARSED with ASCII form ASCII."
  (let* ((labels (plist-get parsed :labels))
         (text (plist-get parsed :text))
         (hostname (net-domain--hostname-p labels)))
    (list :json :name
          :heading "Domain"
          :items (delq nil
                       (list '(:field "Domain" :domain)
                             (unless (string= (downcase text) ascii)
                               '(:field "ASCII" :ascii))
                             '(:field "Labels" :labelCount)
                             '(:field "Length (octets)" :octets)
                             '(:field "Fully qualified" :fullyQualified
                                      :fullyQualifiedText)
                             '(:field "TLD" :tld)
                             '(:field "Hostname" :hostname :hostnameText)
                             (when (plist-get parsed :unicode)
                               '(:text "Note" :note))))
          :domain text
          :ascii (unless (string= (downcase text) ascii) ascii)
          :labelCount (length labels)
          :octets (length ascii)
          :fullyQualified (if (plist-get parsed :trailing-dot)
                              t
                            :json-false)
          :fullyQualifiedText (if (plist-get parsed :trailing-dot)
                                  "yes"
                                "no")
          :tld (car (last labels))
          :hostname (if hostname t :json-false)
          :hostnameText (if hostname "valid" "invalid")
          :note (when (plist-get parsed :unicode)
                  "IDNA normalization is limited to lowercasing."))))

(defun net-domain--report-label-section (parsed)
  "Return the label table section of PARSED."
  (let ((labels (plist-get parsed :labels))
        (index 0)
        (records nil))
    (dolist (label labels)
      (let* ((ascii (net-domain-punycode-label (downcase label)))
             (same (string= ascii (downcase label))))
        (push (list :items
                    (list (list :field (format "%d. %s" index label)
                                (format "%d octets%s"
                                        (length ascii)
                                        (if same
                                            ""
                                          (format ", ASCII %s" ascii)))))
                    :json (list :label label
                                :octets (length ascii)
                                :punycode (unless same ascii)))
              records))
      (cl-incf index))
    (list :json :labels
          :heading "Labels"
          :records (nreverse records))))

(defun net-domain--report-psl-section (parsed)
  "Return the Public Suffix List section of PARSED."
  (let ((fields (net-domain--psl-fields parsed)))
    (if (null fields)
        (list :json :publicSuffix
              :heading "Public Suffix"
              :items (list '(:text "List" :list))
              :list "unset (customize `net-domain-psl-file')")
      (let ((registrable (plist-get fields :registrable)))
        (list :json :publicSuffix
              :heading "Public Suffix"
              :items (list '(:field "Suffix" :suffix)
                           '(:field "Suffix labels" :suffixLabels)
                           '(:field "Section" :section)
                           (if registrable
                               '(:link "Registrable domain" domain
                                       :registrable)
                             '(:field "Registrable domain" :registrable
                                      :registrableText))
                           '(:text "List" :source :sourceFile))
              :suffix (plist-get fields :suffix)
              :suffixLabels (plist-get fields :labels)
              :section (plist-get fields :section)
              :registrable registrable
              :source (net-data-description net-domain-psl-file)
              :sourceFile net-domain-psl-file
              :registrableText (unless registrable
                                 "the name is itself a public suffix"))))))

(defun net-domain-report (domain)
  "Return the report of the DOMAIN name.
The report holds the fields that the buffer shows and the RDAP
identity of the name."
  (let* ((parsed (net-domain-parse domain))
         (text (plist-get parsed :text))
         (ascii (net-domain-ascii parsed))
         (fields (net-domain--psl-fields parsed))
         (registrable (plist-get fields :registrable)))
    (list
     :summary (when fields
                (if registrable
                    (format "suffix %s, registrable %s"
                            (plist-get fields :suffix) registrable)
                  (format "suffix %s" (plist-get fields :suffix))))
     :rdap-type "domain"
     :rdap-key ascii
     :rdap (append (list :objectClassName "domain" :ldhName ascii)
                   (unless (string= (downcase text) ascii)
                     (list :unicodeName text)))
     :sections
     (delq nil
           (list (net-domain--report-name-section parsed ascii)
                 (net-domain--report-label-section parsed)
                 (net-domain--report-psl-section parsed))))))

(defun net-domain--display ()
  "Render the domain name in the current buffer."
  (net--render-report (net-domain-report net--value)))

;;; Mode and entry points

(define-derived-mode net-domain-mode net-mode "Net Domain"
  "Major mode for inspecting one domain name.
\\{net-mode-map}"
  :interactive nil)

;;;###autoload
(defun net-domain-inspect (domain)
  "Inspect the DOMAIN name in a `net-domain-mode' buffer."
  (interactive
   (list (or (when-let* ((bounds (bounds-of-thing-at-point 'net-domain)))
               (buffer-substring-no-properties (car bounds) (cdr bounds)))
             (read-string "Domain: "))))
  (let ((parsed (net-domain-parse domain)))
    (unless parsed
      (user-error "Not a domain name: %s" domain))
    (net-display 'domain (net-domain-canonical parsed)
                 #'net-domain-mode #'net-domain--display)))

(defun net-domain--sniff (string)
  "Return the canonical form of STRING when it is a domain name."
  (when (and (stringp string)
             (string-match-p "\\." string)
             (not (string-match-p "[:/]" string))
             (not (string-match-p "\\`[0-9.]+\\'" string)))
    (when-let* ((parsed (net-domain-parse string)))
      (net-domain-canonical parsed))))

(net-register-kind 'domain
                   '(:label "Domain"
                     :open net-domain-inspect
                     :report net-domain-report
                     :sniff net-domain--sniff
                     :priority 10))

(put 'net-domain 'bounds-of-thing-at-point
     (lambda ()
       (net--thing-bounds "0-9A-Za-z._-" #'net-domain-parse)))
(put 'net-domain 'thing-at-point
     (lambda ()
       (when-let* ((bounds (bounds-of-thing-at-point 'net-domain)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(provide 'net-domain)
;;; net-domain.el ends here
