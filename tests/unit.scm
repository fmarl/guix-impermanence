;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(use-modules (guix-impermanence btrfs)
             (guix-impermanence build persist)
             (guix-impermanence file-systems)
             (guix-impermanence services)
             (gnu services)
             (gnu services base)
             (gnu system file-systems)
             ((guix build utils) #:select (mkdir-p delete-file-recursively))
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define (call-with-temporary-directory proc)
  (let ((directory (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp")
                                           "/impermanence-XXXXXX"))))
    (dynamic-wind
      (const #t)
      (lambda () (proc directory))
      (lambda () (delete-file-recursively directory)))))

(define (write-file file text)
  (mkdir-p (dirname file))
  (call-with-output-file file
    (lambda (port) (display text port))))

(define (read-file file)
  (call-with-input-file file get-string-all))

(define (mode file)
  (stat:perms (stat file)))

(test-begin "impermanence")

(test-equal "persisted directories become bind mounts below persist"
  '(("/var/guix" "/data/var/guix" "none" (bind-mount)))
  (map (lambda (fs)
         (list (file-system-mount-point fs) (file-system-device fs)
               (file-system-type fs) (file-system-flags fs)))
       (persisted-file-systems '(("/var/guix" #o755)) #:persist "/data")))

(test-assert "a tmpfs root is impermanent"
  (impermanent-file-systems? (list (tmpfs-root-file-system))))

(test-assert "a btrfs root is not impermanent"
  (not (impermanent-file-systems?
        (list (file-system
                (mount-point "/")
                (device "/dev/sda1")
                (type "btrfs"))))))

(test-equal "impermanence adds three services"
  3
  (length (impermanence-services '("alice"))))

(define (persisted-mounts config)
  (let ((extension (find (lambda (extension)
                           (eq? (service-extension-target extension)
                                file-system-service-type))
                         (service-type-extensions
                          persisted-directories-service-type))))
    (map file-system-mount-point
         ((service-extension-compute extension) config))))

(test-equal "persisted directories do nothing without persist"
  '()
  (persisted-mounts (persisted-directories-configuration)))

(test-equal "extensions add persisted directories once"
  '("/var/guix" "/root/.cache/guix" "/var/lib/a" "/var/lib/b")
  (persisted-mounts ((service-type-extend persisted-directories-service-type)
                     (persisted-directories-configuration (persist "/data"))
                     '(("/var/lib/a" #o700) ("/var/lib/b" #o700)
                       ("/var/lib/a" #o700)))))

(test-equal "persisted directories are created with their mode"
  #o700
  (call-with-temporary-directory
   (lambda (persist)
     (create-persisted-directories persist '(("/var/lib/secret" #o700)))
     (mode (string-append persist "/var/lib/secret")))))

(test-equal "existing persisted directories keep their mode"
  #o755
  (call-with-temporary-directory
   (lambda (persist)
     (mkdir-p (string-append persist "/var/lib/data"))
     (chmod (string-append persist "/var/lib/data") #o755)
     (create-persisted-directories persist '(("/var/lib/data" #o700)))
     (mode (string-append persist "/var/lib/data")))))

(test-equal "new keys are saved to persist"
  "secret"
  (call-with-temporary-directory
   (lambda (root)
     (let ((persist (string-append root "/persist"))
           (etc (string-append root "/etc")))
       (write-file (string-append etc "/guix/signing-key.sec") "secret")
       (mkdir-p persist)
       (restore-secrets persist '() #:etc etc)
       (read-file (string-append persist "/etc/guix/signing-key.sec"))))))

(test-equal "saved keys replace the keys of a fresh /etc"
  "saved"
  (call-with-temporary-directory
   (lambda (root)
     (let ((persist (string-append root "/persist"))
           (etc (string-append root "/etc")))
       (write-file (string-append persist "/etc/ssh/ssh_host_ed25519_key")
                   "saved")
       (write-file (string-append etc "/ssh/ssh_host_ed25519_key") "fresh")
       (restore-secrets persist '() #:etc etc)
       (read-file (string-append etc "/ssh/ssh_host_ed25519_key"))))))

(test-equal "password hashes are saved and restored"
  "alice:$6$hash\n"
  (call-with-temporary-directory
   (lambda (root)
     (let ((persist (string-append root "/persist"))
           (etc (string-append root "/etc"))
           (chpasswd (string-append root "/chpasswd"))
           (output (string-append root "/chpasswd.out")))
       (write-file (string-append etc "/shadow")
                   "root:!:1::::::\nalice:$6$hash:1::::::\n")
       (save-secrets persist '("alice" "root") #:etc etc)
       (write-file chpasswd (string-append "#!/bin/sh\ncat > " output "\n"))
       (chmod chpasswd #o755)
       (restore-secrets persist '("alice" "root")
                        #:chpasswd chpasswd #:etc etc)
       (read-file output)))))

(test-equal "saved password hashes are private"
  #o600
  (call-with-temporary-directory
   (lambda (persist)
     (save-password-hash persist "alice" "$6$hash")
     (mode (string-append persist "/etc/shadow.d/alice")))))

(define (mount-points file-systems)
  (map file-system-mount-point file-systems))

(test-equal "btrfs layout has a tmpfs root and the required subvolumes"
  '("/" "/gnu" "/persist" "/boot")
  (mount-points (impermanent-btrfs-file-systems "/dev/sda1")))

(test-equal "extra subvolumes come after the required ones"
  '("/" "/gnu" "/persist" "/boot" "/home")
  (mount-points (impermanent-btrfs-file-systems
                 "/dev/sda1"
                 #:subvolumes (list (btrfs-subvolume
                                      (mount-point "/home")
                                      (name "@home"))))))

(test-equal "a subvolume replaces the required one at its mount point"
  '(("/gnu" "subvol=@store,compress=zstd" (no-atime no-suid)))
  (filter-map (lambda (fs)
                (and (string=? (file-system-mount-point fs) "/gnu")
                     (list (file-system-mount-point fs)
                           (file-system-options fs)
                           (file-system-flags fs))))
              (impermanent-btrfs-file-systems
               "/dev/sda1"
               #:options "compress=zstd"
               #:flags '(no-atime)
               #:subvolumes (list (btrfs-subvolume
                                    (mount-point "/gnu")
                                    (name "@store")
                                    (flags '(no-suid)))))))

(test-equal "the persist subvolume is needed for boot"
  '(("/persist" #t) ("/boot" #f))
  (filter-map (lambda (fs)
                (and (member (file-system-mount-point fs) '("/persist" "/boot"))
                     (list (file-system-mount-point fs)
                           (file-system-needed-for-boot? fs))))
              (impermanent-btrfs-file-systems "/dev/sda1")))

(test-equal "subvolume names are read back from file systems"
  '(#f "@gnu" "@persist" "@boot")
  (map file-system-subvolume (impermanent-btrfs-file-systems "/dev/sda1")))

(exit (zero? (test-runner-fail-count (test-end "impermanence"))))
