#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" src/*.swift -o .build/sentient-native-trial
