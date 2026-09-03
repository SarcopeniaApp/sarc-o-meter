#!/bin/sh

set -e

echo "==> Configuring Xcode Cloud for Swift Package Plugins"

defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

echo "==> Package plugin validation skipped"
