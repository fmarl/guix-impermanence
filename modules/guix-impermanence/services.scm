;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-impermanence services)
  #:use-module (guix diagnostics)
  #:use-module (guix gexp)
  #:use-module (guix i18n)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu system file-systems)
  #:use-module (guix-impermanence file-systems)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:export (impermanent-operating-system
            impermanence-services
            persisted-directories-service-type
            persisted-directories-configuration
            persisted-directories-configuration?
            persisted-directories-configuration-persist
            persisted-directories-configuration-directories))

(define %build-modules
  (cons '(guix-impermanence build persist)
        (source-module-closure '((guix build syscalls)
                                 (guix build utils)))))

(define-record-type* <persisted-directories-configuration>
  persisted-directories-configuration make-persisted-directories-configuration
  persisted-directories-configuration?
  (persist persisted-directories-configuration-persist
           (default #f))
  (directories persisted-directories-configuration-directories
               (default %base-persisted-directories)))

(define (persisted-directories config)
  (reverse
   (fold (lambda (entry directories)
           (match entry
             (((? absolute-file-name? directory) (? integer? mode))
              (match (assoc directory directories)
                (#f (cons entry directories))
                ((_ (? (cut = mode <>))) directories)
                ((_ other-mode)
                 (raise (formatted-message
                         (G_ "~a: persisted with modes ~o and ~o")
                         directory other-mode mode)))))
             (_
              (raise (formatted-message
                      (G_ "~s: expected an absolute directory and a mode")
                      entry)))))
         '()
         (persisted-directories-configuration-directories config))))

(define (persisted-directories-activation config)
  (let ((persist (persisted-directories-configuration-persist config)))
    (if persist
        (with-imported-modules %build-modules
          #~(begin
              (use-modules (guix-impermanence build persist))
              (create-persisted-directories
               #$persist '#$(persisted-directories config))))
        #~#t)))

(define (persisted-directories-file-systems config)
  (let ((persist (persisted-directories-configuration-persist config)))
    (if persist
        (persisted-file-systems (persisted-directories config)
                                #:persist persist)
        '())))

(define persisted-directories-service-type
  (service-type
    (name 'persisted-directories)
    (extensions
     (list (service-extension activation-service-type
                              persisted-directories-activation)
           (service-extension file-system-service-type
                              persisted-directories-file-systems)))
    (compose concatenate)
    (extend (lambda (config directories)
              (persisted-directories-configuration
                (inherit config)
                (directories
                 (append (persisted-directories-configuration-directories
                          config)
                         directories)))))
    (default-value (persisted-directories-configuration))
    (description
     "Bind-mount directories from the persistent file system over the tmpfs
root.")))

(define (secrets-program name exp)
  (program-file name
                (with-imported-modules %build-modules
                  #~(begin
                      (use-modules (guix-impermanence build persist))
                      #$exp))))

(define (persistent-secrets-shepherd-service persist users)
  (let ((restore (secrets-program "restore-secrets"
                                  #~(exit (restore-secrets #$persist
                                                           '#$users))))
        (save (secrets-program "save-secrets"
                               #~(exit (save-secrets #$persist
                                                     '#$users)))))
    (shepherd-service
      (provision '(persistent-secrets))
      (requirement '(file-systems))
      ;; Never fail, 'user-processes' requires this service.
      (start #~(lambda _
                 (system* #$restore)
                 #t))
      (stop #~(lambda _
                (system* #$save)
                #f))
      (documentation
       "Persistent password hashes, signing key and SSH host keys"))))

(define* (impermanence-services users
                                #:key (persist %persist))
  (list (service persisted-directories-service-type
                 (persisted-directories-configuration (persist persist)))
        (simple-service 'persistent-secrets shepherd-root-service-type
                        (list (persistent-secrets-shepherd-service persist
                                                                   users)))
        (simple-service 'persistent-secrets-before-login
                        user-processes-service-type
                        '(persistent-secrets))))

(define* (impermanent-operating-system os users
                                       #:key (persist %persist))
  (let ((file-systems (operating-system-file-systems os))
        (accounts (cons "root"
                        (map user-account-name (operating-system-users os)))))
    (for-each (lambda (user)
                (unless (member user accounts)
                  (raise (formatted-message (G_ "~a: no such user account")
                                            user))))
              users)
    (unless (impermanent-file-systems? file-systems)
      (raise (formatted-message (G_ "the root file system is not a tmpfs"))))
    (unless (any (lambda (fs)
                   (and (string=? (file-system-mount-point fs) persist)
                        (file-system-needed-for-boot? fs)))
                 file-systems)
      (raise (formatted-message (G_ "~a is not a file system needed for boot")
                                persist)))
    (operating-system
      (inherit os)
      (services (append (impermanence-services users #:persist persist)
                        (operating-system-user-services os))))))
