# Same as run_chrome_galaxy_s26.ps1 but taller window to leave room for Chrome's top UI.
Set-Location $PSScriptRoot\..
.\tool\flutter_with_local_keys.ps1 run -d chrome --web-browser-flag="--window-size=360,900" @args
