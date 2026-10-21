# Languages

ThunderControl 0.8.26 uses English as its development language and bundles Korean translations. It follows the preferred language macOS selects for this app. Unsupported languages fall back to English.

## Change the app language

In macOS **System Settings > General > Language & Region > Applications**, add or select ThunderControl and choose English or Korean. Restart the app after a change. There is no custom language picker inside ThunderControl, and the app does not rewrite the system language preference.

The English README is `README.md`; `README.ko.md` is the matching Korean guide. Their language links are independent of the app's macOS preference.

## Translation resources

- `Resources/en.lproj/Localizable.strings` contains readable English message keys and values.
- `Resources/ko.lproj/Localizable.strings` contains Korean values for those same keys.
- Both folders include `InfoPlist.strings` for the app name and Local Network permission explanation.
- `Localization.swift` chooses the bundled language and substitutes display values. No translation service or network request is used.

Call `TCText("Request Connection")` for a static message. For a value, use `TCText("Receiver display {0}", "7")`. Keep `{0}`, `{1}` and existing printf directives unchanged in translations. Substitution reads the trusted template once, so a peer name containing `{1}` or `%s` is displayed literally rather than interpreted as another parameter.

Localization is for presentation only. Wire message names, role identifiers, capability checks, Keychain services, bundle identifiers, saved-settings keys and route fields must remain stable and must never depend on translated text. Product names, keyboard shortcuts, addresses and user-supplied peer names are not translated. Technical diagnostic records may remain English.

## Test without controlling another Mac

```sh
bash build.sh
ThunderControl.app/Contents/MacOS/ThunderControl --localization-self-test
ThunderControl.app/Contents/MacOS/ThunderControl --self-test -AppleLanguages '(en)'
ThunderControl.app/Contents/MacOS/ThunderControl --self-test -AppleLanguages '(ko)'
```

The localization test checks both bundled catalogs, key and placeholder parity, English fallback, Korean regional language tags and inert Unicode/peer values. The full memory-only regressions should pass in either app language.

An additional offscreen preview builds the actual settings controls without ordering a window or activating the app:

```sh
ThunderControl.app/Contents/MacOS/ThunderControl \
  --ui-smoke-test /tmp/thundercontrol-ui-en \
  --layout-only --offscreen-localization -AppleLanguages '(en)'
```

Use a new output folder and repeat with `(ko)` for Korean. This path clears the preview PIN, peer address and device list before writing images. It does not start discovery, input, screen capture, login registration or a two-Mac connection. A preview image is not proof of live sharing, physical gesture behavior or end-to-end latency.

The preview also exports `report.json` with the actual tab labels, control text, button bounds/width checks and guarded app state. Its PNGs use AppKit's print renderer, which can omit modern layer-backed tab/button artwork while the window is hidden. They are partial layout previews, not full appearance screenshots, and are not used as public live-sharing proof.
