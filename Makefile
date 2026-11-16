# Command Line Tools ship Swift Testing outside the default search path. Xcode (as on the
# CI runners) finds it itself, and mixing in the CLT copy would clash with its toolchain.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIBS := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
ifeq ($(shell xcode-select -p),/Library/Developer/CommandLineTools)
TEST_FLAGS := -Xswiftc -F$(CLT_FRAMEWORKS) -Xlinker -F$(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_LIBS)
endif

.PHONY: build test run app release icon install clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

run:
	swift run DiskCleaner

app:
	scripts/build-app.sh

release:
	scripts/build-app.sh --zip

icon:
	swift scripts/make-icon.swift

install: app
	rm -rf "/Applications/Disk Cleaner.app"
	cp -R "build/Disk Cleaner.app" /Applications/

clean:
	rm -rf .build build
