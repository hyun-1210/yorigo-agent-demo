# Runs flutter command with local dart-define secrets.
# Usage examples:
#   .\tool\flutter_with_local_keys.ps1 run -d android
#   .\tool\flutter_with_local_keys.ps1 build apk --release
#   .\tool\flutter_with_local_keys.ps1 run -d chrome

Set-Location "$PSScriptRoot\.."

$defineFile = "dart_define.local.json"
if (-not (Test-Path $defineFile)) {
  Write-Error "Missing $defineFile. Run .\tool\init_local_keys.ps1 and fill real keys."
  exit 1
}

try {
  $jsonRaw = Get-Content -Path $defineFile -Raw -Encoding UTF8
  $jsonObj = $jsonRaw | ConvertFrom-Json
} catch {
  Write-Error "Failed to parse $defineFile as JSON: $($_.Exception.Message)"
  exit 1
}

if (-not $jsonObj -or -not $jsonObj.PSObject.Properties -or $jsonObj.PSObject.Properties.Count -eq 0) {
  Write-Error "$defineFile is empty. Add at least one key-value pair."
  exit 1
}

$defineArgs = @()
foreach ($prop in $jsonObj.PSObject.Properties) {
  $key = $prop.Name
  $value = $prop.Value
  if ($null -eq $value) {
    $value = ""
  }
  $defineArgs += "--dart-define=$key=$value"
}

$flutterArgs = @() + $args + $defineArgs
flutter @flutterArgs
