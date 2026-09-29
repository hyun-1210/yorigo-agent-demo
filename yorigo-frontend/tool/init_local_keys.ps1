# Initialize local dart-define file from tracked example template.
# Usage:
#   .\tool\init_local_keys.ps1

Set-Location "$PSScriptRoot\.."

$localFile = "dart_define.local.json"
$exampleFile = "dart_define.example.json"

if (Test-Path $localFile) {
  Write-Host "$localFile already exists. Edit it with your own keys."
  exit 0
}

if (-not (Test-Path $exampleFile)) {
  Write-Error "Missing $exampleFile. Restore the template file first."
  exit 1
}

Copy-Item -Path $exampleFile -Destination $localFile -Force
Write-Host "Created $localFile from $exampleFile."
Write-Host "Open $localFile and replace placeholder values with real keys."
