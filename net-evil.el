;;; net-evil.el --- Evil bindings for the network modes  -*- lexical-binding: t; -*-

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
;;
;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file is optional.  It gives every `net-mode' buffer evil
;; bindings that keep the motions: j, k, gg, G, C-d, C-u, /, n and N
;; keep their meaning, and the commands of `net-mode-map' get a state
;; binding.
;;
;;   (require 'net-evil)
;;   (net-evil-mode 1)
;;
;; Evil state maps take precedence over a major mode map, so RET, q, w,
;; b, J and i would otherwise run an evil command instead of the
;; inspect command.  The bindings below put those commands back.  A
;; read-only buffer has nothing to insert, paste or change, so the
;; inspect commands win on those keys.

;;; Code:

(require 'evil)
(require 'net-mode)

(defvar net-evil-keys
  '(("RET" . push-button)
    ("q" . quit-window)
    ("gr" . revert-buffer)
    ("w" . net-copy-value)
    ("b" . net-rdap)
    ("J" . net-json-view)
    ("i" . net-inspect))
  "Keys that `net-evil-mode' binds in normal state.
Each entry is a key description and the command it runs.  The
bindings replace evil commands that do nothing in a read-only
buffer, such as insert on i and paste on p.")

(defvar net-evil-visual-keys
  '(("RET" . push-button))
  "Keys that `net-evil-mode' binds in visual state.
A narrow set, because visual state needs its text objects.  RET
follows the button at point.")

(defun net-evil--bind (state keys)
  "Bind STATE's evil keys from the KEYS list."
  (apply #'evil-define-minor-mode-key state 'net-evil-local-mode
         (mapcan (lambda (binding)
                   (list (key-parse (car binding)) (cdr binding)))
                 keys)))

(define-minor-mode net-evil-local-mode
  "Minor mode that installs the evil bindings of `net-evil-mode'.
Enable `net-evil-mode' instead of this mode."
  :group 'net
  :lighter nil)

(net-evil--bind 'normal net-evil-keys)
(net-evil--bind 'visual net-evil-visual-keys)

(defun net-evil--enable-buffer ()
  "Turn on `net-evil-local-mode' in a network inspect buffer."
  (when (derived-mode-p 'net-mode)
    (net-evil-local-mode 1)))

(defun net-evil--disable-buffer ()
  "Turn off `net-evil-local-mode' in the current buffer."
  (when (bound-and-true-p net-evil-local-mode)
    (net-evil-local-mode -1)))

;;;###autoload
(define-minor-mode net-evil-mode
  "Global minor mode that gives network inspect buffers evil bindings.
The bindings keep the evil motions and put every command of
`net-mode-map' on a state key.  Turn it off to give the buffers
back to `net-mode-map'."
  :global t
  :group 'net
  :lighter nil
  (if net-evil-mode
      (progn
        (add-hook 'after-change-major-mode-hook
                  #'net-evil--enable-buffer)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (net-evil--enable-buffer))))
    (remove-hook 'after-change-major-mode-hook
                 #'net-evil--enable-buffer)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (net-evil--disable-buffer)))))

(provide 'net-evil)
;;; net-evil.el ends here
