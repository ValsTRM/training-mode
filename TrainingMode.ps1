#requires -Version 5.1
<#
.SYNOPSIS
    Training Mode: one click to tune this PC for long ML training runs, one click to put everything back.

.DESCRIPTION
    Start training mode:
      * Switches to a temporary COPY of your current power plan, named "Training Mode (temporary)".
        Your own power plans are never edited. The copy has:
          - never sleep / never hibernate (so long runs are not interrupted)
          - display turns off after N minutes
          - CPU allowed to idle down (minimum state 5%, energy preference 25 = the Windows Balanced values)
      * Caps the NVIDIA GPU power limit to a percentage of stock (nvidia-smi -pl). Needs admin.
      * Saves what it is about to change to %LOCALAPPDATA%\TrainingMode\state.json BEFORE changing it,
        and registers a one-time "switch the power plan back at next sign-in" entry (HKCU RunOnce)
        in case the PC restarts while training mode is on. (The GPU limit resets itself on restart.)

    Calm mode (optional, after training is done):
      * Instead of going straight back to your normal plan, switches to a second temporary copy,
        "Calm Mode (temporary)": CPU prefers efficiency (energy preference 60, minimum state 5%:
        the Windows Power saver values, with no speed cap), display off after N minutes, GPU limit
        back to stock. Sleep stays as in your normal plan. Stays on until "Back to normal" or a restart.

    Back to normal:
      * Re-activates your original power plan, deletes the temporary copies, restores the GPU limit,
        removes the one-time entry and the state file.

.EXAMPLE
    .\TrainingMode.ps1                        # open the window (asks for admin once)
    .\TrainingMode.ps1 -Action on             # command line: start with your last-used settings
    .\TrainingMode.ps1 -Action on -GpuPercent 70 -DisplayOffMinutes 10
    .\TrainingMode.ps1 -Action done           # training finished: Calm mode or normal, per your setting
    .\TrainingMode.ps1 -Action calm
    .\TrainingMode.ps1 -Action off
    .\TrainingMode.ps1 -Action status
#>
[CmdletBinding()]
param(
    [ValidateSet('gui', 'on', 'done', 'calm', 'off', 'status')]
    [string]$Action = 'gui',

    # GPU power cap as % of the stock limit (0 = use the last setting, default 75).
    [ValidateRange(0, 100)]
    [int]$GpuPercent = 0,

    # Minutes before the display turns off in training mode (0 = never, -1 = use the last setting).
    [ValidateRange(-1, 240)]
    [int]$DisplayOffMinutes = -1,

    [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'TrainingMode'),

    # Do not ask for administrator rights (the GPU power cap will then not be changed).
    [switch]$NoElevate,

    # Log every change instead of making it (reads are still real). For testing.
    [switch]$DryRun,

    [switch]$Quiet,

    # Internal: set when the script re-launches itself elevated.
    [switch]$Relaunched,

    # Internal/testing: render the window to a PNG file and exit.
    [string]$SnapshotPath
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------------------------
$script:SelfPath       = $PSCommandPath
$script:TempSchemeGuid = 'c0de7a1e-7ea1-4000-8000-00007ea1101a'   # fixed, so a leftover copy is always recognisable
$script:TempSchemeName = 'Training Mode (temporary)'
$script:CalmSchemeGuid = 'c0de7a1e-7ea1-4000-8000-00000ca1a001'
$script:CalmSchemeName = 'Calm Mode (temporary)'
$script:OurSchemes     = @($script:TempSchemeGuid, $script:CalmSchemeGuid)
$script:BalancedGuid   = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:RunOnceKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$script:RunOnceName    = 'TrainingModeSwitchBack'
$script:StatePath      = Join-Path $StateDir 'state.json'
$script:SettingsPath   = Join-Path $StateDir 'settings.json'
$script:LogPath        = Join-Path $StateDir 'log.txt'
$script:PowerCfg       = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$script:GuidRx         = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:DisplayChoices = [int[]]@(0, 1, 2, 5, 10, 15, 30)
$script:AutoChoices    = [int[]]@(5, 10, 15, 30, 60)
$script:LogSink        = $null
$script:Scale          = 1.0
$script:IsAdmin        = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                            [Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------
function Write-TMLog {
    param([string]$Message, [string]$Level = 'info')
    $line = '{0}  [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch { }
    if ($script:LogSink) {
        try { & $script:LogSink $Message $Level } catch { }
    } elseif (-not $Quiet) {
        $color = switch ($Level) { 'warn' { 'Yellow' } 'error' { 'Red' } 'ok' { 'Green' } default { 'Gray' } }
        Write-Host $Message -ForegroundColor $color
    }
}

function Read-JsonFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-TMLog "Could not read ${Path}: $_" 'warn' }
    }
    return $null
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    ($Object | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-Settings {
    $d = [ordered]@{
        gpuPercent         = 75
        displayOffMinutes  = 5
        autoRevert         = $true
        autoRevertMinutes  = 15
        calmAfterTraining  = $true
        lastOriginalScheme = $null
    }
    $s = Read-JsonFile $script:SettingsPath
    if ($s) {
        foreach ($k in @($d.Keys)) {
            if ($s.PSObject.Properties.Name -contains $k) { $d[$k] = $s.$k }
        }
    }
    return $d
}

function Save-Settings($Settings) {
    try { Write-JsonFile $script:SettingsPath $Settings } catch { Write-TMLog "Could not save settings: $_" 'warn' }
}

# Runs a native exe without letting stderr turn into PowerShell errors. -Change = skipped in dry-run mode.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$Change)
    if ($Change -and $DryRun) {
        Write-TMLog ('[dry run] {0} {1}' -f (Split-Path -Leaf $Exe), ($Arguments -join ' '))
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
    }
    $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Output = ((@($output) | Where-Object { $_ }) -join "`n").Trim() }
}

function ConvertTo-Num($Text) {
    $d = 0.0
    $clean = ("$Text" -replace '[^\d\.\-]', '')
    if ([double]::TryParse($clean, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function ConvertTo-LocalTime($Value) {
    if ($Value -is [datetime]) { return $Value.ToLocalTime() }
    try {
        return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture,
                                 [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    } catch { return $null }
}

function Format-Duration([timespan]$Span) {
    if ($Span.TotalMinutes -lt 1) { return 'just now' }
    if ($Span.TotalHours -lt 1) { return ('{0} min' -f [math]::Floor($Span.TotalMinutes)) }
    return ('{0}h {1:D2}m' -f [math]::Floor($Span.TotalHours), $Span.Minutes)
}

# ---------------------------------------------------------------------------------------------
# Power plans
# ---------------------------------------------------------------------------------------------
function Get-PowerSchemes {
    $r = Invoke-Native $script:PowerCfg @('/list')
    $rx = '(' + $script:GuidRx + ')\s+\((.+?)\)\s*(\*)?\s*$'
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match $rx) {
            [pscustomobject]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2]; Active = [bool]$Matches[3] }
        }
    }
}

function Get-ActiveScheme {
    $r = Invoke-Native $script:PowerCfg @('/getactivescheme')
    if ($r.Output -match ('(' + $script:GuidRx + ')\s+\((.+?)\)')) {
        return [pscustomobject]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2] }
    }
    return $null
}

function Test-Scheme([string]$Guid) {
    return [bool](@(Get-PowerSchemes) | Where-Object { $_.Guid -eq $Guid.ToLower() })
}

function Get-SchemeName([string]$Guid) {
    $s = @(Get-PowerSchemes) | Where-Object { $_.Guid -eq $Guid.ToLower() } | Select-Object -First 1
    if ($s) { return $s.Name }
    return $Guid
}

function Get-PlanTweaks([int]$DisplayOffMinutes, [string]$Mode = 'training') {
    if ($Mode -eq 'calm') {
        # Windows Power saver CPU values on this kind of CPU, without its other limits. Sleep is left as in the normal plan.
        return @(
            @{ Sub = 'SUB_VIDEO';     Setting = 'VIDEOIDLE';        Value = ($DisplayOffMinutes * 60); Label = 'display timeout' }
            @{ Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMIN';  Value = 5;                        Label = 'CPU minimum state (P-cores)' }
            @{ Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMIN1'; Value = 5;                        Label = 'CPU minimum state (E-cores)' }
            @{ Sub = 'SUB_PROCESSOR'; Setting = 'PERFEPP';          Value = 60;                       Label = 'CPU energy preference (P-cores)' }
            @{ Sub = 'SUB_PROCESSOR'; Setting = 'PERFEPP1';         Value = 60;                       Label = 'CPU energy preference (E-cores)' }
        )
    }
    @(
        @{ Sub = 'SUB_SLEEP';     Setting = 'STANDBYIDLE';      Value = 0;                        Label = 'never sleep' }
        @{ Sub = 'SUB_SLEEP';     Setting = 'HIBERNATEIDLE';    Value = 0;                        Label = 'never hibernate' }
        @{ Sub = 'SUB_VIDEO';     Setting = 'VIDEOIDLE';        Value = ($DisplayOffMinutes * 60); Label = 'display timeout' }
        @{ Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMIN';  Value = 5;                        Label = 'CPU minimum state (P-cores)' }
        @{ Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMIN1'; Value = 5;                        Label = 'CPU minimum state (E-cores)' }
        @{ Sub = 'SUB_PROCESSOR'; Setting = 'PERFEPP';          Value = 25;                       Label = 'CPU energy preference (P-cores)' }
        @{ Sub = 'SUB_PROCESSOR'; Setting = 'PERFEPP1';         Value = 25;                       Label = 'CPU energy preference (E-cores)' }
    )
}

# One-time entry that switches the power plan back at next sign-in, in case the PC restarts while on.
function Register-SwitchBackAtLogon([string]$OriginalGuid) {
    $cmd = '"{0}" /setactive {1}' -f $script:PowerCfg, $OriginalGuid
    if ($DryRun) { Write-TMLog "[dry run] RunOnce $script:RunOnceName = $cmd"; return }
    try {
        if (-not (Test-Path $script:RunOnceKey)) { New-Item -Path $script:RunOnceKey -Force | Out-Null }
        New-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceName -Value $cmd -PropertyType String -Force | Out-Null
    } catch { Write-TMLog "Could not set up the switch-back-after-restart safety net: $_" 'warn' }
}

function Test-SwitchBackAtLogon {
    return ($null -ne (Get-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceName -ErrorAction SilentlyContinue))
}

function Unregister-SwitchBackAtLogon {
    if ($DryRun) { return }
    Remove-ItemProperty -Path $script:RunOnceKey -Name $script:RunOnceName -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------
# NVIDIA GPU
# ---------------------------------------------------------------------------------------------
function Get-NvidiaSmiPath {
    $c = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @((Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
                     (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
$script:NvSmi = Get-NvidiaSmiPath

function Get-GpuInfo {
    if (-not $script:NvSmi) { return @() }
    $q = 'index,name,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,utilization.gpu,temperature.gpu'
    $r = Invoke-Native $script:NvSmi @("--query-gpu=$q", '--format=csv,noheader,nounits')
    if ($r.ExitCode -ne 0) { return @() }
    $list = @()
    foreach ($line in ($r.Output -split "`n")) {
        $p = @($line -split ',' | ForEach-Object { $_.Trim() })
        if ($p.Count -lt 9) { continue }
        $idx = ConvertTo-Num $p[0]
        if ($null -eq $idx) { continue }
        $list += [pscustomobject]@{
            Index        = [int]$idx
            Name         = $p[1]
            Draw         = (ConvertTo-Num $p[2])
            Limit        = (ConvertTo-Num $p[3])
            DefaultLimit = (ConvertTo-Num $p[4])
            MinLimit     = (ConvertTo-Num $p[5])
            MaxLimit     = (ConvertTo-Num $p[6])
            Util         = (ConvertTo-Num $p[7])
            Temp         = (ConvertTo-Num $p[8])
        }
    }
    return $list
}

function Get-GpuTargetWatts($Gpu, [int]$Percent) {
    $t = [math]::Round($Gpu.DefaultLimit * $Percent / 100)
    if ($null -ne $Gpu.MinLimit) { $t = [math]::Max($t, [math]::Ceiling($Gpu.MinLimit)) }
    if ($null -ne $Gpu.MaxLimit) { $t = [math]::Min($t, [math]::Floor($Gpu.MaxLimit)) }
    return [int]$t
}

function Set-GpuPowerLimit([int]$Index, [double]$Watts) {
    $w = [int][math]::Round($Watts)
    $r = Invoke-Native $script:NvSmi @('-i', "$Index", '-pl', "$w") -Change
    if ($DryRun) { return $true }
    $g = @(Get-GpuInfo) | Where-Object { $_.Index -eq $Index } | Select-Object -First 1
    if ($g -and $null -ne $g.Limit -and [math]::Abs($g.Limit - $w) -lt 1.5) { return $true }
    $why = if ($r.Output) { ($r.Output -replace '\s+', ' ') } else { "exit code $($r.ExitCode)" }
    Write-TMLog "GPU ${Index}: could not set the power limit to $w W ($why)" 'warn'
    return $false
}

# ---------------------------------------------------------------------------------------------
# Core: start / back to normal / status
# ---------------------------------------------------------------------------------------------
function Get-StateMode($State) {
    if (-not $State) { return 'normal' }
    if ($State.PSObject.Properties.Name -contains 'mode' -and $State.mode) { return [string]$State.mode }
    return 'training'   # records from before Calm mode existed
}

function Get-ModeSince($State) {
    if (-not $State) { return $null }
    if ($State.PSObject.Properties.Name -contains 'modeSince' -and $State.modeSince) { return (ConvertTo-LocalTime $State.modeSince) }
    return (ConvertTo-LocalTime $State.startedAt)
}

function Get-ModeScheme([string]$Mode) {
    if ($Mode -eq 'calm') { return $script:CalmSchemeGuid }
    return $script:TempSchemeGuid
}

function Get-ModeLabel([string]$Mode) {
    switch ($Mode) { 'calm' { 'Calm mode' } 'training' { 'Training mode' } default { 'Normal mode' } }
}

function Set-StateProp($State, [string]$Name, $Value) {
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

# Creates (or re-creates) one of our temporary plans as a copy of $FromGuid, then applies $Tweaks. Throws on failure.
function New-TempPlan([string]$Guid, [string]$Name, [string]$FromGuid, $Tweaks) {
    if (Test-Scheme $Guid) {
        if ((Get-ActiveScheme).Guid -eq $Guid) { [void](Invoke-Native $script:PowerCfg @('/setactive', $FromGuid) -Change) }
        [void](Invoke-Native $script:PowerCfg @('/delete', $Guid) -Change)
    }
    $r = Invoke-Native $script:PowerCfg @('/duplicatescheme', $FromGuid, $Guid) -Change
    if ($r.ExitCode -ne 0) { throw "could not create the temporary power plan ($($r.Output))" }
    [void](Invoke-Native $script:PowerCfg @('/changename', $Guid, $Name, 'Temporary plan made by Training Mode. Safe to delete.') -Change)
    foreach ($t in $Tweaks) {
        $ac = Invoke-Native $script:PowerCfg @('/setacvalueindex', $Guid, $t.Sub, $t.Setting, "$($t.Value)") -Change
        [void](Invoke-Native $script:PowerCfg @('/setdcvalueindex', $Guid, $t.Sub, $t.Setting, "$($t.Value)") -Change)
        if ($ac.ExitCode -ne 0) { Write-TMLog "  (skipped '$($t.Label)': not available on this PC)" }
    }
}

# Records your normal settings (power plan + GPU limits) BEFORE anything changes, and sets up the restart safety net.
# Returns the new record, or $null if it could not be saved (then nothing has been changed).
function New-NormalSnapshot([string]$Mode) {
    $active = Get-ActiveScheme
    if (-not $active) { Write-TMLog 'Could not read the active power plan.' 'error'; return $null }
    $settings = Get-Settings
    $original = $active

    if ($script:OurSchemes -contains $active.Guid) {
        # One of our temporary plans is active but its record is gone. Pick a sensible plan to return to.
        $fallback = $script:BalancedGuid
        if ($settings.lastOriginalScheme -and (Test-Scheme $settings.lastOriginalScheme)) { $fallback = $settings.lastOriginalScheme }
        $original = [pscustomobject]@{ Guid = $fallback; Name = (Get-SchemeName $fallback) }
        Write-TMLog "Found a leftover temporary plan. Will return to '$($original.Name)' afterwards." 'warn'
    }

    $gpuPlan = @()
    foreach ($g in @(Get-GpuInfo)) {
        if ($null -eq $g.DefaultLimit -or $null -eq $g.Limit) { continue }
        $gpuPlan += [pscustomobject]@{
            Index         = $g.Index
            Name          = $g.Name
            OriginalLimit = $g.Limit
            TargetLimit   = $g.Limit
            Applied       = $false
        }
    }

    $now = (Get-Date).ToString('o')
    $state = [pscustomobject]@{
        version            = 2
        mode               = $Mode
        startedAt          = $now
        modeSince          = $now
        originalScheme     = $original.Guid
        originalSchemeName = $original.Name
        tempScheme         = $script:TempSchemeGuid
        gpus               = $gpuPlan
        gpuPercent         = 100
        displayOffMinutes  = 0
        dryRun             = [bool]$DryRun
    }
    try { Write-JsonFile $script:StatePath $state }
    catch { Write-TMLog "Could not save the record of your current settings, so nothing was changed: $_" 'error'; return $null }
    $settings.lastOriginalScheme = $original.Guid
    Save-Settings $settings
    Register-SwitchBackAtLogon $original.Guid
    return $state
}

# Moves to training or Calm mode. Always builds the plan from the RECORDED original, never from whatever is active.
function Switch-Mode {
    param($State, [string]$Mode, [int]$GpuPercent, [int]$DisplayOffMinutes)
    $target    = Get-ModeScheme $Mode
    $other     = if ($Mode -eq 'calm') { $script:TempSchemeGuid } else { $script:CalmSchemeGuid }
    $name      = if ($Mode -eq 'calm') { $script:CalmSchemeName } else { $script:TempSchemeName }
    $orig      = $State.originalScheme
    $origName  = $State.originalSchemeName
    $disp      = if ($DisplayOffMinutes -eq 0) { 'display stays on' } else { "display off after $DisplayOffMinutes min" }

    # 1. Power plan: build the copy, activate it, then remove the other mode's copy.
    try {
        New-TempPlan $target $name $orig (Get-PlanTweaks $DisplayOffMinutes $Mode)
        $r = Invoke-Native $script:PowerCfg @('/setactive', $target) -Change
        if ($r.ExitCode -ne 0) { throw "could not switch to the temporary power plan ($($r.Output))" }
        if (Test-Scheme $other) {
            $r = Invoke-Native $script:PowerCfg @('/delete', $other) -Change
            if ($r.ExitCode -ne 0) { Write-TMLog "Could not delete the previous temporary plan: $($r.Output)" 'warn' }
        }
        if ($Mode -eq 'calm') {
            Write-TMLog "Power plan: Calm copy of '$origName' active (CPU prefers efficiency, $disp, sleep as in your normal plan)." 'ok'
        } else {
            Write-TMLog "Power plan: training copy of '$origName' active (no sleep, $disp, CPU can idle down)." 'ok'
        }
    } catch {
        Write-TMLog "Power plan step failed: $_" 'error'
        Write-TMLog 'Going back to your normal settings instead...' 'warn'
        [void](Disable-TrainingMode)
        return $false
    }

    # 2. GPU: training = cap at the chosen %, Calm = back to your normal limit.
    if ($Mode -eq 'training' -and -not $script:NvSmi) {
        Write-TMLog 'No NVIDIA tools (nvidia-smi) found, so the GPU power cap was skipped.' 'warn'
    }
    $now = @(Get-GpuInfo)
    $gpuFailed = $false
    foreach ($g in @($State.gpus)) {
        $info = $now | Where-Object { $_.Index -eq $g.Index } | Select-Object -First 1
        $want = [int][math]::Round($g.OriginalLimit)
        if ($Mode -eq 'training' -and $info -and $null -ne $info.DefaultLimit) { $want = Get-GpuTargetWatts $info $GpuPercent }
        $g.TargetLimit = $want
        if (-not $DryRun -and $info -and $null -ne $info.Limit -and [math]::Abs($info.Limit - $want) -lt 1.5) {
            $g.Applied = $true
            Write-TMLog ('GPU {0}: power cap is at {1} W.' -f $g.Index, $want) 'ok'
        } elseif (Set-GpuPowerLimit $g.Index $want) {
            $g.Applied = $true
            if ($Mode -eq 'training') {
                Write-TMLog ('GPU {0}: power cap {1:N0} W -> {2} W ({3}% of stock).' -f $g.Index, $g.OriginalLimit, $want, $GpuPercent) 'ok'
            } else {
                Write-TMLog ('GPU {0}: power cap back to {1} W (your normal limit).' -f $g.Index, $want) 'ok'
            }
        } else {
            $g.Applied = $false
            $gpuFailed = $true
        }
    }
    if ($gpuFailed -and -not $script:IsAdmin) {
        Write-TMLog 'Changing the GPU power cap needs administrator rights. Open the app normally and accept the admin prompt.' 'warn'
    }

    # 3. Update the record (the original plan and GPU limits are never overwritten).
    Set-StateProp $State 'mode' $Mode
    Set-StateProp $State 'modeSince' ((Get-Date).ToString('o'))
    Set-StateProp $State 'displayOffMinutes' $DisplayOffMinutes
    if ($Mode -eq 'training') { Set-StateProp $State 'gpuPercent' $GpuPercent }
    Write-JsonFile $script:StatePath $State
    Register-SwitchBackAtLogon $orig
    Write-TMLog "$(Get-ModeLabel $Mode) is ON." 'ok'
    return $true
}

function Start-Mode {
    param([ValidateSet('training', 'calm')][string]$Mode, [int]$GpuPercent, [int]$DisplayOffMinutes)
    $state = Read-JsonFile $script:StatePath
    if ($state) {
        if ((Get-StateMode $state) -eq $Mode) {
            Write-TMLog "$(Get-ModeLabel $Mode) is already on. Switch back to normal first to change its settings." 'warn'
            return $false
        }
    } else {
        $state = New-NormalSnapshot $Mode
        if (-not $state) { return $false }
    }
    return (Switch-Mode $state $Mode $GpuPercent $DisplayOffMinutes)
}

function Enable-TrainingMode {
    param([int]$GpuPercent, [int]$DisplayOffMinutes)
    return (Start-Mode 'training' $GpuPercent $DisplayOffMinutes)
}

# Training finished: Calm mode or normal, depending on the "after training is done" setting.
function Complete-Training {
    $state = Read-JsonFile $script:StatePath
    if ((Get-StateMode $state) -ne 'training') { Write-TMLog 'Training mode is not on.' 'warn'; return $false }
    $s = Get-Settings
    if ($s.calmAfterTraining) {
        Write-TMLog 'Training is done. Switching to Calm mode to save energy.'
        return (Start-Mode 'calm' 0 ([int]$state.displayOffMinutes))
    }
    Write-TMLog 'Training is done. Switching back to normal.'
    return (Disable-TrainingMode)
}

function Disable-TrainingMode {
    $state = Read-JsonFile $script:StatePath
    $settings = Get-Settings
    $allOk = $true

    # 1. Power plan: back to the recorded original, then delete the temporary copies.
    try {
        $active = Get-ActiveScheme
        if ($state -or ($active -and $script:OurSchemes -contains $active.Guid)) {
            $orig = $script:BalancedGuid
            if ($state -and $state.originalScheme) { $orig = $state.originalScheme }
            elseif ($settings.lastOriginalScheme) { $orig = $settings.lastOriginalScheme }
            if ($script:OurSchemes -contains $orig -or -not (Test-Scheme $orig)) {
                Write-TMLog "Your original power plan ($orig) no longer exists, so switching to Balanced." 'warn'
                $orig = $script:BalancedGuid
            }
            if (-not $active -or $active.Guid -ne $orig) {
                $r = Invoke-Native $script:PowerCfg @('/setactive', $orig) -Change
                if ($r.ExitCode -ne 0) { throw "could not switch back ($($r.Output))" }
            }
            Write-TMLog "Power plan: back to '$(Get-SchemeName $orig)'." 'ok'
        }
        foreach ($sg in $script:OurSchemes) {
            if (Test-Scheme $sg) {
                $r = Invoke-Native $script:PowerCfg @('/delete', $sg) -Change
                if ($r.ExitCode -ne 0) { Write-TMLog "Could not delete a temporary plan: $($r.Output)" 'warn'; $allOk = $false }
                else { Write-TMLog 'Removed the temporary power plan.' }
            }
        }
    } catch {
        Write-TMLog "Power plan restore failed: $_" 'error'
        $allOk = $false
    }

    # 2. GPU power limit.
    if ($state -and $state.gpus) {
        $now = @(Get-GpuInfo)
        foreach ($g in @($state.gpus)) {
            $cur = $now | Where-Object { $_.Index -eq $g.Index } | Select-Object -First 1
            if ($cur -and $null -ne $cur.Limit -and [math]::Abs($cur.Limit - $g.OriginalLimit) -lt 1.5) {
                Write-TMLog ('GPU {0}: power cap is at {1:N0} W (normal).' -f $g.Index, $g.OriginalLimit) 'ok'
                continue
            }
            if (Set-GpuPowerLimit $g.Index $g.OriginalLimit) {
                Write-TMLog ('GPU {0}: power cap restored to {1:N0} W.' -f $g.Index, $g.OriginalLimit) 'ok'
            } else {
                $allOk = $false
                if (-not $script:IsAdmin) {
                    Write-TMLog 'Restoring the GPU power cap needs administrator rights. Open the app normally (it asks for admin), or just restart the PC.' 'warn'
                }
            }
        }
    }

    # 3. Safety net + record.
    if ($allOk) {
        Unregister-SwitchBackAtLogon
        if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
        Write-TMLog 'Back to normal.' 'ok'
    } else {
        if ($state) { Register-SwitchBackAtLogon $state.originalScheme }
        Write-TMLog 'Some settings could not be restored (see above). Try "Back to normal" again.' 'warn'
    }
    return $allOk
}

# Re-applies training settings if another app (e.g. a game booster) switched the plan or the GPU cap was reset.
function Repair-TrainingMode {
    $state = Read-JsonFile $script:StatePath
    if (-not $state) { return }
    $mode = Get-StateMode $state
    $want = Get-ModeScheme $mode
    if (Test-Scheme $want) {
        $active = Get-ActiveScheme
        if (-not $active -or $active.Guid -ne $want) {
            $r = Invoke-Native $script:PowerCfg @('/setactive', $want) -Change
            if ($r.ExitCode -eq 0) { Write-TMLog "Power plan: '$(Get-SchemeName $want)' is active again." 'ok' }
            else { Write-TMLog "Could not re-activate the temporary plan: $($r.Output)" 'warn' }
        }
    } else {
        Write-TMLog "The temporary plan is gone. Click ""Back to normal"", then start $((Get-ModeLabel $mode).ToLower()) again." 'warn'
    }
    foreach ($g in @($state.gpus)) {
        if (Set-GpuPowerLimit $g.Index $g.TargetLimit) {
            $g.Applied = $true
            Write-TMLog ('GPU {0}: power cap set to {1} W again.' -f $g.Index, $g.TargetLimit) 'ok'
        }
    }
    Write-JsonFile $script:StatePath $state
    Register-SwitchBackAtLogon $state.originalScheme
}

# If the PC restarted / the user signed out while training mode was on, the one-time entry has already
# switched the power plan back. Finish the job: delete the temporary plan and the record.
function Invoke-Reconcile {
    $state = Read-JsonFile $script:StatePath
    if (-not $state -or $state.dryRun) { return }
    $active = Get-ActiveScheme
    if (-not (Test-SwitchBackAtLogon) -and $active -and -not ($script:OurSchemes -contains $active.Guid)) {
        Write-TMLog "The PC restarted (or you signed out) while $((Get-ModeLabel (Get-StateMode $state)).ToLower()) was on. Finishing the switch back..." 'warn'
        [void](Disable-TrainingMode)
    }
}

function Get-TMStatus {
    $state = Read-JsonFile $script:StatePath
    $active = Get-ActiveScheme
    $gpus = @(Get-GpuInfo)
    $warnings = @()
    $mode = Get-StateMode $state
    if ($state -and -not $state.dryRun) {
        if ($active -and $active.Guid -ne (Get-ModeScheme $mode)) {
            $warnings += "Another program switched the power plan to '$($active.Name)'."
        }
        foreach ($g in @($state.gpus)) {
            $cur = $gpus | Where-Object { $_.Index -eq $g.Index } | Select-Object -First 1
            if ($g.Applied -and $cur -and $null -ne $cur.Limit -and [math]::Abs($cur.Limit - $g.TargetLimit) -ge 1.5) {
                $warnings += ('GPU power cap is {0:N0} W instead of {1} W (reset by a restart or another app).' -f $cur.Limit, $g.TargetLimit)
            }
        }
    }
    return [pscustomobject]@{
        On           = [bool]$state
        Mode         = $mode
        State        = $state
        ActiveScheme = $active
        Gpus         = $gpus
        Warnings     = $warnings
    }
}

function Show-CliStatus {
    $st = Get-TMStatus
    $deg = [char]0x00B0
    if ($st.On) {
        $started = Get-ModeSince $st.State
        $since = if ($started) { ' since {0:t} ({1})' -f $started, (Format-Duration ((Get-Date) - $started)) } else { '' }
        Write-Host "Mode:          $(Get-ModeLabel $st.Mode)$since" -ForegroundColor Green
    } else {
        Write-Host 'Mode:          Normal (your usual settings)'
    }
    if ($st.ActiveScheme) { Write-Host ('Power plan:    {0}' -f $st.ActiveScheme.Name) }
    foreach ($g in $st.Gpus) {
        Write-Host ('GPU {0}:         {1}: cap {2:N0} W (stock {3:N0} W), drawing {4:N0} W, {5:N0}% busy, {6:N0}{7}C' -f
                    $g.Index, $g.Name, $g.Limit, $g.DefaultLimit, $g.Draw, $g.Util, $g.Temp, $deg)
    }
    foreach ($w in $st.Warnings) { Write-Host "Note: $w" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------------------------
# Automatic switch-back
# ---------------------------------------------------------------------------------------------
# Decides from GPU power draw (utilisation alone is too noisy: an idle desktop can read 50%).
#   busy  = drawing >= 35% of stock power (min 70 W). Must hold for 60 s straight to "arm".
#   idle  = drawing <  25% of stock power (min 50 W).
#   fire  = armed, then idle for $Minutes straight. Anything in between resets the idle clock.
function Step-AutoSwitchBack {
    param($Tracker, $Draw, $StockLimit, [datetime]$Now, [int]$Minutes)
    $Tracker.Fire = $false
    if ($null -eq $Draw -or $null -eq $StockLimit -or $StockLimit -le 0) { return $Tracker }
    $busyW = [math]::Max(70, 0.35 * $StockLimit)
    $idleW = [math]::Max(50, 0.25 * $StockLimit)
    if ($Draw -ge $busyW) {
        if (-not $Tracker.BusySince) { $Tracker.BusySince = $Now }
        if (($Now - $Tracker.BusySince).TotalSeconds -ge 60) { $Tracker.Armed = $true }
        $Tracker.IdleSince = $null
    } elseif ($Draw -lt $idleW) {
        $Tracker.BusySince = $null
        if ($Tracker.Armed -and -not $Tracker.IdleSince) { $Tracker.IdleSince = $Now }
    } else {
        $Tracker.BusySince = $null
        $Tracker.IdleSince = $null
    }
    if ($Tracker.Armed -and $Tracker.IdleSince -and ($Now - $Tracker.IdleSince).TotalMinutes -ge $Minutes) { $Tracker.Fire = $true }
    return $Tracker
}

function Reset-AutoSwitchBack {
    $script:RT.Armed = $false
    $script:RT.BusySince = $null
    $script:RT.IdleSince = $null
    $script:RT.Fire = $false
}

# ---------------------------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------------------------
function Px([double]$v) { return [int][math]::Round($v * $script:Scale) }

function New-Label {
    param([string]$Text, [int]$Width = 0, $Font = $null, $Color = $null)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    if ($Width -gt 0) { $l.MaximumSize = New-Object System.Drawing.Size($Width, 0) }
    if ($Font) { $l.Font = $Font }
    if ($Color) { $l.ForeColor = $Color }
    $l.Margin = New-Object System.Windows.Forms.Padding(0, (Px 3), 0, (Px 3))
    return $l
}

function New-Section([string]$Text) {
    $l = New-Label $Text.ToUpper() 0 (New-Object System.Drawing.Font('Segoe UI Semibold', 8.25)) $script:C.Muted
    $l.Margin = New-Object System.Windows.Forms.Padding(0, (Px 14), 0, (Px 2))
    return $l
}

function New-Grid([int]$Width, [int]$LeftWidth) {
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.ColumnCount = 2
    $t.RowCount = 0
    $t.AutoSize = $true
    $t.AutoSizeMode = 'GrowAndShrink'
    $t.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$LeftWidth)))
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]($Width - $LeftWidth))))
    return $t
}

function Add-GridRow($Grid, $Left, $Right = $null) {
    $r = $Grid.RowCount
    $Grid.RowCount = $r + 1
    [void]$Grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $Grid.Controls.Add($Left, 0, $r)
    if ($Right) { $Grid.Controls.Add($Right, 1, $r) } else { $Grid.SetColumnSpan($Left, 2) }
}

function New-DotIcon([System.Drawing.Color]$Color) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('T', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
    $g.Dispose(); $brush.Dispose(); $font.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Show-MainWindow {
    $f = $script:UI.Form
    $f.Show()
    $f.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $f.Activate()
}

function Update-CapLabel {
    $UI = $script:UI
    $pct = $UI.Track.Value
    $dot = [char]0x00B7
    $g = $UI.Gpus | Select-Object -First 1
    if ($g -and $null -ne $g.DefaultLimit) {
        $UI.CapVal.Text = ('{0}%  {1}  {2} W  (stock {3:N0} W)' -f $pct, $dot, (Get-GpuTargetWatts $g $pct), $g.DefaultLimit)
    } else {
        $UI.CapVal.Text = '{0}%  (no NVIDIA GPU found)' -f $pct
    }
}

function Save-UiSettings {
    $UI = $script:UI
    if (-not $UI -or -not $UI.Ready) { return }
    $s = Get-Settings
    $s.gpuPercent        = [int]$UI.Track.Value
    $s.displayOffMinutes = $script:DisplayChoices[[math]::Max(0, $UI.Display.SelectedIndex)]
    $s.autoRevert        = [bool]$UI.Auto.Checked
    $s.autoRevertMinutes = $script:AutoChoices[[math]::Max(0, $UI.AutoMins.SelectedIndex)]
    $s.calmAfterTraining = [bool]$UI.Calm.Checked
    Save-Settings $s
}

# $To: 'training' | 'calm' | 'normal' | 'done' (training finished: Calm or normal per the setting)
function Invoke-ModeChange([string]$To) {
    $UI = $script:UI; $RT = $script:RT
    if ($RT.Busy -or -not $To) { return }
    $RT.Busy = $true
    $UI.Button.Enabled = $false
    $UI.Button2.Enabled = $false
    $UI.Form.UseWaitCursor = $true
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $mins = $script:DisplayChoices[[math]::Max(0, $UI.Display.SelectedIndex)]
        switch ($To) {
            'training' {
                Save-UiSettings
                Reset-AutoSwitchBack
                [void](Start-Mode 'training' $UI.Track.Value $mins)
            }
            'calm' {
                Save-UiSettings
                [void](Start-Mode 'calm' 0 $mins)
            }
            'done' {
                Save-UiSettings
                [void](Complete-Training)
            }
            'normal' {
                if (Test-Path -LiteralPath $script:StatePath) { [void](Disable-TrainingMode) }
            }
        }
    } catch {
        Write-TMLog "Unexpected error: $_" 'error'
    } finally {
        $RT.Busy = $false
        $UI.Button.Enabled = $true
        $UI.Button2.Enabled = $true
        $UI.Form.UseWaitCursor = $false
        Update-Ui
    }
}

function Update-Ui {
    param([switch]$Tick)
    $UI = $script:UI; $RT = $script:RT; $C = $script:C
    if ($RT.Busy) { return }
    $st = Get-TMStatus
    $UI.Gpus = $st.Gpus
    $on = $st.On
    $dot = [char]0x00B7
    $deg = [char]0x00B0

    # Live readout
    if ($st.Gpus.Count -gt 0) {
        $lines = foreach ($g in $st.Gpus) {
            '{0:N0} W now  {1}  cap {2:N0} W  {1}  {3:N0}% busy  {1}  {4:N0}{5}C' -f $g.Draw, $dot, $g.Limit, $g.Util, $g.Temp, $deg
        }
        $UI.GpuVal.Text = (@($lines) -join "`n")
    } elseif (-not $script:NvSmi) {
        $UI.GpuVal.Text = 'No NVIDIA GPU tools found'
    } else {
        $UI.GpuVal.Text = 'Could not read the GPU'
    }
    $UI.PlanVal.Text = if ($st.ActiveScheme) { $st.ActiveScheme.Name } else { 'unknown' }

    # Header, buttons, settings
    $mode = $st.Mode
    $calmNext = [bool]$UI.Calm.Checked
    $autoText = ''
    $since = Get-ModeSince $st.State
    $sinceText = if ($since) { 'Since {0:t}  ({1})' -f $since, (Format-Duration ((Get-Date) - $since)) } else { '' }
    $dispText = if ($st.State -and [int]$st.State.displayOffMinutes -eq 0) { 'never' } elseif ($st.State) { "$($st.State.displayOffMinutes) min" } else { '' }
    switch ($mode) {
        'training' {
            $UI.Title.Text = 'Training mode is ON'
            $UI.Title.ForeColor = $C.Green
            $UI.Sub.Text = '{0}   {1}   GPU cap {2}%, display off after {3}' -f $sinceText, $dot, $st.State.gpuPercent, $dispText
            if ($calmNext) {
                $UI.PrimaryAction = 'done';     $UI.Button.Text = 'Training done: switch to Calm mode'; $UI.Button.BackColor = $C.Teal
                $UI.SecondaryAction = 'normal'; $UI.Button2.Text = 'Back to normal instead'
            } else {
                $UI.PrimaryAction = 'normal';   $UI.Button.Text = 'Back to normal';                     $UI.Button.BackColor = $C.Blue
                $UI.SecondaryAction = 'calm';   $UI.Button2.Text = 'Switch to Calm mode instead'
            }
            $icon = $UI.IconOn
            $UI.Tray.Text = 'Training Mode: training'
        }
        'calm' {
            $UI.Title.Text = 'Calm mode is ON'
            $UI.Title.ForeColor = $C.Teal
            $UI.Sub.Text = '{0}   {1}   Saving energy: CPU prefers efficiency, GPU at its normal limit, display off after {2}' -f $sinceText, $dot, $dispText
            $UI.PrimaryAction = 'normal';     $UI.Button.Text = 'Back to normal';      $UI.Button.BackColor = $C.Blue
            $UI.SecondaryAction = 'training'; $UI.Button2.Text = 'Start training mode'
            $icon = $UI.IconCalm
            $UI.Tray.Text = 'Training Mode: calm'
            Reset-AutoSwitchBack
        }
        default {
            $UI.Title.Text = 'Normal mode'
            $UI.Title.ForeColor = $C.Ink
            $UI.Sub.Text = 'Your usual settings are active.'
            $UI.PrimaryAction = 'training'; $UI.Button.Text = 'Start training mode'; $UI.Button.BackColor = $C.Green
            $UI.SecondaryAction = 'calm';   $UI.Button2.Text = 'Calm mode (save energy without training)'
            $icon = $UI.IconOff
            $UI.Tray.Text = 'Training Mode: normal'
            Reset-AutoSwitchBack
        }
    }
    if ($st.State -and $st.State.dryRun) { $UI.Sub.Text += '   [dry run]' }
    $UI.Tray.Icon = $icon
    $UI.Form.Icon = $icon
    $UI.MiTrain.Enabled  = $mode -ne 'training'
    $UI.MiCalm.Enabled   = $mode -ne 'calm'
    $UI.MiDone.Visible   = $mode -eq 'training'
    $UI.MiNormal.Enabled = $mode -ne 'normal'
    $UI.Track.Enabled = $mode -ne 'training'
    $UI.Display.Enabled = $mode -ne 'training'

    # Detect when training is done (GPU busy for a while, then idle for N minutes).
    if ($mode -eq 'training' -and $UI.Auto.Checked) {
        $mins = $script:AutoChoices[[math]::Max(0, $UI.AutoMins.SelectedIndex)]
        # Use the GPU working hardest relative to its stock limit.
        $g = $st.Gpus | Where-Object { $null -ne $_.Draw -and $_.DefaultLimit -gt 0 } |
             Sort-Object -Property @{ Expression = { $_.Draw / $_.DefaultLimit } } -Descending | Select-Object -First 1
        if (-not $g) {
            $autoText = 'Detecting the end of training needs an NVIDIA GPU power reading.'
        } else {
            if ($Tick) { [void](Step-AutoSwitchBack $RT $g.Draw $g.DefaultLimit (Get-Date) $mins) }
            $next = if ($calmNext) { 'Calm mode' } else { 'normal' }
            if ($RT.Fire) {
                Write-TMLog "GPU idle for $mins min, so training looks finished." 'ok'
                Reset-AutoSwitchBack
                Invoke-ModeChange 'done'
                $UI.Tray.ShowBalloonTip(5000, 'Training Mode', "Training looks finished. Switched to $next.",
                                        [System.Windows.Forms.ToolTipIcon]::Info)
                return
            }
            if ($RT.Armed -and $RT.IdleSince) {
                $autoText = 'GPU idle for {0} min. Switching to {1} at {2} min.' -f [math]::Floor(((Get-Date) - $RT.IdleSince).TotalMinutes), $next, $mins
            } elseif ($RT.Armed) {
                $autoText = 'Training detected. Will switch to {0} after {1} min of GPU idle.' -f $next, $mins
            } else {
                $autoText = 'Waiting for training to start, then watching for it to finish.'
            }
        }
    }
    $UI.AutoStatus.Text = $autoText
    $UI.AutoStatus.Visible = [bool]$autoText

    # Warnings
    $warn = @($st.Warnings)
    if (-not $script:IsAdmin -and -not $DryRun -and $script:NvSmi) {
        $warn += 'Not running as administrator, so the GPU power cap cannot be changed.'
    }
    $UI.Warn.Text = ($warn -join "`n")
    $UI.Warn.Visible = $warn.Count -gt 0
    $UI.Fix.Text = 'Re-apply {0} settings' -f $(if ($mode -eq 'calm') { 'Calm mode' } else { 'training' })
    $UI.Fix.Visible = $on -and @($st.Warnings).Count -gt 0
}

function Show-WhatChanges {
    $b = [char]0x2022
    $msg = @(
        'Start training mode:'
        "  $b Switches to a temporary COPY of your current power plan (""$script:TempSchemeName""). Your own plans are never edited. The copy:"
        '       - never sleeps or hibernates, so long runs are not interrupted'
        '       - turns the display off after the time you pick'
        '       - lets the CPU idle down when it is only feeding the GPU (minimum state 5%, energy preference 25: the Windows Balanced values)'
        "  $b Caps the GPU power limit at the % you pick (nvidia-smi -pl)."
        "  $b Saves your originals first, in $StateDir"
        "  $b If the PC restarts while it is on, the power plan switches back at the next sign-in (the GPU cap resets on restart by itself)."
        ''
        'Calm mode (after training is done, if ticked, or any time from the button):'
        "  $b Switches to a different temporary copy (""$script:CalmSchemeName"") where the CPU prefers efficiency (energy preference 60, minimum state 5%: the Windows Power saver values, with no speed cap), and the display turns off after the time you pick."
        "  $b Puts the GPU power limit back to normal. Sleep stays as in your normal plan."
        "  $b Stays on until you click Back to normal. A restart also returns you to normal."
        ''
        'Back to normal:'
        "  $b Re-activates your original power plan and deletes the temporary copies."
        "  $b Restores the GPU power limit to what it was."
        ''
        'Nothing else on your system is changed.'
    ) -join "`n"
    [void][System.Windows.Forms.MessageBox]::Show($script:UI.Form, $msg, 'What Training Mode changes', 'OK', 'Information')
}

function Show-TrainingModeGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try {
        Add-Type -Namespace TMNative -Name User32 -ErrorAction Stop -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
        [void][TMNative.User32]::SetProcessDPIAware()
    } catch { }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if (-not $SnapshotPath) {
        $created = $false
        try { $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\TrainingModeApp', [ref]$created) } catch { $created = $false }
        if (-not $created) {
            [void][System.Windows.Forms.MessageBox]::Show('Training Mode is already open. Look for its icon in the system tray.', 'Training Mode')
            return
        }
    }

    $gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = $gfx.DpiX / 96.0
    $gfx.Dispose()

    $script:C = @{
        Green = [System.Drawing.Color]::FromArgb(22, 163, 74)
        Blue  = [System.Drawing.Color]::FromArgb(37, 99, 235)
        Teal  = [System.Drawing.Color]::FromArgb(13, 148, 136)
        Line  = [System.Drawing.Color]::FromArgb(203, 213, 225)
        Ink   = [System.Drawing.Color]::FromArgb(15, 23, 42)
        Muted = [System.Drawing.Color]::FromArgb(100, 116, 139)
        Warn  = [System.Drawing.Color]::FromArgb(180, 83, 9)
        Bad   = [System.Drawing.Color]::FromArgb(185, 28, 28)
        LogBg = [System.Drawing.Color]::FromArgb(246, 248, 250)
        Back  = [System.Drawing.Color]::White
    }
    $C = $script:C
    $script:UI = @{ Ready = $false }
    $script:RT = @{ Armed = $false; BusySince = $null; IdleSince = $null; Fire = $false
                    TrayHintShown = $false; ForceExit = $false; Busy = $false }
    $UI = $script:UI
    $settings = Get-Settings
    $UI.Gpus = @(Get-GpuInfo)
    $W = Px 440
    $LW = Px 130

    # Form
    $form = New-Object System.Windows.Forms.Form
    $UI.Form = $form
    $form.Text = 'Training Mode'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $form.BackColor = $C.Back
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AutoSize = $true
    $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $form.Padding = New-Object System.Windows.Forms.Padding(0, 0, (Px 20), (Px 16))

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.ColumnCount = 1
    $root.AutoSize = $true
    $root.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $root.Location = New-Object System.Drawing.Point((Px 20), (Px 14))
    $root.Margin = New-Object System.Windows.Forms.Padding(0)
    $form.Controls.Add($root)

    # Header
    $UI.Title = New-Label 'Normal mode' $W (New-Object System.Drawing.Font('Segoe UI Semibold', 16)) $C.Ink
    $UI.Title.Margin = New-Object System.Windows.Forms.Padding(0)
    $UI.Sub = New-Label '' $W $null $C.Muted
    $root.Controls.Add($UI.Title)
    $root.Controls.Add($UI.Sub)

    # Live section
    $root.Controls.Add((New-Section 'Right now'))
    $live = New-Grid $W $LW
    $UI.GpuVal = New-Label '' ($W - $LW)
    $UI.PlanVal = New-Label '' ($W - $LW)
    Add-GridRow $live (New-Label 'GPU' 0 $null $C.Muted) $UI.GpuVal
    Add-GridRow $live (New-Label 'Power plan' 0 $null $C.Muted) $UI.PlanVal
    $UI.Warn = New-Label '' $W $null $C.Warn
    $UI.Warn.Visible = $false
    Add-GridRow $live $UI.Warn
    $UI.Fix = New-Object System.Windows.Forms.LinkLabel
    $UI.Fix.Text = 'Re-apply training settings'
    $UI.Fix.AutoSize = $true
    $UI.Fix.Visible = $false
    $UI.Fix.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 2))
    $UI.Fix.Add_LinkClicked({
        $script:RT.Busy = $true
        try { Repair-TrainingMode } finally { $script:RT.Busy = $false; Update-Ui }
    })
    Add-GridRow $live $UI.Fix
    $root.Controls.Add($live)

    # Settings section
    $root.Controls.Add((New-Section 'Training settings'))
    $set = New-Grid $W $LW
    $UI.CapVal = New-Label '' ($W - $LW) (New-Object System.Drawing.Font('Segoe UI Semibold', 9.5))
    Add-GridRow $set (New-Label 'GPU power cap' 0 $null $C.Muted) $UI.CapVal

    $minPct = 50
    $g0 = $UI.Gpus | Select-Object -First 1
    if ($g0 -and $g0.DefaultLimit -and $g0.MinLimit) {
        $minPct = [int]([math]::Ceiling(($g0.MinLimit / $g0.DefaultLimit * 100) / 5) * 5)
        $minPct = [math]::Min([math]::Max($minPct, 30), 95)
    }
    $UI.Track = New-Object System.Windows.Forms.TrackBar
    $UI.Track.Minimum = $minPct
    $UI.Track.Maximum = 100
    $UI.Track.TickFrequency = 5
    $UI.Track.SmallChange = 5
    $UI.Track.LargeChange = 10
    $UI.Track.Value = [int][math]::Min([math]::Max([int]$settings.gpuPercent, $minPct), 100)
    $UI.Track.BackColor = $C.Back
    $UI.Track.Width = $W
    $UI.Track.Margin = New-Object System.Windows.Forms.Padding(0)
    $UI.Track.Add_ValueChanged({
        $t = $script:UI.Track
        $snap = [int]([math]::Round($t.Value / 5) * 5)
        $snap = [math]::Min([math]::Max($snap, $t.Minimum), $t.Maximum)
        if ($t.Value -ne $snap) { $t.Value = $snap; return }
        Update-CapLabel
        Save-UiSettings
    })
    Add-GridRow $set $UI.Track
    Add-GridRow $set (New-Label 'Lower = less power, heat and noise, but somewhat slower. 100% = stock speed. The live GPU readout shows whether the cap is actually limiting your run.' $W $null $C.Muted)

    $UI.Display = New-Object System.Windows.Forms.ComboBox
    $UI.Display.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $UI.Display.Width = Px 130
    foreach ($m in $script:DisplayChoices) { [void]$UI.Display.Items.Add($(if ($m -eq 0) { 'Never' } else { "$m min" })) }
    $di = [array]::IndexOf($script:DisplayChoices, [int]$settings.displayOffMinutes)
    $UI.Display.SelectedIndex = $(if ($di -ge 0) { $di } else { 3 })
    $UI.Display.Margin = New-Object System.Windows.Forms.Padding(0, (Px 6), 0, (Px 3))
    $UI.Display.Add_SelectedIndexChanged({ Save-UiSettings })
    $lblDisp = New-Label 'Display off after' 0 $null $C.Muted
    $lblDisp.Margin = New-Object System.Windows.Forms.Padding(0, (Px 9), 0, 0)
    Add-GridRow $set $lblDisp $UI.Display

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.AutoSize = $true
    $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flow.WrapContents = $true
    $flow.MaximumSize = New-Object System.Drawing.Size($W, 0)
    $flow.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, 0)
    $UI.Auto = New-Object System.Windows.Forms.CheckBox
    $UI.Auto.Text = 'Treat training as done after'
    $UI.Auto.AutoSize = $true
    $UI.Auto.Checked = [bool]$settings.autoRevert
    $UI.Auto.Margin = New-Object System.Windows.Forms.Padding(0, (Px 4), (Px 4), 0)
    $UI.Auto.Add_CheckedChanged({ Save-UiSettings; Update-Ui })
    $UI.AutoMins = New-Object System.Windows.Forms.ComboBox
    $UI.AutoMins.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $UI.AutoMins.Width = Px 80
    foreach ($m in $script:AutoChoices) { [void]$UI.AutoMins.Items.Add("$m min") }
    $autoIdx = [array]::IndexOf($script:AutoChoices, [int]$settings.autoRevertMinutes)
    $UI.AutoMins.SelectedIndex = $(if ($autoIdx -ge 0) { $autoIdx } else { 2 })
    $UI.AutoMins.Margin = New-Object System.Windows.Forms.Padding(0, (Px 1), (Px 4), 0)
    $UI.AutoMins.Add_SelectedIndexChanged({ Save-UiSettings })
    $lblIdle = New-Label 'of GPU idle' 0
    $lblIdle.Margin = New-Object System.Windows.Forms.Padding(0, (Px 5), 0, 0)
    $flow.Controls.Add($UI.Auto)
    $flow.Controls.Add($UI.AutoMins)
    $flow.Controls.Add($lblIdle)
    Add-GridRow $set $flow
    Add-GridRow $set (New-Label 'Only counts once training has started, so you have time to set things up. Needs this window open (it can sit in the tray).' $W $null $C.Muted)

    $UI.Calm = New-Object System.Windows.Forms.CheckBox
    $UI.Calm.Text = 'After training is done, optimize energy (Calm mode)'
    $UI.Calm.AutoSize = $true
    $UI.Calm.Checked = [bool]$settings.calmAfterTraining
    $UI.Calm.Margin = New-Object System.Windows.Forms.Padding(0, (Px 10), 0, 0)
    $UI.Calm.Add_CheckedChanged({ Save-UiSettings; Update-Ui })
    Add-GridRow $set $UI.Calm
    Add-GridRow $set (New-Label 'Instead of going back to your normal plan: CPU prefers efficiency (Windows Power saver values, no speed cap), GPU back to its normal limit, display off as above. Stays on until you click Back to normal.' $W $null $C.Muted)
    $root.Controls.Add($set)

    # Main button
    $UI.Button = New-Object System.Windows.Forms.Button
    $UI.Button.Size = New-Object System.Drawing.Size($W, (Px 46))
    $UI.Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $UI.Button.FlatAppearance.BorderSize = 0
    $UI.Button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11.5)
    $UI.Button.ForeColor = [System.Drawing.Color]::White
    $UI.Button.BackColor = $C.Green
    $UI.Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $UI.Button.Margin = New-Object System.Windows.Forms.Padding(0, (Px 14), 0, (Px 4))
    $UI.Button.Add_Click({ Invoke-ModeChange $script:UI.PrimaryAction })
    $root.Controls.Add($UI.Button)

    $UI.Button2 = New-Object System.Windows.Forms.Button
    $UI.Button2.Size = New-Object System.Drawing.Size($W, (Px 34))
    $UI.Button2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $UI.Button2.FlatAppearance.BorderSize = 1
    $UI.Button2.FlatAppearance.BorderColor = $C.Line
    $UI.Button2.BackColor = $C.Back
    $UI.Button2.ForeColor = $C.Ink
    $UI.Button2.Cursor = [System.Windows.Forms.Cursors]::Hand
    $UI.Button2.Margin = New-Object System.Windows.Forms.Padding(0, (Px 2), 0, (Px 4))
    $UI.Button2.Add_Click({ Invoke-ModeChange $script:UI.SecondaryAction })
    $root.Controls.Add($UI.Button2)

    $UI.AutoStatus = New-Label '' $W $null $C.Muted
    $UI.AutoStatus.Visible = $false
    $root.Controls.Add($UI.AutoStatus)

    # Activity log + links
    $root.Controls.Add((New-Section 'Activity'))
    $UI.Log = New-Object System.Windows.Forms.RichTextBox
    $UI.Log.ReadOnly = $true
    $UI.Log.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $UI.Log.BackColor = $C.LogBg
    $UI.Log.Font = New-Object System.Drawing.Font('Segoe UI', 8.75)
    $UI.Log.Size = New-Object System.Drawing.Size($W, (Px 92))
    $UI.Log.DetectUrls = $false
    $UI.Log.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $UI.Log.Margin = New-Object System.Windows.Forms.Padding(0, (Px 2), 0, (Px 6))
    $root.Controls.Add($UI.Log)

    $links = New-Object System.Windows.Forms.FlowLayoutPanel
    $links.AutoSize = $true
    $links.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $links.Margin = New-Object System.Windows.Forms.Padding(0)
    $lnkWhat = New-Object System.Windows.Forms.LinkLabel
    $lnkWhat.Text = 'What does this change?'
    $lnkWhat.AutoSize = $true
    $lnkWhat.Margin = New-Object System.Windows.Forms.Padding(0, 0, (Px 16), 0)
    $lnkWhat.Add_LinkClicked({ Show-WhatChanges })
    $lnkLog = New-Object System.Windows.Forms.LinkLabel
    $lnkLog.Text = 'Open log folder'
    $lnkLog.AutoSize = $true
    $lnkLog.Margin = New-Object System.Windows.Forms.Padding(0)
    $lnkLog.Add_LinkClicked({
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList "`"$StateDir`""
    })
    $links.Controls.Add($lnkWhat)
    $links.Controls.Add($lnkLog)
    $root.Controls.Add($links)

    # Tray icon
    $UI.IconOn = New-DotIcon $C.Green
    $UI.IconOff = New-DotIcon $C.Muted
    $UI.IconCalm = New-DotIcon $C.Teal
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $UI.Tray = $tray
    $tray.Icon = $UI.IconOff
    $tray.Text = 'Training Mode'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = $menu.Items.Add('Show window')
    $miShow.Add_Click({ Show-MainWindow })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $UI.MiTrain = $menu.Items.Add('Start training mode')
    $UI.MiTrain.Add_Click({ Invoke-ModeChange 'training' })
    $UI.MiDone = $menu.Items.Add('Training done')
    $UI.MiDone.Add_Click({ Invoke-ModeChange 'done' })
    $UI.MiCalm = $menu.Items.Add('Calm mode')
    $UI.MiCalm.Add_Click({ Invoke-ModeChange 'calm' })
    $UI.MiNormal = $menu.Items.Add('Back to normal')
    $UI.MiNormal.Add_Click({ Invoke-ModeChange 'normal' })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = $menu.Items.Add('Exit')
    $miExit.Add_Click({ Show-MainWindow; $script:UI.Form.Close() })
    $tray.ContextMenuStrip = $menu
    $tray.Add_DoubleClick({ Show-MainWindow })
    if (-not $SnapshotPath) { $tray.Visible = $true }

    # Window events
    $form.Add_Resize({
        if ($script:UI.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $script:UI.Form.Hide()
            if (-not $script:RT.TrayHintShown) {
                $script:RT.TrayHintShown = $true
                $script:UI.Tray.ShowBalloonTip(3000, 'Training Mode', 'Still running here in the tray. Double-click to open.',
                                               [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    })
    $form.Add_FormClosing({
        param($s, $e)
        if ($script:RT.ForceExit) { return }
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) { return }
        # Calm mode is meant to stay on after the app closes, so only training mode asks.
        if ((Get-StateMode (Read-JsonFile $script:StatePath)) -eq 'training') {
            $next = if ($script:UI.Calm.Checked) { 'switch to Calm mode' } else { 'switch back to normal' }
            $msg = "Training mode is still on, and nothing will notice when training ends once the app is closed.`n`n" +
                   "Yes:  training is done, $next, then close`n" +
                   "No:  close and leave training mode on. Open this app again later to switch (restarting the PC also switches the power plan back).`n" +
                   "Cancel:  keep the app open"
            $r = [System.Windows.Forms.MessageBox]::Show($script:UI.Form, $msg, 'Training Mode', 'YesNoCancel', 'Question')
            if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { $e.Cancel = $true; return }
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-ModeChange 'done' }
        }
    })
    $form.Add_FormClosed({
        $script:UI.Timer.Stop()
        $script:UI.Tray.Visible = $false
        $script:UI.Tray.Dispose()
    })

    $timer = New-Object System.Windows.Forms.Timer
    $UI.Timer = $timer
    $timer.Interval = 3000
    $timer.Add_Tick({ Update-Ui -Tick })

    # Hook the log into the window.
    $script:LogSink = {
        param($Message, $Level)
        $box = $script:UI.Log
        $color = switch ($Level) { 'warn' { $script:C.Warn } 'error' { $script:C.Bad } 'ok' { $script:C.Green } default { $script:C.Ink } }
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionColor = $color
        $box.AppendText(('{0:HH:mm}  {1}' -f (Get-Date), $Message) + "`n")
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
    }

    $UI.Ready = $true
    Update-CapLabel
    if ($DryRun) { Write-TMLog 'Dry run: changes are logged, not made.' 'warn' }
    Invoke-Reconcile
    $startMode = Get-StateMode (Read-JsonFile $script:StatePath)
    if ($startMode -ne 'normal') { Write-TMLog "$(Get-ModeLabel $startMode) is on (from earlier)." }
    else { Write-TMLog 'Ready. Your current settings will be restored when you click "Back to normal".' }
    Update-Ui

    if ($SnapshotPath) {
        $form.Add_Shown({
            Update-Ui
            [System.Windows.Forms.Application]::DoEvents()
            $f = $script:UI.Form
            $bmp = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
            $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $f.Width, $f.Height)))
            $bmp.Save($SnapshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $script:RT.ForceExit = $true
            $f.Close()
        })
    } else {
        $timer.Start()
    }
    [System.Windows.Forms.Application]::Run($form)
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
}

# ---------------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------------
# Keep the log file small.
try {
    if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 512KB) {
        $tail = Get-Content -LiteralPath $script:LogPath -Tail 1000
        Set-Content -LiteralPath $script:LogPath -Value $tail -Encoding UTF8
    }
} catch { }

# Ask for admin once (needed for the GPU power cap). Status never needs it.
if ($Action -ne 'status' -and -not $script:IsAdmin -and -not $NoElevate -and -not $DryRun -and -not $Relaunched) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA')
    if ($Action -eq 'gui') { $argList += @('-WindowStyle', 'Hidden') }
    $argList += @('-File', "`"$script:SelfPath`"", '-Action', $Action, '-Relaunched')
    if ($GpuPercent -gt 0) { $argList += @('-GpuPercent', "$GpuPercent") }
    if ($DisplayOffMinutes -ge 0) { $argList += @('-DisplayOffMinutes', "$DisplayOffMinutes") }
    if ($PSBoundParameters.ContainsKey('StateDir')) { $argList += @('-StateDir', "`"$StateDir`"") }
    if ($Quiet) { $argList += '-Quiet' }
    $style = if ($Action -eq 'gui') { 'Hidden' } else { 'Normal' }
    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList -Verb RunAs -WindowStyle $style -ErrorAction Stop
        exit 0
    } catch {
        if (-not $Quiet -and $Action -ne 'gui') {
            Write-Host 'Admin rights were not granted; continuing without the GPU power cap.' -ForegroundColor Yellow
        }
    }
}

switch ($Action) {
    'gui' {
        Show-TrainingModeGui
    }
    'on' {
        Invoke-Reconcile
        $s = Get-Settings
        $pct = if ($GpuPercent -gt 0) { $GpuPercent } else { [int]$s.gpuPercent }
        $disp = if ($DisplayOffMinutes -ge 0) { $DisplayOffMinutes } else { [int]$s.displayOffMinutes }
        [void](Start-Mode 'training' $pct $disp)
        if (-not $Quiet) { Write-Host ''; Show-CliStatus }
    }
    'calm' {
        Invoke-Reconcile
        $s = Get-Settings
        $disp = if ($DisplayOffMinutes -ge 0) { $DisplayOffMinutes } else { [int]$s.displayOffMinutes }
        [void](Start-Mode 'calm' 0 $disp)
        if (-not $Quiet) { Write-Host ''; Show-CliStatus }
    }
    'done' {
        [void](Complete-Training)
        if (-not $Quiet) { Write-Host ''; Show-CliStatus }
    }
    'off' {
        [void](Disable-TrainingMode)
        if (-not $Quiet) { Write-Host ''; Show-CliStatus }
    }
    'status' {
        Show-CliStatus
    }
}

if ($Relaunched -and $Action -ne 'gui' -and -not $Quiet) {
    Write-Host ''
    [void](Read-Host 'Press Enter to close')
}
