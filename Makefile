# Command Line Tools ship Swift Testing outside the default search path; Xcode does not need these flags.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIBS := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F$(CLT_FRAMEWORKS) -Xlinker -F$(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_LIBS)

.PHONY: build test run app install clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

run:
	swift run DiskCleaner

app:
	scripts/build-app.sh

install: app
	rm -rf "/Applications/Disk Cleaner.app"
	cp -R "build/Disk Cleaner.app" /Applications/

clean:
	rm -rf .build build
