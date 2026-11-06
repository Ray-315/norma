#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
developer=/Applications/Xcode.app/Contents/Developer
sdk="$developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk"
frameworks="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$developer/Platforms/MacOSX.platform/Developer/usr/lib"
SDKROOT="$sdk" "$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" build --build-tests --sdk "$sdk" --build-system native -j 4 \
  -Xswiftc "-F$frameworks" -Xswiftc "-I$libraries" \
  -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libraries" -Xlinker "-L$libraries"
DYLD_LIBRARY_PATH="$libraries" DYLD_FRAMEWORK_PATH="$frameworks" "$developer/usr/bin/xctest" .build/arm64-apple-macosx/debug/NORMAPackageTests.xctest
/usr/bin/python3 -m unittest discover -s tests/contract -v
