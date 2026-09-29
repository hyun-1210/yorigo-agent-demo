# yorigo-frontend: dart_defines.json 이 있으면 --dart-define-from-file 를 자동 적용
# 사용: .\scripts\run_flutter.ps1 run
#      .\scripts\run_flutter.ps1 build apk --release
#      .\scripts\run_flutter.ps1 build appbundle --release  # 빌드 성공 후 Instagram cropped 백필 실행
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Remaining
)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$Defines = Join-Path $Root "dart_defines.json"

function Has-Arg([string]$Value) {
  return $Remaining -contains $Value
}

function Supports-DartDefines {
  if ($Remaining.Count -eq 0) {
    return $false
  }
  return @("run", "build", "test", "drive") -contains $Remaining[0]
}

function Invoke-InstagramCroppedBackfill {
  if ($env:SKIP_INSTAGRAM_CROPPED_BACKFILL -eq "true") {
    Write-Host "[run_flutter] SKIP_INSTAGRAM_CROPPED_BACKFILL=true, Instagram cropped thumbnail backfill skipped."
    return
  }

  $BackfillScript = Join-Path (Split-Path -Parent $Root) "backend\tools\backfill_instagram_thumbnail_cropped.py"
  if (-not (Test-Path $BackfillScript)) {
    Write-Error "[run_flutter] Instagram cropped thumbnail backfill script not found: $BackfillScript"
    exit 1
  }

  $BackfillArgs = @($BackfillScript)
  if ($env:INSTAGRAM_CROPPED_BACKFILL_LIMIT) {
    $BackfillArgs += @("--limit", $env:INSTAGRAM_CROPPED_BACKFILL_LIMIT)
  }
  if ($env:INSTAGRAM_CROPPED_BACKFILL_FORCE -eq "true") {
    $BackfillArgs += "--force"
  }

  Write-Host "[run_flutter] Running Instagram cropped thumbnail backfill..."
  if (Get-Command python -ErrorAction SilentlyContinue) {
    & python @BackfillArgs
  } elseif (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 @BackfillArgs
  } else {
    Write-Error "[run_flutter] Python not found. Install Python or set SKIP_INSTAGRAM_CROPPED_BACKFILL=true."
    exit 1
  }
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

if ((Test-Path $Defines) -and (Supports-DartDefines)) {
  & flutter @Remaining --dart-define-from-file=$Defines
} else {
  & flutter @Remaining
}
$FlutterExitCode = $LASTEXITCODE
if ($FlutterExitCode -ne 0) {
  exit $FlutterExitCode
}

$ShouldUpdateMobileConfig =
  (Has-Arg "build") -and
  (Has-Arg "appbundle") -and
  ((Has-Arg "--release") -or -not (Has-Arg "--debug") -and -not (Has-Arg "--profile"))

if ($ShouldUpdateMobileConfig) {
  Invoke-InstagramCroppedBackfill
}
