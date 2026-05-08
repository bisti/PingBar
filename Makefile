APP_NAME := PingBar
APP_BUNDLE := $(APP_NAME).app
EXECUTABLE := .build/release/$(APP_NAME)

.PHONY: build test run package open clean

build:
	swift build -c release

test:
	swift test

run:
	swift run $(APP_NAME)

package: build
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(EXECUTABLE)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp "Resources/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	cp "Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	chmod +x "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	touch "$(APP_BUNDLE)"

open: package
	open "$(APP_BUNDLE)"

clean:
	rm -rf .build "$(APP_BUNDLE)"
