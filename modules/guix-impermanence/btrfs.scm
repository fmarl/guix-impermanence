;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-impermanence btrfs)
  #:use-module (guix records)
  #:use-module (gnu system file-systems)
  #:use-module (guix-impermanence file-systems)
  #:use-module (srfi srfi-1)
  #:export (btrfs-subvolume
            btrfs-subvolume?
            btrfs-subvolume-mount-point
            btrfs-subvolume-name
            btrfs-subvolume-flags
            %impermanence-subvolumes
            merge-subvolumes
            btrfs-subvolume-file-system
            file-system-subvolume
            impermanent-btrfs-file-systems))

(define-record-type* <btrfs-subvolume>
  btrfs-subvolume make-btrfs-subvolume
  btrfs-subvolume?
  (mount-point btrfs-subvolume-mount-point)
  (name        btrfs-subvolume-name)
  (flags       btrfs-subvolume-flags
               (default '())))

(define %impermanence-subvolumes
  (list (btrfs-subvolume
          (mount-point "/gnu")
          (name "@gnu"))
        (btrfs-subvolume
          (mount-point %persist)
          (name "@persist"))
        (btrfs-subvolume
          (mount-point "/boot")
          (name "@boot"))))

(define (merge-subvolumes defaults subvolumes)
  "SUBVOLUMES replace the DEFAULTS with the same mount point."
  (append (remove (lambda (default)
                    (find (lambda (subvolume)
                            (string=? (btrfs-subvolume-mount-point subvolume)
                                      (btrfs-subvolume-mount-point default)))
                          subvolumes))
                  defaults)
          subvolumes))

(define* (btrfs-subvolume-file-system device subvolume
                                      #:key
                                      (options "")
                                      (flags '())
                                      (dependencies '()))
  (let ((mount-point (btrfs-subvolume-mount-point subvolume)))
    (file-system
      (device device)
      (mount-point mount-point)
      (type "btrfs")
      (options (string-append "subvol=" (btrfs-subvolume-name subvolume)
                              (if (string-null? options)
                                  ""
                                  (string-append "," options))))
      (flags (append flags (btrfs-subvolume-flags subvolume)))
      (needed-for-boot? (string=? mount-point %persist))
      (dependencies dependencies))))

(define (file-system-subvolume fs)
  (and (string=? (file-system-type fs) "btrfs")
       (assoc-ref (file-system-options->alist (file-system-options fs))
                  "subvol")))

(define* (impermanent-btrfs-file-systems device
                                         #:key
                                         (subvolumes '())
                                         (options "")
                                         (flags '())
                                         (dependencies '()))
  "Return a tmpfs root and DEVICE's subvolumes, %IMPERMANENCE-SUBVOLUMES
merged with SUBVOLUMES.  OPTIONS and FLAGS apply to every subvolume."
  (cons (tmpfs-root-file-system)
        (map (lambda (subvolume)
               (btrfs-subvolume-file-system device subvolume
                                            #:options options
                                            #:flags flags
                                            #:dependencies dependencies))
             (merge-subvolumes %impermanence-subvolumes subvolumes))))
