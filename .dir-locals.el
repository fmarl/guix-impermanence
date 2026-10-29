;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

;; Per-directory local variables for GNU Emacs, following those of Guix.

((nil
  . ((fill-column . 78)
     (tab-width   .  8)
     (sentence-end-double-space . t)))
 (scheme-mode
  .
  ((indent-tabs-mode . nil)

   (eval . (with-eval-after-load 'geiser-guile
             (let ((root (expand-file-name
                          "modules"
                          (locate-dominating-file default-directory
                                                  ".dir-locals.el"))))
               (unless (member root geiser-guile-load-path)
                 (setq-local geiser-guile-load-path
                             (cons root geiser-guile-load-path))))))

   (eval . (put 'call-with-input-file 'scheme-indent-function 1))
   (eval . (put 'call-with-output-file 'scheme-indent-function 1))
   (eval . (put 'catch 'scheme-indent-function 1))
   (eval . (put 'dynamic-wind 'scheme-indent-function 0))
   (eval . (put 'guard 'scheme-indent-function 1))
   (eval . (put 'lambda* 'scheme-indent-function 1))
   (eval . (put 'with-file-lock 'scheme-indent-function 1))
   (eval . (put 'with-imported-modules 'scheme-indent-function 1))
   (eval . (put 'test-assert 'scheme-indent-function 1))
   (eval . (put 'test-equal 'scheme-indent-function 1))

   (eval . (put 'bootloader-configuration 'scheme-indent-function 0))
   (eval . (put 'channel 'scheme-indent-function 0))
   (eval . (put 'file-system 'scheme-indent-function 0))
   (eval . (put 'operating-system 'scheme-indent-function 0))
   (eval . (put 'service-type 'scheme-indent-function 0))
   (eval . (put 'shepherd-service 'scheme-indent-function 0))

   (eval . (put 'btrfs-subvolume 'scheme-indent-function 0))
   (eval . (put 'persisted-directories-configuration
                'scheme-indent-function 0)))))
