# 便り（tayori）iOS — よく使う手順
#
#   make generate   xcodegen で .xcodeproj を作る（生成物はコミットしない）
#   make sim        シミュレータ向けにビルドだけ通す（Team ID 不要・アドホック署名）
#   make shots      iPhone と iPad のシミュレータで起動してスクリーンショット（先に ../worker で npm run dev と npm run seed）
#   make archive    TestFlight 向けアーカイブ（Release・自動署名）。サービストークンをこの Mac のキーチェーンから埋め込む
#   make export-testflight  .ipa を build/export/ に書き出す（送らない）
#   make upload     API キーで App Store Connect へ上げる（Release.local.env と .p8 が要る）
#   make release    archive → upload（ビルド番号は日時で自動）
#   make icon       アプリアイコンを描き直す
#
# Team ID は ~/.config/kazoku-keijiban/team-id（1行・家族掲示板と同じチーム）か `make ... TEAM=XXXXXXXXXX`。

PROJECT = tayori.xcodeproj
SCHEME  = Tayori
BUNDLE  = jp.kechiiiiin.tayori
CONF    = $(HOME)/.config/kazoku-keijiban
TEAM   ?= $(shell cat $(CONF)/team-id 2>/dev/null)
export TAYORI_TEAM_ID = $(TEAM)
PHONE_SIM = Tayori-iPhone
PHONE_TYPE = iPhone 17
PAD_SIM   = Tayori-iPad
PAD_TYPE  = iPad Pro 13-inch (M5)
LOCAL   = http://127.0.0.1:8792
SHOTS   = ../docs/screenshots
APP     = build-sim/Build/Products/Debug-iphonesimulator/Tayori.app

ARCHIVE = build/Tayori.xcarchive
# サービストークンの出どころ（ビルドする Mac のキーチェーン。読むだけで書き込まない）
KC_SERVICE ?= tayori-token
SECRETS = Secrets.xcconfig

.PHONY: generate sim shots shots-phone shots-pad icon clean archive upload export-testflight release require-team require-asc-key

generate:
	xcodegen generate

sim: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS Simulator' -configuration Debug \
	  -derivedDataPath build-sim CODE_SIGN_IDENTITY=- build
	@echo "✅ シミュレータ向けのビルドは通る"

# 起動引数で画面の状態を作って撮る（App/RootView.swift の applyDemo）。
# $(1)=シミュレータ名 $(2)=接頭辞
define shoot
	xcrun simctl launch --terminate-running-process "$(1)" $(BUNDLE) -tayoriBaseURL $(LOCAL) $(3)
	@sleep 5
	xcrun simctl io "$(1)" screenshot $(SHOTS)/$(2).png
endef

shots-phone: sim
	@xcrun simctl list devices | grep -q "$(PHONE_SIM) (" || xcrun simctl create "$(PHONE_SIM)" "$(PHONE_TYPE)" > /dev/null
	@xcrun simctl boot "$(PHONE_SIM)" 2>/dev/null || true
	xcrun simctl install "$(PHONE_SIM)" $(APP)
	@mkdir -p $(SHOTS)
	$(call shoot,$(PHONE_SIM),iphone-1-list,)
	$(call shoot,$(PHONE_SIM),iphone-3-returned,-tayoriDemo opened)
	$(call shoot,$(PHONE_SIM),iphone-4-comment,-tayoriDemo comment)
	$(call shoot,$(PHONE_SIM),iphone-5-commented,-tayoriTab commented)
	$(call shoot,$(PHONE_SIM),iphone-6-sites,-tayoriScreen sites)
	$(call shoot,$(PHONE_SIM),iphone-7-share,-tayoriSharePreview https://blog.example.jp/)

shots-pad: sim
	@xcrun simctl list devices | grep -q "$(PAD_SIM) (" || xcrun simctl create "$(PAD_SIM)" "$(PAD_TYPE)" > /dev/null
	@xcrun simctl boot "$(PAD_SIM)" 2>/dev/null || true
	xcrun simctl install "$(PAD_SIM)" $(APP)
	@mkdir -p $(SHOTS)
	$(call shoot,$(PAD_SIM),ipad-1-list,)
	$(call shoot,$(PAD_SIM),ipad-3-returned,-tayoriDemo opened)

shots: shots-phone shots-pad
	@echo "✅ $(SHOTS)/ に保存した"

# 署名は API キー＋ -allowProvisioningUpdates の自動署名（縁側 engawa・家族掲示板と同形）。
# xcodebuild の全文ログ（build/archive.log・build/export.log）には API キーのパスと Key ID が出る。build/ は gitignore 済み
RELEASE_ENV   = Release.local.env
EXPORT_DIR    = build/export
EXPORT_PLIST  = build/ExportOptions.generated.plist
RELEASE_DD    = build/release
DESTINATION  ?= export
# ビルド番号（CFBundleVersion）: 「年月日.1時分」（例 20261108.10930）。上げるたびに増える。BUILD_NUMBER= で上書き可。
# project.yml の CURRENT_PROJECT_VERSION（1）は開発用のまま書き換えない（コマンドラインの値は両ターゲットに効く）
BUILD_NUMBER ?= $(shell date +%Y%m%d.1%H%M)

# API キー（Release.local.env から読む。環境変数でも渡せる）。値は表示しない
env_value = $(strip $(shell sed -n 's/^$(1)=//p' $(RELEASE_ENV) 2>/dev/null | tail -1))
ASC_KEY_ID    ?= $(call env_value,ASC_KEY_ID)
ASC_ISSUER_ID ?= $(call env_value,ASC_ISSUER_ID)
ASC_KEY_PATH  ?= $(call env_value,ASC_KEY_PATH)
ifeq ($(strip $(ASC_KEY_PATH)),)
ASC_KEY_PATH := $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8
endif
ASC_KEY_PATH := $(patsubst ~/%,$(HOME)/%,$(ASC_KEY_PATH))
ifneq ($(and $(ASC_KEY_ID),$(ASC_ISSUER_ID),$(wildcard $(ASC_KEY_PATH))),)
AUTH_FLAGS = -authenticationKeyPath "$(ASC_KEY_PATH)" -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID)
endif

require-team:
	@test -n "$(TEAM)" || { echo "❌ Team ID がありません（$(CONF)/team-id か TEAM=XXXXXXXXXX）"; exit 1; }

require-asc-key:
	@test -n "$(ASC_KEY_ID)" -a -n "$(ASC_ISSUER_ID)" || { echo "ASC_KEY_ID / ASC_ISSUER_ID がありません。Release.example.env を見て Release.local.env を作ってください"; exit 1; }
	@test -f "$(ASC_KEY_PATH)" || { echo "API キーがありません: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"; exit 1; }

## キーチェーン → Secrets.xcconfig（gitignore）→ generate → archive。値は表示しない。無ければ失敗
archive: require-team require-asc-key
	@umask 077; \
	cid=$$(security find-generic-password -s $(KC_SERVICE) -a client-id -w 2>/dev/null) && [ -n "$$cid" ] || { echo "❌ キーチェーンに $(KC_SERVICE) / client-id がありません（scripts/setup-access.sh のトークンを入れてください）"; exit 1; }; \
	sec=$$(security find-generic-password -s $(KC_SERVICE) -a client-secret -w 2>/dev/null) && [ -n "$$sec" ] || { echo "❌ キーチェーンに $(KC_SERVICE) / client-secret がありません"; exit 1; }; \
	printf 'TAYORI_ACCESS_CLIENT_ID = %s\nTAYORI_ACCESS_CLIENT_SECRET = %s\n' "$$cid" "$$sec" > $(SECRETS); \
	echo "✅ $(SECRETS) を生成した（値は表示しない・gitignore 済み）"
	xcodegen generate
	@mkdir -p build
	rm -rf $(ARCHIVE)
	@echo "ビルド番号 $(BUILD_NUMBER) で archive します"
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -derivedDataPath $(RELEASE_DD) -archivePath $(ARCHIVE) \
	  -allowProvisioningUpdates $(AUTH_FLAGS) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) archive 2>&1 \
	  | tee build/archive.log | grep -E '(error|warning):|ARCHIVE (SUCCEEDED|FAILED)' ; \
	  grep -q 'ARCHIVE SUCCEEDED' build/archive.log || { echo "archive に失敗しました（全文は build/archive.log）"; exit 1; }
	@echo "できました: $(ARCHIVE)（ビルド $(BUILD_NUMBER)）。上げるなら make upload"

## .xcarchive から App Store Connect 向けの .ipa を build/export/ に書き出す（送らない）
export-testflight: require-team require-asc-key
	@test -d $(ARCHIVE) || { echo "$(ARCHIVE) がありません。先に make archive"; exit 1; }
	rm -rf $(EXPORT_DIR)
	@mkdir -p $(EXPORT_DIR)
	cp ExportOptions.plist $(EXPORT_PLIST)
	@plutil -replace teamID -string "$(TEAM)" $(EXPORT_PLIST)
	plutil -replace destination -string $(DESTINATION) $(EXPORT_PLIST)
	@set -o pipefail; xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportPath $(EXPORT_DIR) \
	  -exportOptionsPlist $(EXPORT_PLIST) -allowProvisioningUpdates $(AUTH_FLAGS) 2>&1 \
	  | tee build/export.log | grep -E '(error|warning):|EXPORT (SUCCEEDED|FAILED)|Upload|Uploaded|uploaded' ; \
	  grep -q 'EXPORT SUCCEEDED' build/export.log || { echo "export に失敗しました（全文は build/export.log）"; exit 1; }
	@if [ "$(DESTINATION)" = export ]; then ls -lh $(EXPORT_DIR)/*.ipa; else echo "App Store Connect へ上げました（処理が済むと TestFlight に出る）"; fi

## API キーで App Store Connect へ上げる（先に make archive）。アプリのレコードは App Store Connect で先に作っておく
upload: require-asc-key
	$(MAKE) export-testflight DESTINATION=upload

release: archive upload

icon:
	swift scripts/gen-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

clean:
	rm -rf build build-sim build-check $(PROJECT)
	rm -f Secrets.xcconfig
