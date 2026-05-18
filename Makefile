.PHONY: build deps test fmt check clean release help
.DEFAULT_GOAL := build

build:
	mix cli

deps:
	mix deps.get

test:
	mix test

fmt:
	mix format

check:
	mix format_check
	mix credo

clean:
	rm -f bin/tractor
	mix clean

release:
	MIX_ENV=prod mix release tractor

help:
	@echo "make build    - build bin/tractor escript (MIX_ENV=prod)"
	@echo "make deps     - fetch mix deps"
	@echo "make test     - run mix test"
	@echo "make fmt      - mix format"
	@echo "make check    - format check + credo"
	@echo "make clean    - remove bin/tractor and run mix clean"
	@echo "make release  - cross-compiled Burrito release"
