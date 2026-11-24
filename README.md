# Lumen Browser (rename me)

SwiftUI + WKWebView browser. To rename: change `name`, `PRODUCT_NAME`, `CFBundleDisplayName`
and the bundle id in `project.yml`, plus the app name in `.github/workflows/build.yml`.

## Build an unsigned IPA without a Mac
1. Create a GitHub repo and push this folder.
2. Open the Actions tab, run "Build unsigned IPA" (it also runs on every push).
3. Download the `Lumen-ipa` artifact, unzip it, and sign `Lumen.ipa` with Sideloadly / AltStore.
