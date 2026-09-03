#!/bin/sh

set -e

echo "=== XCODE CLOUD: Configure Package Plugin Validation ==="

defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

echo "=== Package plugin validation disabled ==="
