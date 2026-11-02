#!/bin/sh

set -e

echo "=== XCODE CLOUD: Configure Package Plugin Validation ==="

defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

echo "=== Package plugin validation disabled ==="

echo "=== Installing CocoaPods dependencies ==="

cd "$CI_PRIMARY_REPOSITORY_PATH"

pod install --repo-update

echo "=== CocoaPods installation completed ==="
