# ui/ZB-Winget-UI.ps1 — point-and-click control panel for the ZB winget repo.
# Thin shell ONLY: every action calls ..\deploy.ps1 with the same switches a CLI user
# would type, so the demo path == the real path. No business logic lives here.
#
# Run:  pwsh -Sta -File .\ui\ZB-Winget-UI.ps1      (double-click ui\Open-Panel.cmd also works)
# Test: pwsh -Sta -File .\ui\ZB-Winget-UI.ps1 -SelfTest   (clicks List itself, exits 0/1)
#
# Buttons: Publish (file picker + metadata) | List | Verify | Setup this PC | Install | Downloads

param([switch]$SelfTest, [string]$SelfTestFile)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# WinForms wants STA; relaunch ourselves if we were started without it.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process -FilePath 'pwsh' -ArgumentList @('-Sta', '-NoProfile', '-File', $PSCommandPath)
    return
}

$repo      = Split-Path $PSScriptRoot -Parent
$deploy    = Join-Path $repo 'deploy.ps1'
$downloads = Join-Path $repo 'downloads'

# metadata reader (reads the picked file -> fills the form)
. (Join-Path $PSScriptRoot 'Get-PackageMetadata.ps1')

# ---------------------------------------------------------------- settings chip
$ctxLine = 'settings: deploy-settings.psd1 not found'
try {
    $s = Import-PowerShellDataFile (Join-Path $repo 'deploy-settings.psd1')
    $ctxLine = "repo '{0}'  ·  RG '{1}'  ·  {2}" -f $s.Name, $s.ResourceGroup, $s.Region
} catch { }

# ------------------------------------------------------------------- run engine
$script:proc  = $null
$script:logPath = $null
$script:logPos = 0
$script:buffer = ''
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 600

function Append-Log {
    param([string]$text)
    if (-not $text) { return }
    $script:buffer += $text + "`r`n"
    $tbLog.AppendText($text + "`r`n")
    $tbLog.SelectionStart = $tbLog.TextLength
    $tbLog.ScrollToCaret()
}

function Set-Busy {
    param([bool]$busy)
    foreach ($b in @($btnPublish, $btnList, $btnVerify, $btnSetup, $btnInstall)) { $b.Enabled = -not $busy }
    $form.Cursor = if ($busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
}

function Set-Status {
    param([string]$text, [string]$kind = 'info')
    $lblStatus.Text = $text
    $lblStatus.ForeColor = switch ($kind) {
        'ok'   { [System.Drawing.Color]::FromArgb(0, 120, 60) }
        'err'  { [System.Drawing.Color]::FromArgb(180, 30, 30) }
        'busy' { [System.Drawing.Color]::FromArgb(150, 90, 0) }
        default { [System.Drawing.Color]::FromArgb(60, 60, 60) }
    }
}

# Reads the chosen file and fills the form from its own metadata. Always overwrites,
# so switching files never leaves stale values from the previous one.
function Fill-FromFile {
    param([string]$path)
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $m = $null
    try { $m = Get-PackageMetadata -Path $path -UseCatalog }
    catch { Append-Log "could not read metadata: $($_.Exception.Message)"; return }
    if (-not $m) { return }
    $tbId.Text   = $m.PackageId
    $tbVer.Text  = $m.Version
    $tbPubr.Text = $m.Publisher
    $tbDesc.Text = $m.Description
    if ($m.Arch) { $cmbArch.SelectedItem = $m.Arch }
    $note = if ($m.CatalogId) { ' (public catalog ID)' } else { '' }
    Append-Log ("auto-fill  {0}  ->  id={1}{2}  version={3}  publisher={4}  arch={5}" -f $m.File, $m.PackageId, $note, $m.Version, $m.Publisher, $m.Arch)
    $missing = @()
    if (-not $m.PackageId)    { $missing += 'Package ID' }
    if (-not $m.Version)      { $missing += 'Version' }
    if (-not $m.Publisher)    { $missing += 'Publisher' }
    if (-not $m.Description)  { $missing += 'Description' }
    if ($missing.Count) {
        Append-Log ("no metadata for: {0} - type those in (see PUBLISHING.md)" -f ($missing -join ', '))
        Set-Status ("auto-filled - file carries no metadata for: " + ($missing -join ', ')) 'info'
    }
    else                { Set-Status 'auto-filled from the file - check the values, then Publish' 'ok' }
}

# Runs any PowerShell command line with output captured to a temp log; the timer
# streams it into the pane, so the window never freezes.
function Run-Command {
    param([string]$label, [string]$commandText)
    if ($script:proc -and -not $script:proc.HasExited) {
        [System.Windows.Forms.MessageBox]::Show('A task is still running — wait for it to finish.', 'Busy') | Out-Null
        return
    }
    $script:logPath = Join-Path $env:TEMP ("zbui-{0}.log" -f ([guid]::NewGuid().ToString('N')))
    $script:logPos = 0
    $wrapped = "$commandText *>&1 | Out-File -FilePath '$($script:logPath)' -Encoding utf8 -Append"
    Append-Log ("`r`n=== {0} ===" -f $label)
    Set-Status ("running: {0} ..." -f $label) 'busy'
    Set-Busy $true
    $script:proc = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $wrapped)
    $script:timer.Start()
}

function Quote([string]$p) { "'" + $p.Replace("'", "''") + "'" }

$script:timer.Add_Tick({
    # stream new log content
    try {
        if ($script:logPath -and (Test-Path -LiteralPath $script:logPath)) {
            $all = [IO.File]::ReadAllText($script:logPath)
            if ($all.Length -gt $script:logPos) {
                Append-Log $all.Substring($script:logPos).TrimEnd("`r", "`n")
                $script:logPos = $all.Length
            }
        }
    } catch { }

    if ($script:proc -and $script:proc.HasExited) {
        $script:timer.Stop()
        $code = $script:proc.ExitCode
        Append-Log ("=== finished (exit {0}) ===" -f $code)
        $receipt = ([regex]::Matches($script:buffer, '\[(PUBLISH_OK|LIST_OK|FETCH_OK|INGEST_OK|HOST_UP|REPAIR_DONE|CLIENT_TEST_OK)\]') |
                    ForEach-Object { $_.Groups[1].Value } | Select-Object -Last 1)
        if ($code -eq 0 -and $receipt) { Set-Status ("done — {0}" -f $receipt) 'ok' }
        elseif ($code -eq 0)          { Set-Status 'done' 'ok' }
        else                           { Set-Status ("failed (exit {0}) — see log above" -f $code) 'err' }
        Set-Busy $false
        Remove-Item -LiteralPath $script:logPath -Force -ErrorAction SilentlyContinue
        $script:proc = $null
        if ($script:selfTest) { Start-Sleep -Milliseconds 400; $form.Close() }
    }
})

# ------------------------------------------------------------------------ form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'ZB Winget Repo — Control Panel'
$form.Size = New-Object System.Drawing.Size(940, 700)
$form.MinimumSize = New-Object System.Drawing.Size(780, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$ctx = New-Object System.Windows.Forms.Label
$ctx.Text = $ctxLine
$ctx.Location = New-Object System.Drawing.Point(14, 8)
$ctx.AutoSize = $true
$ctx.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$form.Controls.Add($ctx)

# --- publish group
$grpPub = New-Object System.Windows.Forms.GroupBox
$grpPub.Text = 'Publish a file into the repo'
$grpPub.Location = New-Object System.Drawing.Point(12, 30)
$grpPub.Size = New-Object System.Drawing.Size(596, 232)
$form.Controls.Add($grpPub)

$lblFile = New-Object System.Windows.Forms.Label
$lblFile.Text = 'Installer file'
$lblFile.Location = New-Object System.Drawing.Point(12, 28); $lblFile.AutoSize = $true
$grpPub.Controls.Add($lblFile)

$tbFile = New-Object System.Windows.Forms.TextBox
$tbFile.Location = New-Object System.Drawing.Point(110, 25); $tbFile.Size = New-Object System.Drawing.Size(372, 24)
$grpPub.Controls.Add($tbFile)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(490, 23); $btnBrowse.Size = New-Object System.Drawing.Size(92, 26)
$grpPub.Controls.Add($btnBrowse)

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Pick the installer to publish'
    $dlg.Filter = 'Installers (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $tbFile.Text = $dlg.FileName
        Fill-FromFile $dlg.FileName
    }
})

# typing/pasting a path and tabbing away also auto-fills
$tbFile.Add_Leave({ Fill-FromFile $tbFile.Text })

$lblId = New-Object System.Windows.Forms.Label
$lblId.Text = 'Package ID'
$lblId.Location = New-Object System.Drawing.Point(12, 62); $lblId.AutoSize = $true
$grpPub.Controls.Add($lblId)

$tbId = New-Object System.Windows.Forms.TextBox
$tbId.Location = New-Object System.Drawing.Point(110, 59); $tbId.Size = New-Object System.Drawing.Size(232, 24)
$grpPub.Controls.Add($tbId)

$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = 'Version'
$lblVer.Location = New-Object System.Drawing.Point(360, 62); $lblVer.AutoSize = $true
$grpPub.Controls.Add($lblVer)

$tbVer = New-Object System.Windows.Forms.TextBox
$tbVer.Location = New-Object System.Drawing.Point(420, 59); $tbVer.Size = New-Object System.Drawing.Size(70, 24)
$grpPub.Controls.Add($tbVer)

$lblArch = New-Object System.Windows.Forms.Label
$lblArch.Text = 'Arch'
$lblArch.Location = New-Object System.Drawing.Point(500, 62); $lblArch.AutoSize = $true
$grpPub.Controls.Add($lblArch)

$cmbArch = New-Object System.Windows.Forms.ComboBox
$cmbArch.DropDownStyle = 'DropDownList'
[void]$cmbArch.Items.AddRange(@('x64', 'x86', 'arm64'))
$cmbArch.SelectedIndex = 0
$cmbArch.Location = New-Object System.Drawing.Point(535, 59); $cmbArch.Size = New-Object System.Drawing.Size(47, 24)
$grpPub.Controls.Add($cmbArch)

$lblPubr = New-Object System.Windows.Forms.Label
$lblPubr.Text = 'Publisher'
$lblPubr.Location = New-Object System.Drawing.Point(12, 96); $lblPubr.AutoSize = $true
$grpPub.Controls.Add($lblPubr)

$tbPubr = New-Object System.Windows.Forms.TextBox
$tbPubr.Location = New-Object System.Drawing.Point(110, 93); $tbPubr.Size = New-Object System.Drawing.Size(232, 24)
$grpPub.Controls.Add($tbPubr)

$lblDesc = New-Object System.Windows.Forms.Label
$lblDesc.Text = 'Description'
$lblDesc.Location = New-Object System.Drawing.Point(12, 130); $lblDesc.AutoSize = $true
$grpPub.Controls.Add($lblDesc)

$tbDesc = New-Object System.Windows.Forms.TextBox
$tbDesc.Location = New-Object System.Drawing.Point(110, 127); $tbDesc.Size = New-Object System.Drawing.Size(472, 24)
$grpPub.Controls.Add($tbDesc)

$btnPublish = New-Object System.Windows.Forms.Button
$btnPublish.Text = 'Publish to repo'
$btnPublish.Location = New-Object System.Drawing.Point(110, 168); $btnPublish.Size = New-Object System.Drawing.Size(150, 34)
$grpPub.Controls.Add($btnPublish)

$btnDownloads = New-Object System.Windows.Forms.Button
$btnDownloads.Text = 'Open downloads folder'
$btnDownloads.Location = New-Object System.Drawing.Point(272, 168); $btnDownloads.Size = New-Object System.Drawing.Size(160, 34)
$grpPub.Controls.Add($btnDownloads)

$btnDownloads.Add_Click({
    if (-not (Test-Path $downloads)) { New-Item -ItemType Directory -Path $downloads -Force | Out-Null }
    Start-Process explorer.exe $downloads
})

$btnPublish.Add_Click({
    if (-not $tbFile.Text) { [System.Windows.Forms.MessageBox]::Show('Pick an installer file first.', 'Missing file') | Out-Null; return }
    if (-not (Test-Path -LiteralPath $tbFile.Text)) { [System.Windows.Forms.MessageBox]::Show('That file does not exist.', 'Missing file') | Out-Null; return }
    if ($tbId.Text -notmatch '\.') { [System.Windows.Forms.MessageBox]::Show('Package ID must look like Publisher.Product (e.g. Zenblox.MyApp).', 'Package ID') | Out-Null; return }
    if (-not $tbVer.Text) { [System.Windows.Forms.MessageBox]::Show('Enter a version (e.g. 1.0.0).', 'Version') | Out-Null; return }
    if (-not $tbPubr.Text) { [System.Windows.Forms.MessageBox]::Show('Enter a publisher name.', 'Publisher') | Out-Null; return }
    $cmd = "& $(Quote $deploy) -Publish -File $(Quote $tbFile.Text) -PackageId $(Quote $tbId.Text) -Version $(Quote $tbVer.Text) -Publisher $(Quote $tbPubr.Text) -Description $(Quote $tbDesc.Text) -Architecture $(Quote $cmbArch.SelectedItem)"
    Run-Command ("Publish {0} {1}" -f $tbId.Text, $tbVer.Text) $cmd
})

# --- repo group
$grpRepo = New-Object System.Windows.Forms.GroupBox
$grpRepo.Text = 'Repo'
$grpRepo.Location = New-Object System.Drawing.Point(620, 30)
$grpRepo.Size = New-Object System.Drawing.Size(292, 232)
$form.Controls.Add($grpRepo)

function New-RepoButton([string]$text, [int]$y) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point(12, $y)
    $b.Size = New-Object System.Drawing.Size(266, 34)
    $grpRepo.Controls.Add($b)
    return $b
}

$btnList    = New-RepoButton 'List packages in repo' 26
$btnVerify  = New-RepoButton 'Check repo health'     66
$btnSetup   = New-RepoButton 'Setup winget on THIS PC' 106
$btnInstall = New-RepoButton 'Install from repo'     146

$btnList.Add_Click({ Run-Command 'List packages' "& $(Quote $deploy) -List" })

$btnVerify.Add_Click({ Run-Command 'Repo health check' "& $(Quote $deploy) -Verify" })

$btnSetup.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show('Registers this PC as a winget client of the repo. A UAC prompt will appear - approve it. Continue?', 'Setup this PC', 'YesNo', 'Question')
    if ($r -eq 'Yes') { Run-Command 'Setup this PC (winget source add)' "& $(Quote $deploy) -ClientTest" }
})

$btnInstall.Add_Click({
    if ($tbId.Text -notmatch '\.') { [System.Windows.Forms.MessageBox]::Show('Fill in the Package ID first (the same field used for publishing).', 'Package ID') | Out-Null; return }
    $ver = if ($tbVer.Text) { " --version $($tbVer.Text)" } else { '' }
    $cmd = "winget install --id $(Quote $tbId.Text)$ver --source internal --accept-package-agreements --accept-source-agreements"
    Run-Command ("Install {0}{1}" -f $tbId.Text, $ver) $cmd
})

# --- log pane
$tbLog = New-Object System.Windows.Forms.TextBox
$tbLog.Multiline = $true
$tbLog.ReadOnly = $true
$tbLog.ScrollBars = 'Both'
$tbLog.WordWrap = $false
$tbLog.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
$tbLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$tbLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$tbLog.Location = New-Object System.Drawing.Point(12, 270)
$tbLog.Size = New-Object System.Drawing.Size(900, 340)
$tbLog.Anchor = 'Top,Left,Right,Bottom'
$form.Controls.Add($tbLog)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'ready'
$lblStatus.Location = New-Object System.Drawing.Point(14, 620)
$lblStatus.Size = New-Object System.Drawing.Size(896, 22)
$lblStatus.Anchor = 'Left,Right,Bottom'
$form.Controls.Add($lblStatus)

Append-Log 'ZB Winget Repo — control panel. Every button runs ..\deploy.ps1 (same path as CLI).'
Append-Log ("repo: {0}" -f $repo)

# --- self-test hooks -------------------------------------------------------------------
# -SelfTest            : clicks "List packages in repo" itself, exits 0/1 on the receipt
# -SelfTest -SelfTestFile <path> : selects that file, auto-fills, prints the fields, exits
$script:selfTest = $SelfTest
if ($script:selfTest) {
    if ($SelfTestFile) {
        $form.Add_Shown({
            $tbFile.Text = $SelfTestFile
            Fill-FromFile $SelfTestFile
            Append-Log ("AUTOFILL_RESULT id='{0}' version='{1}' publisher='{2}' arch='{3}' desc='{4}'" -f $tbId.Text, $tbVer.Text, $tbPubr.Text, $cmbArch.SelectedItem, $tbDesc.Text)
            $form.Close()
        })
    } else {
        $script:autoTimer = New-Object System.Windows.Forms.Timer
        $script:autoTimer.Interval = 1200
        $script:autoTimer.Add_Tick({
            $script:autoTimer.Stop()
            Append-Log 'SELFTEST: clicking "List packages in repo" ...'
            $btnList.PerformClick()
        })
        $form.Add_Shown({ $script:autoTimer.Start() })
    }
}

[void]$form.ShowDialog()

if ($script:selfTest) {
    Write-Output '--- SELFTEST LOG BEGIN ---'
    Write-Output $script:buffer
    Write-Output '--- SELFTEST LOG END ---'
    if ($SelfTestFile) {
        if ($script:buffer -match "AUTOFILL_RESULT id='[^']+\.[^']+'") { Write-Output 'SELFTEST: PASS (autofill)'; exit 0 }
        if ($script:buffer -match 'no metadata for:')                { Write-Output 'SELFTEST: PASS (autofill - file has no metadata, fields left blank by design)'; exit 0 }
        Write-Output 'SELFTEST: FAIL (neither an id nor a no-metadata note)'
        exit 1
    }
    if ($script:buffer -match '\[LIST_OK\]') { Write-Output 'SELFTEST: PASS'; exit 0 }
    Write-Output 'SELFTEST: FAIL (no [LIST_OK] receipt seen)'
    exit 1
}