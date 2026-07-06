# Covey.app bundle targets. Day-to-day SPM loop stays `swift build` / `swift test`.
#
#   make app      — build Release Covey.app (regenerates .xcodeproj if project.yml changed)
#   make install  — app + replace /Applications/Covey.app
#   make icons    — re-slice App icon from icon.png (runs automatically when icon.png changes)
#
# SIGN: ad-hoc until an Apple ID team is configured in project.yml — then drop it.

DERIVED := .build/xcode
APP     := $(DERIVED)/Build/Products/Release/Covey.app
ICONSET := App/Assets.xcassets/AppIcon.appiconset
SIGN    := CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES

.PHONY: app install icons

Covey.xcodeproj/project.pbxproj: project.yml
	xcodegen generate

# Stamp: any slice regenerated after icon.png means the whole set is fresh.
$(ICONSET)/icon_512@2x.png: icon.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size icon.png --out "$(ICONSET)/icon_$$size.png" >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) icon.png --out "$(ICONSET)/icon_$$size@2x.png" >/dev/null; \
	done

icons: $(ICONSET)/icon_512@2x.png

app: Covey.xcodeproj/project.pbxproj icons
	xcodebuild -project Covey.xcodeproj -scheme Covey -configuration Release \
		-derivedDataPath $(DERIVED) build $(SIGN)

install: app
	rm -rf /Applications/Covey.app
	ditto "$(APP)" /Applications/Covey.app
	@echo "Installed /Applications/Covey.app"
