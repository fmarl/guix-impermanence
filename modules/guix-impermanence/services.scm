;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-impermanence services)
  #:use-module (guix gexp)
  #:use-module (gnu packages admin)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix-impermanence file-systems)
  #:export (impermanence-services))

(define %build-modules
  '((guix build utils)
    (guix-impermanence build persist)))

(define (persisted-directories-activation persist directories)
  (with-imported-modules %build-modules
    #~(begin
        (use-modules (guix-impermanence build persist))
        (create-persisted-directories #$persist
                                      '#$directories))))

(define (secrets-program name exp)
  (program-file name
                (with-imported-modules %build-modules
                  #~(begin
                      (use-modules (guix-impermanence build persist))
                      #$exp))))

(define (persistent-secrets-shepherd-service persist users)
  (let ((restore (secrets-program "restore-secrets"
                                  #~(restore-secrets #$persist
                                                     '#$users
                                                     #:chpasswd #$(file-append
                                                                   shadow
                                                                   "/sbin/chpasswd"))))
        (save (secrets-program "save-secrets"
                               #~(save-secrets #$persist
                                               '#$users))))
    (shepherd-service
      (provision '(persistent-secrets))
      (requirement '(file-systems))
      (start #~(lambda _
                 (system* #$restore) #t))
      (stop #~(lambda _
                (system* #$save) #f))
      (documentation
       "Persistent password hashes, signing key and SSH host keys"))))

(define* (impermanence-services directories users
                                #:key (persist %persist))
  (list (simple-service 'persisted-directories activation-service-type
                        (persisted-directories-activation persist directories))
        (simple-service 'persistent-secrets shepherd-root-service-type
                        (list (persistent-secrets-shepherd-service persist
                                                                   users)))
        (simple-service 'persistent-secrets-before-login
                        user-processes-service-type
                        '(persistent-secrets))))
