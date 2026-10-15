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

   ;; Guile and Guix forms used here.
   (eval . (put 'call-with-output-file 'scheme-indent-function 1))
   (eval . (put 'lambda* 'scheme-indent-function 1))
   (eval . (put 'test-assert 'scheme-indent-function 1))
   (eval . (put 'test-equal 'scheme-indent-function 1))
   (eval . (put 'with-imported-modules 'scheme-indent-function 1))

   ;; Record constructors.
   (eval . (put 'file-system 'scheme-indent-function 0))
   (eval . (put 'shepherd-service 'scheme-indent-function 0)))))
