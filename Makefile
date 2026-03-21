APP_NAME = Limelight
APP_BUNDLE = $(APP_NAME).app
BUILD_DIR = .build/release

.PHONY: app clean

app:
	swift build -c release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp ./assets/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "Built $(APP_BUNDLE) successfully."

clean:
	rm -rf $(APP_BUNDLE) .build