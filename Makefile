# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

GUIX := guix time-machine -C $(CURDIR)/channels-lock.scm --

export GUILE_LOAD_PATH := $(CURDIR)/modules$(if $(GUILE_LOAD_PATH),:$(GUILE_LOAD_PATH))

.PHONY: check compile update

check:
	$(GUIX) repl -- tests/unit.scm

compile:
	$(GUIX) shell guix guile -- sh -c '\
	  out=$$(mktemp -d) && \
	  for f in $$(find modules -name "*.scm"); do \
	    guild compile -W3 -L modules -o "$$out/out.go" "$$f" >/dev/null \
	      || status=1; \
	  done; \
	  rm -r "$$out"; \
	  exit $${status:-0}'

update:
	guix time-machine -C channels.scm -- \
	    describe -f channels > channels-lock.scm.new
	mv channels-lock.scm.new channels-lock.scm
