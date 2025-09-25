```
release build
cargo make --profile production-mac-arm64 appflowy
```

```
find "./build/macos/Build/Products/Release/AppFlowy.app/Contents/Frameworks" -name "*.framework" -exec codesign --force --sign "Apple Development: xxxxxxx" --options runtime {} \;

codesign --force --sign "Apple Development: xxxxx" --options runtime "./build/macos/Build/Products/Release/AppFlowy.app"
```