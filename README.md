# guix-impermanence
Guix System with `/` on a tmpfs

```scheme
(use-modules (guix-impermanence file-systems)
             (guix-impermanence services))

(impermanent-operating-system
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
                     %base-services)))
 '("alice"))
```

`impermanent-operating-system` refuses a system whose `/` is not a tmpfs,
whose `/persist` is not needed for boot, or whose user list names an unknown
account.

Services persist directories by extending `persisted-directories-service-type`
with directory and mode pairs.  `/var/guix` and `/root/.cache/guix` are always
kept; `/home` is not, so persist it or give it a file system of its own.

Keys and password hashes are restored at boot and saved at shutdown.  Changes
made since the last clean shutdown are lost on a crash.  A secret that could
not be restored is not saved either, so its good copy stays.

## Btrfs
`(guix-impermanence btrfs)` lays out a tmpfs root and subvolumes for `/gnu`,
`/persist` and `/boot`.  Extra subvolumes are added; one at the mount point of a
default replaces it.  The subvolume at `/persist` is always needed for boot.

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

Pass `#:root` for a different tmpfs, such as `(tmpfs-root-file-system #:size
"4G")`, and `#:persist` to move the persistent subvolume.
