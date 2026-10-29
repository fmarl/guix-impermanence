;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-impermanence btrfs)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:use-module (guix records)
  #:use-module (gnu system file-systems)
  #:use-module (guix-impermanence file-systems)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:export (impermanent-btrfs-file-systems
            impermanence-subvolumes
            merge-subvolumes
            btrfs-subvolume
            btrfs-subvolume?
            btrfs-subvolume-mount-point
            btrfs-subvolume-name
            btrfs-subvolume-flags
            btrfs-subvolume-needed-for-boot?
            btrfs-subvolume-file-system
            file-system-subvolume))

(define-record-type* <btrfs-subvolume>
  btrfs-subvolume make-btrfs-subvolume
  btrfs-subvolume?
  (mount-point      btrfs-subvolume-mount-point)
  (name             btrfs-subvolume-name)
  (flags            btrfs-subvolume-flags
                    (default '()))
  (needed-for-boot? btrfs-subvolume-needed-for-boot?
                    (default #f)))

(define* (impermanence-subvolumes #:key (persist %persist))
  (list (btrfs-subvolume
          (mount-point "/gnu")
          (name "@gnu"))
        (btrfs-subvolume
          (mount-point persist)
          (name "@persist"))
        (btrfs-subvolume
          (mount-point "/boot")
          (name "@boot"))))

(define (merge-subvolumes defaults subvolumes)
  "SUBVOLUMES replace the DEFAULTS with the same mount point."
  (define (same-mount-point? a b)
    (string=? (btrfs-subvolume-mount-point a)
              (btrfs-subvolume-mount-point b)))

  (pair-for-each (match-lambda
                   ((subvolume . rest)
                    (when (any (cut same-mount-point? subvolume <>) rest)
                      (raise (formatted-message
                              (G_ "~a: more than one btrfs subvolume")
                              (btrfs-subvolume-mount-point subvolume))))))
                 subvolumes)
  (append (remove (lambda (default)
                    (any (cut same-mount-point? default <>) subvolumes))
                  defaults)
          subvolumes))

(define* (btrfs-subvolume-file-system device subvolume
                                      #:key
                                      (options "")
                                      (flags '())
                                      (dependencies '()))
  (file-system
    (device device)
    (mount-point (btrfs-subvolume-mount-point subvolume))
    (type "btrfs")
    (options (string-append "subvol=" (btrfs-subvolume-name subvolume)
                            (if (string-null? options)
                                ""
                                (string-append "," options))))
    (flags (append flags (btrfs-subvolume-flags subvolume)))
    (needed-for-boot? (btrfs-subvolume-needed-for-boot? subvolume))
    (dependencies dependencies)))

(define (file-system-subvolume fs)
  (and (string=? (file-system-type fs) "btrfs")
       (assoc-ref (file-system-options->alist (file-system-options fs))
                  "subvol")))

(define* (impermanent-btrfs-file-systems device
                                         #:key
                                         (root (tmpfs-root-file-system))
                                         (subvolumes '())
                                         (options "")
                                         (flags '())
                                         (dependencies '())
                                         (persist %persist))
  "Return ROOT and DEVICE's subvolumes, the impermanence subvolumes merged
with SUBVOLUMES.  OPTIONS and FLAGS apply to every subvolume."
  (define (subvolume-file-system subvolume)
    (btrfs-subvolume-file-system
     device
     (if (string=? (btrfs-subvolume-mount-point subvolume) persist)
         (btrfs-subvolume
           (inherit subvolume)
           (needed-for-boot? #t))
         subvolume)
     #:options options
     #:flags flags
     #:dependencies dependencies))

  (cons root
        (map subvolume-file-system
             (merge-subvolumes (impermanence-subvolumes #:persist persist)
                               subvolumes))))
