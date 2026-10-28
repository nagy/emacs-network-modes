;;; network-modes.el --- Load every network address mode  -*- lexical-binding: t; -*-

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

;; Entry point of the package.  Loading this file loads the base mode
;; and all six address modes, so `net-inspect' works immediately:
;;
;;   (require 'network-modes)
;;   M-x net-inspect
;;
;; The optional integrations stay separate, because they pull in Org,
;; Embark, evil or a global xref hook:
;;
;;   (require 'ol-net)
;;   (require 'embark-net)
;;   (require 'net-evil)
;;   (require 'net-xref)

;;; Code:

(require 'net-mode)
(require 'net-geo)
(require 'net-ip)
(require 'net-cidr)
(require 'net-mac)
(require 'net-asn)
(require 'net-domain)
(require 'net-vsock)

(provide 'network-modes)
;;; network-modes.el ends here
