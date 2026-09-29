# Build Flutter web (release) with local dart-define keys.

Set-Location "$PSScriptRoot\.."
.\tool\flutter_with_local_keys.ps1 build web --release @args
