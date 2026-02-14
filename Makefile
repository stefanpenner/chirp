ROOT := $(shell pwd)
MODEL_DIR := $(ROOT)/models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8
LIB_DIR := $(ROOT)/Frameworks/lib

.PHONY: setup build run clean

setup:
	./scripts/setup.sh

build:
	swift build

run: build
	DYLD_LIBRARY_PATH="$(LIB_DIR)" \
	YODEL_MODEL_DIR="$(MODEL_DIR)" \
		swift run Yodel

clean:
	swift package clean
