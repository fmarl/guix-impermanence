;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(use-modules (guix-impermanence build persist)
             (guix-impermanence file-systems)
             (guix-impermanence services)
             (gnu system file-systems)
             ((guix build utils) #:select (mkdir-p delete-file-recursively))
             (ice-9 rdelim)
             (ice-9 textual-ports)
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
  (length (impermanence-services %base-persisted-directories '("alice"))))

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

(exit (zero? (test-runner-fail-count (test-end "impermanence"))))
