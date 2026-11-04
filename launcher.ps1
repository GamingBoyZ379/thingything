$file = "C:\Users\jjlev\AppData\Local\Real\workspace\SavedInstances\next.txt"
$key  = 'Registry::HKEY_CLASSES_ROOT\roblox\shell\open\command'
$restartPlace = "9087381198"   # where to relaunch after a crash
$grace = 90                    # seconds to wait after any launch before the crash check applies

function Get-RobloxExe {
    $cmd = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
    if ($cmd -match '^"([^"]+)"' -and (Test-Path $Matches[1])) { return $Matches[1] }

    # registry path is stale: newest version folder that contains the exe
    $dirs = Get-ChildItem "$env:LOCALAPPDATA\Roblox\Versions" -Directory | Sort-Object LastWriteTime -Descending
    foreach ($d in $dirs) {
        $exe = Join-Path $d.FullName "RobloxPlayerBeta.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function Launch($id) {
    $exe = Get-RobloxExe
    if (-not $exe) {
        Write-Host "Could not find RobloxPlayerBeta.exe"
        return
    }
    Write-Host "Using $exe"
    Start-Process $exe -ArgumentList "roblox://experiences/start?placeId=$id"
}

$lastLaunch = Get-Date
$missing = 0

while ($true) {
    if (Test-Path $file) {
        $id = (Get-Content $file -Raw).Trim()
        Remove-Item $file -Force
        if ($id -match '^\d+$') {
            Write-Host "Launching place $id"
            Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 3
            Launch $id
            $lastLaunch = Get-Date
            $missing = 0
        }
    }
    else {
        # crash watchdog
        $running = Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue
        if ($running) {
            $missing = 0
        }
        elseif (((Get-Date) - $lastLaunch).TotalSeconds -gt $grace) {
            $missing++
            if ($missing -ge 3) {   # gone for ~6 seconds in a row
                Write-Host "Roblox is not running, relaunching place $restartPlace"
                Launch $restartPlace
                $lastLaunch = Get-Date
                $missing = 0
            }
        }
    }
    Start-Sleep -Seconds 2
}
