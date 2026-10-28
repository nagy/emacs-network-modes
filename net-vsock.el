;;; net-vsock.el --- Inspect AF_VSOCK addresses  -*- lexical-binding: t; -*-

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

;; `net-vsock-mode' displays one AF_VSOCK address: the context ID
;; (CID) and port of `struct sockaddr_vm', the meaning of the reserved
;; CIDs, the byte layout of the structure, and the IANA services that
;; use the same port number on TCP or UDP.
;;
;; The address syntax is CID:PORT, with decimal or 0x hexadecimal
;; numbers.  The vsock:// scheme prefix is accepted.  CIDs 0, 1 and 2
;; name the hypervisor, the local endpoint and the host; 0xFFFFFFFF
;; means any CID.
;;
;; Entry points:
;;
;;   M-x net-vsock-inspect      - inspect a vsock address

;;; Code:

(require 'cl-lib)
(require 'net-mode)

(defcustom net-vsock-service-file (net-data-file "service-names-port-numbers.csv")
  "IANA service names and port numbers CSV file, or nil.
Download it from https://www.iana.org/assignments/service-names-port-numbers/
The mode uses it only for information: AF_VSOCK ports are not assigned
by IANA."
  :type '(choice (const :tag "None" nil) file)
  :group 'net)

(defconst net-vsock--cid-names
  '((0 . "VMADDR_CID_HYPERVISOR")
    (1 . "VMADDR_CID_LOCAL (loopback)")
    (2 . "VMADDR_CID_HOST (the host)")
    (4294967295 . "VMADDR_CID_ANY (any context ID)"))
  "Names of the reserved context IDs from linux/vm_sockets.h.")

(defconst net-vsock--structure
  "offset  size  field
0       2     svm_family     (AF_VSOCK = 40)
2       2     svm_reserved1
4       4     svm_port
8       4     svm_cid
12      1     svm_flags      (VMADDR_FLAG_TO_HOST = 0x01)
13      3     svm_zero
16            total size, same as struct sockaddr"
  "Byte layout of struct sockaddr_vm on Linux.")

(defvar net-vsock--service-cache nil
  "Alist of (FILE MTIME SIZE . ROWS) for parsed service registries.")

;;; Parsing

(defun net-vsock--parse-number (string)
  "Parse STRING as a decimal or 0x hexadecimal number.
Return nil when STRING is not a valid 32-bit number."
  (when (string-match "\\`\\(0[xX]\\)?\\([0-9A-Fa-f]+\\)\\'" string)
    (let* ((hexadecimal (match-beginning 1))
           (digits (match-string 2 string))
           (number (string-to-number digits (if hexadecimal 16 10))))
      (when (and (<= 0 number 4294967295)
                 (or hexadecimal (string-match-p "\\`[0-9]+\\'" digits)))
        number))))

(defun net-vsock-parse (string)
  "Parse STRING as a vsock address.
Return a plist with :cid and :port, or nil.  Accept CID:PORT and
vsock://CID:PORT with decimal or hexadecimal numbers."
  (when (and (stringp string) (not (string-empty-p (string-trim string))))
    (let* ((text (string-trim string))
           (text (if (string-match "\\`[Vv][Ss][Oo][Cc][Kk]://" text)
                     (substring text (match-end 0))
                   text)))
      (when (string-match "\\`\\([^:]+\\):\\([^:]+\\)\\'" text)
        (let* ((cid-text (match-string 1 text))
               (port-text (match-string 2 text))
               (cid (net-vsock--parse-number cid-text))
               (port (net-vsock--parse-number port-text)))
          (when (and cid port)
            (list :cid cid :port port)))))))

(defun net-vsock-canonical (parsed)
  "Return the canonical string of the parsed vsock address PARSED."
  (format "%d:%d" (plist-get parsed :cid) (plist-get parsed :port)))

;;; Services

(defun net-vsock--services (port)
  "Return the IANA service rows for PORT, or nil."
  (when (net-data-available-p net-vsock-service-file)
    (let* ((attributes (file-attributes net-vsock-service-file))
           (key (list net-vsock-service-file
                      (file-attribute-modification-time attributes)
                      (file-attribute-size attributes)))
           (cached (assoc key net-vsock--service-cache)))
      (unless cached
        (let ((rows nil))
          (dolist (record (cdr (net--read-csv-file net-vsock-service-file)))
            (when (>= (length record) 4)
              (push (list :name (nth 0 record)
                          :port (nth 1 record)
                          :transport (nth 2 record)
                          :description (nth 3 record))
                    rows)))
          (setq cached (cons key (nreverse rows)))
          (setq net-vsock--service-cache (cons cached net-vsock--service-cache))))
      (cl-remove-if-not
       (lambda (row)
         (let ((spec (plist-get row :port)))
           (cond
            ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" spec)
             (<= (string-to-number (match-string 1 spec))
                 port
                 (string-to-number (match-string 2 spec))))
            ((string-match "\\`[0-9]+\\'" spec)
             (= (string-to-number spec) port)))))
       (cdr cached)))))

;;; Display

(defun net-vsock--insert-address-section (parsed)
  "Insert the fields of PARSED."
  (net-insert-heading "VSOCK")
  (let ((cid (plist-get parsed :cid))
        (port (plist-get parsed :port)))
    (net-insert-field "Address" (net-vsock-canonical parsed))
    (net-insert-field "CID" cid)
    (net-insert-field "CID (hex)" (format "0x%x" cid))
    (net-insert-field "CID meaning" (alist-get cid net-vsock--cid-names))
    (net-insert-field "Port" port)
    (net-insert-field "Port (hex)" (format "0x%x" port))
    (net-insert-field "Port meaning"
                      (if (= port 4294967295)
                          "VMADDR_PORT_ANY"
                        "not VMADDR_PORT_ANY"))))

(defun net-vsock--insert-services-section (parsed)
  "Insert the IANA service rows that share the port of PARSED."
  (when (net-data-available-p net-vsock-service-file)
    (let ((rows (net-vsock--services (plist-get parsed :port))))
      (net-insert-heading "IANA Service Names")
      (if (null rows)
          (net-insert-field "Service" "none with this number")
        (dolist (row rows)
          (net-insert-field (format "%s/%s"
                                    (or (plist-get row :name) "unnamed")
                                    (or (plist-get row :transport) "?"))
                            (plist-get row :description))))
      (net-insert-text "Note"
                       "AF_VSOCK ports are not assigned by IANA; this is informational."))))

(defun net-vsock--insert-structure-section ()
  "Insert the sockaddr_vm byte layout."
  (net-insert-heading "sockaddr_vm")
  (net-insert-text "Layout" net-vsock--structure))

(defun net-vsock--display ()
  "Render the vsock address in the current buffer."
  (let* ((parsed (net-vsock-parse net--value))
         (cid (plist-get parsed :cid)))
    (net-set-summary (format "VSOCK %s"
                             (or (alist-get cid net-vsock--cid-names)
                                 (format "CID %d" cid))))
    (net-vsock--insert-address-section parsed)
    (net-vsock--insert-services-section parsed)
    (net-vsock--insert-structure-section)))

;;; Mode and entry points

(define-derived-mode net-vsock-mode net-mode "Net VSOCK"
  "Major mode for inspecting one AF_VSOCK address.
\\{net-mode-map}")

;;;###autoload
(defun net-vsock-inspect (address)
  "Inspect the vsock ADDRESS in a `net-vsock-mode' buffer."
  (interactive
   (list (or (when-let* ((bounds (bounds-of-thing-at-point 'net-vsock)))
               (buffer-substring-no-properties (car bounds) (cdr bounds)))
             (read-string "vsock address (CID:PORT): "))))
  (let ((parsed (net-vsock-parse address)))
    (unless parsed
      (user-error "Not a vsock address: %s" address))
    (net-display 'vsock (net-vsock-canonical parsed)
                 #'net-vsock-mode #'net-vsock--display)))

(defun net-vsock--sniff (string)
  "Return the canonical form of STRING when it is a vsock address."
  (when (and (stringp string)
             (string-match-p ":" string))
    (when-let* ((parsed (net-vsock-parse string)))
      (net-vsock-canonical parsed))))

(net-register-kind 'vsock
                   '(:label "VSOCK"
                     :open net-vsock-inspect
                     :sniff net-vsock--sniff
                     :priority 50))

(put 'net-vsock 'bounds-of-thing-at-point
     (lambda ()
       (net--thing-bounds "0-9A-Za-z:/-" #'net-vsock-parse)))
(put 'net-vsock 'thing-at-point
     (lambda ()
       (when-let* ((bounds (bounds-of-thing-at-point 'net-vsock)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(provide 'net-vsock)
;;; net-vsock.el ends here
