.PHONY: project build test app icon clean reset-domains

project:            ## Regenerate FinderADB.xcodeproj from project.yml
	xcodegen generate

build:              ## Build the Swift package (engine + core)
	swift build

test:               ## Run the package test suites
	swift test

app: project        ## Build the container app and its extension
	xcodebuild -project FinderADB.xcodeproj -scheme FinderADB \
		-configuration Debug -destination 'platform=macOS' build

icon:               ## Regenerate the app icon set from the SF Symbol source
	swift scripts/make-icon.swift Apps/FinderADB/Assets.xcassets/AppIcon.appiconset

reset-domains:      ## Tear down every registered File Provider domain
	./scripts/reset-domain.sh

clean:
	rm -rf .build FinderADB.xcodeproj
