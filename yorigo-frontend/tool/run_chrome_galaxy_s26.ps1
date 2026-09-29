# Runs Flutter web in Chrome with a window size close to Samsung Galaxy S26 (non-Pro)
# logical viewport: ~360 x 780 dp (1080 x 2340 px at ~3x; GSMarena specs).
# Chrome still shows the address bar, so use ..._tall.ps1 if the page feels vertically cramped.
Set-Location $PSScriptRoot\..
.\tool\flutter_with_local_keys.ps1 run -d chrome --web-browser-flag="--window-size=360,780" @args
