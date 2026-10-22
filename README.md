# guix-impermanence
Guix System with `/` on a tmpfs.  Whatever has to survive a reboot lives
below `/persist` and gets bind-mounted into place.  Besides the directories
you list, it keeps the store signing key, the SSH host keys and the password
hashes of the given users.

```scheme
(use-modules (guix-impermanence file-systems)
             (guix-impermanence services))

(operating-system
  ...
  (file-systems (append (list (tmpfs-root-file-system)
                              (file-system
                                (mount-point "/persist")
                                (device (file-system-label "persist"))
                                (type "btrfs")
                                (needed-for-boot? #t)))
                        %base-file-systems))
  (services (append (list (simple-service 'bluetooth-state
                                          persisted-directories-service-type
                                          '(("/var/lib/bluetooth" #o700))))
                    (impermanence-services '("alice"))
                    %base-services)))
```

`/persist` has to be `needed-for-boot?`.  Services add directories by
extending `persisted-directories-service-type` (`/var/guix` and
`/root/.cache/guix` are always kept).

On btrfs, `(guix-impermanence btrfs)` gives the tmpfs root and subvolumes for
`/gnu`, `/persist` and `/boot`.  Extra subvolumes are added, and one with the
same mount point replaces the default:

```scheme
(use-modules (guix-impermanence btrfs))

(impermanent-btrfs-file-systems
 (file-system-label "root")
 #:options "compress=zstd"
 #:subvolumes (list (btrfs-subvolume
                      (mount-point "/home")
                      (name "@home")
                      (flags '(no-suid no-dev)))))
```
