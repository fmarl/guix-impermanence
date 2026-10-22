# guix-impermanence
Guix System with `/` on a tmpfs.  Whatever has to survive a reboot lives
below `/persist` and gets bind-mounted into place.  Besides the directories
you list, it keeps the store signing key, the SSH host keys and the password
hashes of the given users.

```scheme
(use-modules (guix-impermanence file-systems)
             (guix-impermanence services))

(define %directories
  (cons '("/var/lib/bluetooth" #o700) %base-persisted-directories))

(operating-system
  ...
  (file-systems (append (list (tmpfs-root-file-system)
                              (file-system
                                (mount-point "/persist")
                                (device (file-system-label "persist"))
                                (type "btrfs")
                                (needed-for-boot? #t)))
                        (persisted-file-systems %directories)
                        %base-file-systems))
  (services (append (impermanence-services %directories '("alice"))
                    %base-services)))
```

`/persist` has to be `needed-for-boot?`.
