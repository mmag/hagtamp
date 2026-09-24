# Common development tasks. The Xcode project is generated from project.yml.

DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Hagtamp.app
KIT := Packages/HagtampKit

.PHONY: project app run test corpus compare clean

project:
	xcodegen generate --quiet

app: project
	xcodebuild -project Hagtamp.xcodeproj -scheme Hagtamp -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' -quiet build

run: app
	open $(APP)

test:
	swift test --package-path $(KIT)

# Downloads ~300 skins with reference screenshots from the Winamp Skin Museum.
corpus:
	scripts/fetch_skin_corpus.py

# Diffs our renders against the museum screenshots; visual diffs go to .artifacts/compare.
compare:
	swift run --package-path $(KIT) -c release skintool compare .corpus .artifacts/compare

clean:
	rm -rf build .artifacts Hagtamp.xcodeproj $(KIT)/.build
