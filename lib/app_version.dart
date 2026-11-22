/// Display version for the Cwhale About panel.
///
/// `tool/package_android.ps1` keeps this fallback in sync with pubspec.yaml
/// and passes APP_VERSION explicitly to every release build.
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.1.34',
);
