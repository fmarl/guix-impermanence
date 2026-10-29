;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(use-modules (guix-impermanence btrfs)
             (guix-impermanence build persist)
             (guix-impermanence file-systems)
             (guix-impermanence services)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu services)
             (gnu services base)
             (gnu system)
             (gnu system accounts)
             (gnu system file-systems)
             (gnu system shadow)
             ((guix build utils) #:select (mkdir-p delete-file-recursively))
             (guix diagnostics)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-34)
             (srfi srfi-64))

(define (call-with-temporary-directory proc)
  (let ((directory (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp")
                                           "/impermanence-XXXXXX"))))
    (dynamic-wind
      (const #t)
      (lambda () (proc directory))
      (lambda () (delete-file-recursively directory)))))

(define (call-with-test-root proc)
  (call-with-temporary-directory
   (lambda (root)
     (proc (string-append root "/persist")
           (string-append root "/etc")
           (string-append root "/run/unrestored")))))

(define (write-file file text)
  (mkdir-p (dirname file))
  (call-with-output-file file
    (lambda (port) (display text port))))

(define (read-file file)
  (call-with-input-file file get-string-all))

(define (mode file)
  (stat:perms (stat file)))

(define-syntax-rule (error-message exp)
  (guard (c ((formatted-message? c)
             (string-trim-right (apply format #f
                                       (formatted-message-string c)
                                       (formatted-message-arguments c))
                                #\newline)))
    exp
    #f))

(test-begin "impermanence")

(test-equal "persisted directories become bind mounts below persist"
  '(("/var/guix" "/data/var/guix" "none" (bind-mount)))
  (map (lambda (fs)
         (list (file-system-mount-point fs) (file-system-device fs)
               (file-system-type fs) (file-system-flags fs)))
       (persisted-file-systems '(("/var/guix" #o755)) #:persist "/data")))

(test-equal "nested persisted directories are mounted after their parent"
  '(("/var/lib/a/b" ("/var/lib/a")) ("/var/lib" ()) ("/var/lib-x" ())
    ("/var/lib/a" ("/var/lib")))
  (map (lambda (fs)
         (list (file-system-mount-point fs)
               (map file-system-mount-point (file-system-dependencies fs))))
       (persisted-file-systems '(("/var/lib/a/b" #o700) ("/var/lib" #o755)
                                 ("/var/lib-x" #o700) ("/var/lib/a" #o700)))))

(define* (persisted-mounts directories #:key (persist "/data"))
  (let ((extension (find (lambda (extension)
                           (eq? (service-extension-target extension)
                                file-system-service-type))
                         (service-type-extensions
                          persisted-directories-service-type))))
    (map file-system-mount-point
         ((service-extension-compute extension)
          ((service-type-extend persisted-directories-service-type)
           (persisted-directories-configuration (persist persist))
           directories)))))

(test-equal "persisted directories do nothing without persist"
  '()
  (persisted-mounts '(("/var/lib/a" #o700)) #:persist #f))

(test-equal "extensions add persisted directories once"
  '("/var/guix" "/root/.cache/guix" "/var/lib/a" "/var/lib/b")
  (persisted-mounts '(("/var/lib/a" #o700) ("/var/lib/b" #o700)
                      ("/var/lib/a" #o700))))

(test-equal "a directory cannot be persisted with two modes"
  "/var/lib/a: persisted with modes 700 and 755"
  (error-message
   (persisted-mounts '(("/var/lib/a" #o700) ("/var/lib/a" #o755)))))

(test-equal "persisted directories need an absolute name and a mode"
  "(\"var/lib/a\" 448): expected an absolute directory and a mode"
  (error-message
   (persisted-mounts '(("var/lib/a" #o700)))))

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
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append etc "/guix/signing-key.sec") "secret")
     (restore-secrets persist '() #:etc etc #:report report)
     (read-file (string-append persist "/etc/guix/signing-key.sec")))))

(test-equal "saved keys replace the keys of a fresh /etc"
  "saved"
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append persist "/etc/ssh/ssh_host_ed25519_key")
                 "saved")
     (write-file (string-append etc "/ssh/ssh_host_ed25519_key") "fresh")
     (restore-secrets persist '() #:etc etc #:report report)
     (read-file (string-append etc "/ssh/ssh_host_ed25519_key")))))

(test-equal "rotated keys are saved at shutdown"
  "rotated"
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append persist "/etc/ssh/ssh_host_ed25519_key")
                 "old")
     (write-file (string-append etc "/ssh/ssh_host_ed25519_key") "old")
     (restore-secrets persist '() #:etc etc #:report report)
     (write-file (string-append etc "/ssh/ssh_host_ed25519_key") "rotated")
     (save-secrets persist '() #:etc etc #:report report)
     (read-file (string-append persist "/etc/ssh/ssh_host_ed25519_key")))))

(test-equal "saved keys keep their mode"
  #o600
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append etc "/guix/signing-key.sec") "secret")
     (chmod (string-append etc "/guix/signing-key.sec") #o600)
     (write-file (string-append persist "/etc/guix/signing-key.sec.new")
                 "stale")
     (chmod (string-append persist "/etc/guix/signing-key.sec.new") #o644)
     (restore-secrets persist '() #:etc etc #:report report)
     (mode (string-append persist "/etc/guix/signing-key.sec")))))

(test-equal "leftover files of interrupted copies are not restored"
  '("ssh_host_ed25519_key")
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append persist "/etc/ssh/ssh_host_ed25519_key.new")
                 "partial")
     (write-file (string-append etc "/ssh/ssh_host_ed25519_key") "key")
     (restore-secrets persist '() #:etc etc #:report report)
     (scandir (string-append etc "/ssh")
              (lambda (name) (not (member name '("." ".."))))))))

(test-equal "password hashes are saved and restored"
  '("root:!:1::::::\nalice:$6$hash:1::::::\nbob:$6$bob:1::::::\n" #o600)
  (call-with-test-root
   (lambda (persist etc report)
     (let ((shadow (string-append etc "/shadow")))
       (write-file shadow "root:!:1::::::\nalice:$6$hash:1::::::\n")
       (restore-secrets persist '("alice" "root") #:etc etc #:report report)
       (save-secrets persist '("alice" "root") #:etc etc #:report report)
       (write-file shadow
                   "root:!:1::::::\nalice:!:1::::::\nbob:$6$bob:1::::::\n")
       (chmod shadow #o644)
       (and (restore-secrets persist '("alice" "root")
                             #:etc etc #:report report)
            (list (read-file shadow) (mode shadow)))))))

(test-equal "locked and deleted passwords stay so after a reboot"
  "root::1::::::\nalice:!$6$hash:1::::::\n"
  (call-with-test-root
   (lambda (persist etc report)
     (let ((shadow (string-append etc "/shadow")))
       (write-file shadow "root:$6$root:1::::::\nalice:$6$hash:1::::::\n")
       (restore-secrets persist '("alice" "root") #:etc etc #:report report)
       ;; passwd -d root; passwd -l alice
       (write-file shadow "root::1::::::\nalice:!$6$hash:1::::::\n")
       (save-secrets persist '("alice" "root") #:etc etc #:report report)
       (write-file shadow "root:!:1::::::\nalice:!:1::::::\n")
       (restore-secrets persist '("alice" "root") #:etc etc #:report report)
       (read-file shadow)))))

(test-equal "saved password hashes are private"
  #o600
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append etc "/shadow") "alice:$6$hash:1::::::\n")
     (restore-secrets persist '("alice") #:etc etc #:report report)
     (save-secrets persist '("alice") #:etc etc #:report report)
     (mode (string-append persist "/etc/shadow.d/alice")))))

(test-assert "restoring fails if the shadow file is missing"
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append persist "/etc/shadow.d/alice") "$6$hash\n")
     (mkdir-p etc)
     (not (restore-secrets persist '("alice") #:etc etc #:report report)))))

(test-equal "secrets that were not restored are not saved"
  '(#f "$6$saved\n" "$6$alice\n")
  (call-with-test-root
   (lambda (persist etc report)
     (let ((shadow (string-append etc "/shadow")))
       (write-file (string-append persist "/etc/shadow.d/alice") "")
       (write-file (string-append persist "/etc/shadow.d/bob")
                   "$6$saved\n")
       (write-file shadow "alice:!:1::::::\nbob:!:1::::::\n")
       (list (restore-secrets persist '("alice" "bob")
                              #:etc etc #:report report)
             (begin
               (save-secrets persist '("alice" "bob")
                             #:etc etc #:report report)
               (read-file (string-append persist "/etc/shadow.d/bob")))
             (begin
               (write-file (string-append persist "/etc/shadow.d/alice")
                           "$6$alice\n")
               (restore-secrets persist '("alice" "bob")
                                #:etc etc #:report report)
               (save-secrets persist '("alice" "bob")
                             #:etc etc #:report report)
               (read-file (string-append persist "/etc/shadow.d/alice"))))))))

(test-equal "a key that fails to restore does not keep the others from saving"
  '(#f "$6$new\n")
  (call-with-test-root
   (lambda (persist etc report)
     (let ((shadow (string-append etc "/shadow")))
       ;; A directory where a key should be cannot be copied.
       (mkdir-p (string-append persist "/etc/ssh/ssh_host_ed25519_key"))
       (write-file (string-append etc "/ssh/ssh_host_ed25519_key") "fresh")
       (write-file shadow "alice:$6$old:1::::::\n")
       (let ((restored? (restore-secrets persist '("alice")
                                         #:etc etc #:report report)))
         (write-file shadow "alice:$6$new:1::::::\n")
         (save-secrets persist '("alice") #:etc etc #:report report)
         (list restored?
               (read-file (string-append persist "/etc/shadow.d/alice"))))))))

(test-equal "nothing is saved without a restore report"
  '(#f #f)
  (call-with-test-root
   (lambda (persist etc report)
     (write-file (string-append etc "/shadow") "alice:$6$hash:1::::::\n")
     (list (save-secrets persist '("alice") #:etc etc #:report report)
           (file-exists? (string-append persist "/etc/shadow.d/alice"))))))

(define (mount-points file-systems)
  (map file-system-mount-point file-systems))

(define (needed-for-boot file-systems)
  (filter-map (lambda (fs)
                (and (file-system-needed-for-boot? fs)
                     (not (member (file-system-mount-point fs) '("/" "/gnu")))
                     (file-system-mount-point fs)))
              file-systems))

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

(test-equal "two subvolumes cannot share a mount point"
  "/home: more than one btrfs subvolume"
  (error-message
   (impermanent-btrfs-file-systems
    "/dev/sda1"
    #:subvolumes (list (btrfs-subvolume
                         (mount-point "/home")
                         (name "@home"))
                       (btrfs-subvolume
                         (mount-point "/home")
                         (name "@home2"))))))

(test-equal "only the persist subvolume is needed for boot"
  '("/persist")
  (needed-for-boot (impermanent-btrfs-file-systems "/dev/sda1")))

(test-equal "a replaced persist subvolume is still needed for boot"
  '("/persist")
  (needed-for-boot (impermanent-btrfs-file-systems
                    "/dev/sda1"
                    #:subvolumes (list (btrfs-subvolume
                                         (mount-point "/persist")
                                         (name "@persist")
                                         (flags '(no-suid)))))))

(test-equal "extra subvolumes can be needed for boot"
  '("/persist" "/var/log")
  (needed-for-boot (impermanent-btrfs-file-systems
                    "/dev/sda1"
                    #:subvolumes (list (btrfs-subvolume
                                         (mount-point "/var/log")
                                         (name "@log")
                                         (needed-for-boot? #t))))))

(test-equal "the persist subvolume and the root can be chosen"
  '(("/" "mode=0755,size=4G") ("/gnu" "subvol=@gnu")
    ("/data" "subvol=@persist") ("/boot" "subvol=@boot"))
  (map (lambda (fs)
         (list (file-system-mount-point fs) (file-system-options fs)))
       (impermanent-btrfs-file-systems
        "/dev/sda1"
        #:root (tmpfs-root-file-system #:size "4G")
        #:persist "/data")))

(test-equal "subvolume names are read back from file systems"
  '(#f "@gnu" "@persist" "@boot")
  (map file-system-subvolume (impermanent-btrfs-file-systems "/dev/sda1")))

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

(define* (test-os #:optional
                  (file-systems (impermanent-btrfs-file-systems "/dev/sda1")))
  (operating-system
    (host-name "test")
    (bootloader (bootloader-configuration
                  (bootloader grub-bootloader)
                  (targets '("/dev/sda"))))
    (file-systems (append file-systems %base-file-systems))
    (users (cons (user-account
                  (name "alice")
                  (group "users"))
                 %base-user-accounts))))

(test-assert "an impermanent operating system gets the services"
  (find (lambda (service)
          (eq? (service-kind service) persisted-directories-service-type))
        (operating-system-user-services
         (impermanent-operating-system (test-os) '("alice" "root")))))

(test-equal "persisted passwords belong to user accounts"
  "alcie: no such user account"
  (error-message
   (impermanent-operating-system (test-os) '("alcie"))))

(test-equal "an operating system without tmpfs root is not impermanent"
  "the root file system is not a tmpfs"
  (error-message
   (impermanent-operating-system
    (test-os (list (file-system
                     (mount-point "/")
                     (device "/dev/sda1")
                     (type "btrfs"))))
    '())))

(test-equal "persist has to be needed for boot"
  "/persist is not a file system needed for boot"
  (error-message
   (impermanent-operating-system
    (test-os (list (tmpfs-root-file-system)
                   (file-system
                     (mount-point "/persist")
                     (device "/dev/sda1")
                     (type "btrfs"))))
    '())))

(exit (zero? (test-runner-fail-count (test-end "impermanence"))))
