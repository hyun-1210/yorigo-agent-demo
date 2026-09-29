# Build Android APK (release) with local dart-define keys.
# Useful for direct install/testing, not preferred for Play upload.

Set-Location "$PSScriptRoot\.."
.\tool\flutter_with_local_keys.ps1 build apk --release @args
