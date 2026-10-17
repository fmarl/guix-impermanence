;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-impermanence services)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (gnu packages admin)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (guix-impermanence file-systems)
  #:use-module (srfi srfi-1)
  #:export (persisted-directories-configuration
            persisted-directories-configuration?
            persisted-directories-configuration-persist
            persisted-directories-configuration-directories
            persisted-directories-service-type
            impermanence-services))

(define %build-modules
  '((guix build utils)
    (guix-impermanence build persist)))

(define-record-type* <persisted-directories-configuration>
  persisted-directories-configuration make-persisted-directories-configuration
  persisted-directories-configuration?
  (persist persisted-directories-configuration-persist
           (default #f))
  (directories persisted-directories-configuration-directories
               (default %base-persisted-directories)))

(define (persisted-directories config)
  (delete-duplicates (persisted-directories-configuration-directories config)
                     (lambda (a b)
                       (string=? (first a)
                                 (first b)))))

(define (persisted-directories-activation config)
  (let ((persist (persisted-directories-configuration-persist config)))
    (if persist
        (with-imported-modules %build-modules
          #~(begin
              (use-modules (guix-impermanence build persist))
              (create-persisted-directories #$persist
                                            '#$(persisted-directories config))))
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
                (directories (append (persisted-directories-configuration-directories
                                      config) directories)))))
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
