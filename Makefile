.PHONY: project build test app icon clean reset-domains preflight release dmg

project:            ## Regenerate Sideport.xcodeproj from project.yml
	xcodegen generate

build:              ## Build the Swift package (engine + core)
	swift build

test:               ## Run the package test suites
	swift test

app: project        ## Build the container app and its extension
	xcodebuild -project Sideport.xcodeproj -scheme Sideport \
		-configuration Debug -destination 'platform=macOS' build

icon:               ## Regenerate the app icon set from the SF Symbol source
	swift scripts/make-icon.swift Apps/Sideport/Assets.xcassets/AppIcon.appiconset

reset-domains:      ## Tear down every registered File Provider domain
	./scripts/reset-domain.sh

preflight:          ## Report what is still missing before a signed release
	./scripts/preflight-release.sh

release:            ## Build, sign, notarize and staple Sideport.dmg
	./scripts/release.sh

dmg:                ## Build a Release DMG signed for this Mac only
	./scripts/build-local-dmg.sh

clean:
	rm -rf .build Sideport.xcodeproj
