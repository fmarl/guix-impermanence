;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-impermanence file-systems)
  #:use-module (gnu system file-systems)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%persist
            %base-persisted-directories
            tmpfs-root-file-system
            impermanent-file-systems?
            persisted-file-systems))

(define %persist
  "/persist")

(define %base-persisted-directories
  '(("/var/guix" #o755)
    ("/root/.cache/guix" #o700)))

(define* (tmpfs-root-file-system #:key (size "2G"))
  (file-system
    (mount-point "/")
    (device "tmpfs")
    (type "tmpfs")
    (options (string-append "mode=0755,size=" size))
    (check? #f)))

(define (impermanent-file-systems? file-systems)
  (any (lambda (fs)
         (and (string=? (file-system-mount-point fs) "/")
              (string=? (file-system-type fs) "tmpfs"))) file-systems))

(define* (persisted-file-systems directories
                                 #:key (persist %persist))
  (map (match-lambda
         ((directory _)
          (file-system
            (mount-point directory)
            (device (string-append persist directory))
            (type "none")
            (flags '(bind-mount))
            (check? #f))))
       directories))
