```
release build
cargo make --profile production-mac-arm64 appflowy
```

```
find "./build/macos/Build/Products/Release/AppFlowy.app/Contents/Frameworks" -name "*.framework" -exec codesign --force --sign "Apple Development: huang weilin (5XVW98DW24)" --options runtime {} \;

codesign --force --sign "Apple Development: huang weilin (5XVW98DW24)" --options runtime "./build/macos/Build/Products/Release/AppFlowy.app"

codesign --verify --verbose "./build/macos/Build/Products/Release/AppFlowy.app" 
```