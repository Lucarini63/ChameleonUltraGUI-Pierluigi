# Repository Guidelines

## Project Structure & Module Organization

The Flutter application lives in `lib/`. UI pages and dialogs are under `lib/gui/`; device transport is split between `lib/bridge/` and `lib/connector/`; protocol-specific logic belongs in `lib/helpers/mifare_classic/`, `lib/helpers/mifare_ultralight/`, `lib/helpers/mifare_desfire/`, and `lib/helpers/t55xx/`. Translation sources are ARB files in `lib/l10n/`, while generated localization output is excluded from Git. Platform hosts are in `android/`, `ios/`, `windows/`, `linux/`, `macos/`, and `web/`. The Gradle 9-compatible USB serial dependency is intentionally vendored in `third_party/usb_serial/`; preserve its license and avoid editing Pub cache copies.

## Build, Test, and Development Commands

- `flutter pub get` resolves hosted, Git, and local dependencies.
- `flutter analyze` runs the `flutter_lints` rules configured by `analysis_options.yaml`.
- `flutter test` runs the complete suite.
- `flutter test test/mifare_ultralight_password_audit_test.dart` runs one focused test file.
- `flutter run` launches a development build for the selected device.
- `flutter build apk --release` produces the Android APK. Android builds require JDK 17+, SDK 36, and NDK `28.2.13676358`.

## Coding Style & Naming Conventions

Format Dart changes with `dart format`. Follow `flutter_lints`: classes and enums use `UpperCamelCase`, members use `lowerCamelCase`, and files use `snake_case.dart`. Keep hardware and protocol decisions out of widgets when they can be expressed as testable helpers. Add user-visible Italian and English text through the existing localization approach; ARB sources are authoritative.

## Testing Guidelines

Tests use `flutter_test` and live in `test/`. Existing suites cover MIFARE recovery and planning, NTAG password safety, DESFire identification, HF/LF sniff parsing, and LF export. Extend the closest focused file when changing one of these flows, then run both that file and the full suite.

## Commit & Pull Request Guidelines

Upstream history uses concise Conventional Commit-style subjects such as `feat:` and `fix:`. Keep commits scoped and mention the affected protocol or UI area. Pull requests should describe hardware/firmware assumptions, list verification commands, and include screenshots for visible UI changes. Never commit `local.properties`, keystores, credentials, logs, APKs, or generated build directories.
