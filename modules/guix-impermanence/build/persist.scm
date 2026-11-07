;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-impermanence build persist)
  #:use-module (guix build syscalls)
  #:use-module (guix build utils)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:export (create-persisted-directories
            restore-secrets
            save-secrets))

;;;; Persisted directories

(define (ensure-directory directory mode)
  "Unless DIRECTORY exists, create it with MODE and its missing parents with
mode 700."
  (unless (file-exists? directory)
    (let ((umask-before (umask #o077)))
      (dynamic-wind
        (const #t)
        (lambda () (mkdir-p directory))
        (lambda () (umask umask-before))))
    (chmod directory mode)))

(define (create-persisted-directories persist directories)
  "Create each of DIRECTORIES below PERSIST with its mode, unless it exists."
  (for-each (match-lambda
              ((directory mode)
               (ensure-directory (string-append persist directory) mode)))
            directories))

;;;; Files

(define (delete-file-if-exists file)
  (guard (exception ((and (eq? (exception-kind exception) 'system-error)
                          (match (exception-args exception)
                            ((_ _ _ (errno)) (= errno ENOENT))
                            (_ #f)))
                     #f))
    (delete-file file)))

(define (replace-file file mode write)
  "Replace FILE atomically with a new file of MODE.  WRITE gets a port to the
new file."
  (let ((new (string-append file ".new")))
    (delete-file-if-exists new)
    (let ((port (open new (logior O_WRONLY O_CREAT O_EXCL) mode)))
      (dynamic-wind
        (const #t)
        (lambda ()
          ;; 'open' honors the umask, which may clear bits of MODE.
          (chmod port mode)
          (write port)
          (force-output port)
          (fsync port))
        (lambda ()
          (close-port port))))
    (rename-file new file)))

(define (copy-file-atomically source target)
  (replace-file target (stat:perms (stat source))
                (lambda (port)
                  (call-with-input-file source
                    (cut dump-port <> port)
                    #:binary #t))))

(define (write-secret file text)
  (replace-file file #o600
                (lambda (port)
                  (display text port)
                  (newline port))))

(define (read-lines file)
  (call-with-input-file file
    (lambda (port)
      (let loop ((lines '()))
        (match (read-line port)
          ((? eof-object?) (reverse lines))
          (line (loop (cons line lines))))))))

;;;; Password hashes

(define (hash-file persist user)
  (string-append persist "/etc/shadow.d/" user))

(define (shadow-hash shadow user)
  (any (lambda (line)
         (match (string-split line #\:)
           (((? (cut string=? user <>)) hash . _) hash)
           (_ #f)))
       (read-lines shadow)))

(define (saved-hash persist user)
  (let ((file (hash-file persist user)))
    (and (file-exists? file)
         (match (read-lines file)
           ((hash) hash)
           (_ (error "malformed password hash file" file))))))

(define (set-hash line hashes)
  (match (string-split line #\:)
    ((name _ . rest)
     (match (assoc name hashes)
       ((_ . hash) (string-join (cons* name hash rest) ":"))
       (#f line)))
    (_ line)))

(define (restore-passwords persist etc users)
  (let ((hashes (filter-map (lambda (user)
                              (and=> (saved-hash persist user)
                                     (cut cons user <>)))
                            users))
        (shadow (string-append etc "/shadow")))
    (unless (null? hashes)
      (with-file-lock (string-append etc "/.pwd.lock")
        (let ((lines (read-lines shadow)))
          (replace-file shadow #o600
                        (lambda (port)
                          (for-each (lambda (line)
                                      (display (set-hash line hashes) port)
                                      (newline port))
                                    lines))))))))

(define (save-password persist shadow user)
  (let ((hash (shadow-hash shadow user))
        (file (hash-file persist user)))
    (when hash
      (ensure-directory (dirname file) #o700)
      (write-secret file hash))))

;;;; Keys and the restore report

(define (live-file etc file)
  (string-append etc "/" file))

(define (saved-file persist file)
  (string-append persist "/etc/" file))

(define (save-secret persist etc file)
  "Copy FILE from ETC to PERSIST.  Delete the copy of an SSH host key that ETC
lacks."
  (let ((live (live-file etc file))
        (saved (saved-file persist file)))
    (cond ((file-exists? live)
           (ensure-directory (dirname saved) #o700)
           (copy-file-atomically live saved))
          ;; A new signing key cannot replace a lost one, so keep its copy.
          ((string-prefix? "ssh/" file)
           (delete-file-if-exists saved)))))

(define (restore-secret persist etc file)
  "Copy FILE from PERSIST to ETC, or save it to PERSIST if it has no copy
there."
  (let ((saved (saved-file persist file)))
    (if (file-exists? saved)
        (copy-file-atomically saved (live-file etc file))
        (save-secret persist etc file))))

(define (host-key-files persist etc)
  (define (host-key? name)
    (and (string-prefix? "ssh_host_" name)
         (not (string-suffix? ".new" name))))

  (define (host-keys directory)
    (or (scandir directory host-key?)
        '()))

  (let ((live (string-append etc "/ssh"))
        (saved (string-append persist "/etc/ssh")))
    (if (file-exists? live)
        (map (cut string-append "ssh/" <>)
             (delete-duplicates (append (host-keys live) (host-keys saved))))
        '())))

(define (secret-files persist etc)
  (append '("guix/signing-key.pub" "guix/signing-key.sec")
          (host-key-files persist etc)))

;;; Secrets that failed to restore, which are therefore not saved at shutdown.
(define %restore-report
  "/run/impermanence/unrestored")

(define (write-restore-report report keys users)
  (ensure-directory (dirname report) #o700)
  (replace-file report #o600
                (lambda (port)
                  (write `((keys ,@keys) (users ,@users)) port))))

(define (read-restore-report report)
  (and (file-exists? report)
       (call-with-input-file report read)))

;;;; Restoring and saving

(define (try what thunk)
  "Call THUNK and return #t, or report its error about WHAT and return #f."
  (guard (exception
          (else
           (format (current-error-port) "impermanence: ~a: " what)
           (print-exception (current-error-port) #f
                            (exception-kind exception)
                            (exception-args exception))
           #f))
    (thunk)
    #t))

(define (failures proc items)
  "Call PROC on each of ITEMS, report its errors, and return the items it
failed for."
  (remove (lambda (item)
            (try item (cut proc item)))
          items))

(define* (restore-secrets persist users
                          #:key (etc "/etc") (report %restore-report))
  "Restore the store signing key, the SSH host keys and the password hashes
of USERS from PERSIST, or persist the keys that are not saved yet."
  (let ((keys (failures (cut restore-secret persist etc <>)
                        (secret-files persist etc)))
        (users (if (try "password hashes"
                        (cut restore-passwords persist etc users))
                   '()
                   users)))
    (write-restore-report report keys users)
    (and (null? keys) (null? users))))

(define* (save-secrets persist users
                       #:key (etc "/etc") (report %restore-report))
  "Save the keys and the password hashes of USERS to PERSIST, except those
that REPORT lists as not restored.  Return true if all of them were saved."
  (match (read-restore-report report)
    (#f
     (format (current-error-port)
             "impermanence: secrets were not restored, not saving them~%")
     #f)
    ((('keys unrestored-keys ...) ('users unrestored-users ...))
     (let* ((keys (lset-difference string=? (secret-files persist etc)
                                   unrestored-keys))
            (users (lset-difference string=? users unrestored-users))
            (shadow (string-append etc "/shadow"))
            (skipped (append unrestored-keys unrestored-users))
            (failed (append (failures (cut save-secret persist etc <>) keys)
                            (failures (cut save-password persist shadow <>)
                                      users))))
       (unless (null? skipped)
         (format (current-error-port)
                 "impermanence: not saving ~{~a~^, ~}, as restoring failed~%"
                 skipped))
       (null? failed)))))
