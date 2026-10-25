#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/build/Ponte Fotos.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -module-cache-path /private/tmp/ponte-fotos-module-cache-v04 -target arm64-apple-macosx14.0 -swift-version 5 -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/PonteFotos" -framework SwiftUI -framework AppKit -framework Photos -framework UniformTypeIdentifiers -framework CryptoKit -framework CoreLocation -framework Network
mkdir -p "$APP/Contents/Resources"
cp Assets/AppLogo.png Assets/AppLogoDisplay.png "$APP/Contents/Resources/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon082.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier br.allan.pontefotos "$APP"
print "Aplicativo criado: $APP"
