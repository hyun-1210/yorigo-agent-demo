# Build Android App Bundle (release) with local dart-define keys.
# This is the recommended artifact for Play Console.

Set-Location "$PSScriptRoot\.."
.\tool\flutter_with_local_keys.ps1 build appbundle --release @args
