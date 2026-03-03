SHELL := /usr/bin/env bash

.PHONY: build docker-build package clean test

build:
	bash scripts/build.sh

docker-build:
	bash docker/build.sh

package:
	bash scripts/build.sh --from-stage 99_package --to-stage 99_package

clean:
	rm -rf build dist state out ziggurat-*.tar.xz
	mkdir -p dist state
	touch dist/.gitkeep state/.gitkeep

test:
	bash tests/run.sh
