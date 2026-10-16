SHELL := /bin/bash

.PHONY: help check test dry-run apply

help:
	@echo "make check     # bash -n (sintaxis, bash 3.2)"
	@echo "make test      # self-test del script"
	@echo "make dry-run   # ver que haria sin tocar nada"
	@echo "make apply     # aplicar los tweaks"

check:
	/bin/bash -n tweakmeup.sh && echo "sintaxis OK"

test:
	./tweakmeup.sh --self-test

dry-run:
	./tweakmeup.sh --dry-run

apply:
	./tweakmeup.sh
