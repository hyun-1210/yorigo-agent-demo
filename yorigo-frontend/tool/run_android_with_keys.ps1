# Run Flutter on Android device/emulator with local dart-define keys.
# Usage:
#   .\tool\run_android_with_keys.ps1
#   .\tool\run_android_with_keys.ps1 -d emulator-5554

Set-Location "$PSScriptRoot\.."
.\tool\flutter_with_local_keys.ps1 run -d android @args
