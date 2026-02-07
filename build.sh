#!/bin/bash

set -e

echo "Building Noodle..."

# Build the Swift package
swift build -c release

# Create app bundle structure
mkdir -p Noodle.app/Contents/MacOS
mkdir -p Noodle.app/Contents/Resources

# Copy binary
cp .build/release/Noodle Noodle.app/Contents/MacOS/

echo "Build complete! Noodle.app is ready."
echo ""
echo "To install, drag Noodle.app to your Applications folder."
echo "To run: open Noodle.app"
