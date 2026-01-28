#!/bin/bash
set -e

# Disable analytics for CI/container environments
dart --disable-analytics
flutter --disable-analytics

# Configure Flutter for Android-only development
flutter config --no-enable-web
flutter config --no-enable-linux-desktop
flutter config --no-enable-macos-desktop
flutter config --no-enable-windows-desktop

# Verify the development environment
flutter doctor

# Install project dependencies
cd mobile
flutter pub get
