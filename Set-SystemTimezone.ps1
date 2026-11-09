# 显示当前时区
$currentTimeZone = Get-TimeZone

Write-Host "Current time zone: $($currentTimeZone.Id)"

Add-Type -AssemblyName System.Windows.Forms

$form = New-Object System.Windows.Forms.Form
$form.Text = "Time Zone Switcher"
$form.ClientSize = New-Object System.Drawing.Size(460, 370)
$form.StartPosition = "CenterScreen"

# 显示当前系统时区
$currentLabel = New-Object System.Windows.Forms.Label
$currentLabel.Text = "Current time zone: $((Get-TimeZone).Id)"
$currentLabel.Location = New-Object System.Drawing.Point(20, 20)
$currentLabel.AutoSize = $true
$form.Controls.Add($currentLabel)

$targetLabel = New-Object System.Windows.Forms.Label
$targetLabel.Text = "Target time zone:"
$targetLabel.Location = New-Object System.Drawing.Point(20, 65)
$targetLabel.AutoSize = $true
$form.Controls.Add($targetLabel)

$timeZoneCombo = New-Object System.Windows.Forms.ComboBox
$timeZoneCombo.Location = New-Object System.Drawing.Point(20, 90)
$timeZoneCombo.Size = New-Object System.Drawing.Size(420, 25)
$timeZoneCombo.DropDownStyle = "DropDownList"

# 从独立时间源获取 UTC，系统时钟修改不会影响它。
function Get-NtpUtc {
    param([string]$Server)

    $client = [System.Net.Sockets.UdpClient]::new()

    try {
        $client.Client.ReceiveTimeout = 2000
        $dns = [System.Net.Dns]::BeginGetHostAddresses($Server, $null, $null)
        try {
            if (-not $dns.AsyncWaitHandle.WaitOne(2000)) {
                throw "DNS lookup timed out: $Server"
            }
            $address = [System.Net.Dns]::EndGetHostAddresses($dns) |
                Where-Object AddressFamily -eq InterNetwork | Select-Object -First 1
        }
        finally {
            $dns.AsyncWaitHandle.Close()
        }
        if ($null -eq $address) { throw "No IPv4 address: $Server" }
        $client.Connect($address, 123)

        $request = New-Object byte[] 48
        $request[0] = 0x23  # NTP v4，客户端模式

        # 请求标识，服务器会在响应里原样返回
        $nonce = [Guid]::NewGuid().ToByteArray()
        [Array]::Copy($nonce, 0, $request, 40, 8)

        $roundTrip = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$client.Send($request, $request.Length)
        $endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $reply = $client.Receive([ref]$endpoint)
        $roundTrip.Stop()

        if ($reply.Length -lt 48 -or
            ($reply[0] -band 7) -ne 4 -or
            ($reply[0] -shr 6) -eq 3 -or
            $reply[1] -lt 1 -or $reply[1] -gt 15 -or
            [BitConverter]::ToUInt64($reply, 24) -ne [BitConverter]::ToUInt64($request, 40) -or
            [BitConverter]::ToUInt64($reply, 40) -eq 0) {
            throw "Invalid NTP response."
        }

        # 将服务器发送时间从网络字节序转换为 UTC
        $timestamp = [byte[]]($reply[40..47])
        if ([BitConverter]::IsLittleEndian) {
            [Array]::Reverse($timestamp)
        }

        $raw = [BitConverter]::ToUInt64($timestamp, 0)
        $seconds = [double]($raw -shr 32)
        $fraction = ($raw -band [uint64]4294967295) / 4294967296.0

        # 处理 2036 年的 NTP 秒计数回卷
        if ($seconds -lt 2147483648) {
            $seconds += 4294967296
        }

        $epoch = [DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        return $epoch.AddSeconds($seconds + $fraction + $roundTrip.Elapsed.TotalSeconds / 2)
    }
    finally {
        $client.Dispose()
    }
}

function Get-NetworkUtc {
    $failures = @()
    foreach ($server in @('time.windows.com', 'time.cloudflare.com', 'time.google.com')) {
        try { return Get-NtpUtc -Server $server }
        catch { $failures += "$server : $($_.Exception.Message)" }
    }

    # UDP 不可用时，使用 HTTPS 响应时间。精度受响应粒度和网络延迟影响。
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    foreach ($url in @('https://www.microsoft.com/', 'https://www.cloudflare.com/')) {
        try {
            $response = Invoke-WebRequest -Uri ($url + '?clock=' + [Guid]::NewGuid().ToString('N')) `
                -Method Head -UseBasicParsing -TimeoutSec 5 `
                -Headers @{ 'Cache-Control' = 'no-cache' } -ErrorAction Stop
            $dateHeader = [string]$response.Headers['Date']
            $ageHeader = [string]$response.Headers['Age']
            if ([string]::IsNullOrWhiteSpace($dateHeader) -or ($ageHeader -and [double]$ageHeader -gt 0)) {
                throw 'Missing or cached server time.'
            }
            return [DateTimeOffset]::Parse($dateHeader, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        }
        catch { $failures += "$url : $($_.Exception.Message)" }
    }
    throw ($failures -join "`n")
}

# 后台取时，窗口可立即显示。成功后用单调计时器推进参考时间。
$referenceClock = @{
    Utc = $null
    Watch = $null
    Worker = $null
    Pending = $null
    LastAttempt = [System.Diagnostics.Stopwatch]::new()
    Error = $null
}

function Start-NetworkTimeRefresh {
    if ($null -ne $referenceClock.Pending) { return }
    $worker = [PowerShell]::Create()
    $code = "function Get-NtpUtc { ${function:Get-NtpUtc} }`n" +
            "function Get-NetworkUtc { ${function:Get-NetworkUtc} }`n" + @'
$utc = Get-NetworkUtc
[PSCustomObject]@{ Utc = $utc; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
'@
    [void]$worker.AddScript($code)
    $referenceClock.Worker = $worker
    $referenceClock.Pending = $worker.BeginInvoke()
    $referenceClock.LastAttempt.Restart()
}

function Complete-NetworkTimeRefresh {
    if ($null -eq $referenceClock.Pending -or -not $referenceClock.Pending.IsCompleted) { return }
    try {
        $result = $referenceClock.Worker.EndInvoke($referenceClock.Pending)
        if ($result.Count -ne 1 -or $null -eq $result[0].Utc) {
            throw 'No network time returned.'
        }
        $referenceClock.Utc = $result[0].Utc
        $referenceClock.Watch = $result[0].Watch
        $referenceClock.Error = $null
    }
    catch {
        $referenceClock.Error = $_.Exception.Message
        Write-Warning $referenceClock.Error
    }
    finally {
        $referenceClock.Worker.Dispose()
        $referenceClock.Worker = $null
        $referenceClock.Pending = $null
    }
    if (-not $timeZoneCombo.DroppedDown) { Update-ZoneList }
}

function Get-ReferenceUtc {
    if ($null -ne $referenceClock.Utc) {
        return $referenceClock.Utc.Add($referenceClock.Watch.Elapsed)
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

# 为每个时区创建一个包含实际id和显示文字的对象
$timeZoneItems = foreach ($zone in (Get-TimeZone -ListAvailable)) {
    [PSCustomObject]@{
        Id   = $zone.Id
        Text = $zone.StandardName
    }
}

# 不使用数据绑定，直接把显示文字加入下拉框
$timeZoneCombo.DataSource = $null
$timeZoneCombo.DisplayMember = ""
$timeZoneCombo.ValueMember = ""
$timeZoneCombo.Items.Clear()

# 保持数组结构
$timeZoneItems = @($timeZoneItems)
$currentId = (Get-TimeZone).Id

for ($i = 0; $i -lt $timeZoneItems.Count; $i++) {
    [void]$timeZoneCombo.Items.Add($timeZoneItems[$i].Text)

    # 默认选中当前系统时区
    if ($timeZoneItems[$i].Id -eq $currentId) {
        $timeZoneCombo.SelectedIndex = $i
    }
}

# 展开时加宽，便于阅读完整内容
$timeZoneCombo.DropDownWidth = 680

# 设置字体
$timeZoneCombo.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

# 允许设置每行高度
$timeZoneCombo.DrawMode = "OwnerDrawFixed"
$timeZoneCombo.ItemHeight = 32

# 控制展开区域高度
$timeZoneCombo.IntegralHeight = $false
$timeZoneCombo.DropDownHeight = 320

# 绘制每一项
$timeZoneCombo.Add_DrawItem({
    param($sender, $e)

    if ($e.Index -lt 0) {
        return
    }
    $e.DrawBackground()
    $bounds = [System.Drawing.Rectangle]::new(
        $e.Bounds.X + 8,
        $e.Bounds.Y,
        [Math]::Max(1, $e.Bounds.Width - 8),
        $e.Bounds.Height
    )

    $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor
             [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
             [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor
             [System.Windows.Forms.TextFormatFlags]::NoPrefix

    [System.Windows.Forms.TextRenderer]::DrawText(
        $e.Graphics,
        [string]$sender.Items[$e.Index],
        $e.Font,
        $bounds,
        $e.ForeColor,
        $flags
    )

    $e.DrawFocusRectangle()
})

$form.Controls.Add($timeZoneCombo)

# 模式一，切换时区并恢复准确时间
$zoneMode = New-Object System.Windows.Forms.RadioButton
$zoneMode.Text = "Use current time in selected time zone"
$zoneMode.Location = New-Object System.Drawing.Point(20, 135)
$zoneMode.AutoSize = $true
$zoneMode.Checked = $true
$form.Controls.Add($zoneMode)

# 模式二，切换时区，并设置自定义时间
$customMode = New-Object System.Windows.Forms.RadioButton
$customMode.Text = "Set custom date and time"
$customMode.Location = New-Object System.Drawing.Point(20, 170)
$customMode.AutoSize = $true
$form.Controls.Add($customMode)

# 输入的日期时间按“目标时区的当地时间”解释
$datePicker = New-Object System.Windows.Forms.DateTimePicker
$datePicker.Location = New-Object System.Drawing.Point(40, 205)
$datePicker.Size = New-Object System.Drawing.Size(340, 25)
$datePicker.Format = "Custom"
$datePicker.CustomFormat = "yyyy-MM-dd HH:mm:ss"
$datePicker.ShowUpDown = $true
$datePicker.Enabled = $false
$form.Controls.Add($datePicker)

# 只有进入自定义模式才允许编辑日期时间
$customMode.Add_CheckedChanged({
    $datePicker.Enabled = $customMode.Checked
})

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 300)
$statusLabel.Size = New-Object System.Drawing.Size(420, 60)
$form.Controls.Add($statusLabel)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = "Apply"
$applyButton.Location = New-Object System.Drawing.Point(320, 250)
$applyButton.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($applyButton)

$applyButton.Add_Click({
    $zoneChanged = $false
    $text = Get-UiText

    try {
        $selectedIndex = $timeZoneCombo.SelectedIndex

        if ($selectedIndex -lt 0) {
          throw "Please select a time zone."
    }

    $selectedId = $timeZoneItems[$selectedIndex].Id

        if ([string]::IsNullOrWhiteSpace($selectedId)) {
            throw "Please select a time zone."
        }

        $selectedZone = Get-TimeZone -Id $selectedId -ErrorAction Stop

        # 先检查自定义时间是否有效
        if ($customMode.Checked) {
            $wallTime = [DateTime]::SpecifyKind(
                $datePicker.Value,
                [DateTimeKind]::Unspecified
            )

            # 夏令时跳转可能导致某个当地时间不存在或出现两次(tmd到底是谁发明的夏令时？？！！！)
            if ($selectedZone.IsInvalidTime($wallTime)) {
                throw "This local time does not exist due to daylight saving time."
            }

            if ($selectedZone.IsAmbiguousTime($wallTime)) {
                throw "This local time occurs twice. Please choose another time."
            }

            $customUtc = [TimeZoneInfo]::ConvertTimeToUtc(
                $wallTime,
                $selectedZone
            )
        }


    if (-not $customMode.Checked) {
           $networkUtc = Get-ReferenceUtc

            if ($null -eq $networkUtc) {
                Start-NetworkTimeRefresh
                throw $text.WaitForNetwork
           }
    }

        # 两种模式都会设置系统时钟，先检查权限，避免仅修改时区。
        if (-not (Test-IsAdministrator)) { throw $text.NeedAdmin }

        # 真正修改系统时区
        Set-TimeZone -Id $selectedId -ErrorAction Stop
        $zoneChanged = $true

        # 清除缓存，让后续转换使用新的系统时区
        [TimeZoneInfo]::ClearCachedData()

    if ($customMode.Checked) {
        $utcToApply = $customUtc
    }
    else {
        $utcToApply = Get-ReferenceUtc
    }

    Set-Date -Date ($utcToApply.ToLocalTime()) -ErrorAction Stop | Out-Null

    Update-Clocks
        $statusLabel.Text = "$($text.Applied) $(
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        )"
    }
    catch {
        # 时区可能已经成功切换而修改时钟失败，分别说明结果
        Update-Clocks

        if ($zoneChanged) {
            $statusLabel.Text = "$($text.PartialFailure) $($_.Exception.Message)"
        }
        else {
            $statusLabel.Text = "$($text.Failed) $($_.Exception.Message)"
        }
    }
})

$form.ClientSize = New-Object System.Drawing.Size(650, 460)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

$currentLabel.Location = New-Object System.Drawing.Point(20, 60)
$targetLabel.Location = New-Object System.Drawing.Point(20, 135)

$timeZoneCombo.Location = New-Object System.Drawing.Point(20, 165)
$timeZoneCombo.Width = 610

$zoneMode.Location = New-Object System.Drawing.Point(20, 245)
$customMode.Location = New-Object System.Drawing.Point(20, 280)
$datePicker.Location = New-Object System.Drawing.Point(40, 315)
$applyButton.Location = New-Object System.Drawing.Point(510, 355)

$statusLabel.Location = New-Object System.Drawing.Point(20, 400)
$statusLabel.Size = New-Object System.Drawing.Size(610, 55)

$languageLabel = New-Object System.Windows.Forms.Label
$languageLabel.Text = "语言 / Language"
$languageLabel.Location = New-Object System.Drawing.Point(20, 20)
$languageLabel.AutoSize = $true
$form.Controls.Add($languageLabel)

$languageCombo = New-Object System.Windows.Forms.ComboBox
$languageCombo.Location = New-Object System.Drawing.Point(190, 16)
$languageCombo.Width = 150
$languageCombo.DropDownStyle = "DropDownList"
[void]$languageCombo.Items.Add("中文")
[void]$languageCombo.Items.Add("English")
$languageCombo.SelectedIndex = 0
$form.Controls.Add($languageCombo)

$systemClockLabel = New-Object System.Windows.Forms.Label
$systemClockLabel.Location = New-Object System.Drawing.Point(20, 95)
$systemClockLabel.AutoSize = $true
$form.Controls.Add($systemClockLabel)

$targetClockLabel = New-Object System.Windows.Forms.Label
$targetClockLabel.Location = New-Object System.Drawing.Point(20, 210)
$targetClockLabel.AutoSize = $true
$form.Controls.Add($targetClockLabel)

$translations = @{
    zh = @{
        Title       = "系统时区与时间"
        CurrentZone = "当前系统时区"
        SystemTime  = "系统时间"
        TargetZone  = "目标时区"
        TargetTime  = "目标时区时间"
        ZoneMode    = "使用目标时区的当前时间"
        CustomMode  = "设置目标时区的自定义日期和时间"
        Apply       = "应用"
        Fetching    = "正在获取真实时间…"
        Unavailable = "真实时间暂不可用，正在等待自动重试"
        WaitForNetwork = "正在获取真实时间，请稍后再次点击应用。"
        NeedAdmin   = "请右键启动.cmd，选择以管理员身份运行。"
        Applied     = "已应用，系统时间："
        Failed      = "操作失败："
        PartialFailure = "时区已修改，设置系统时间失败："
    }

    en = @{
        Title       = "System Time and Time Zone"
        CurrentZone = "Current system time zone"
        SystemTime  = "System time"
        TargetZone  = "Target time zone"
        TargetTime  = "Target time"
        ZoneMode    = "Use current time in selected time zone"
        CustomMode  = "Set custom date and time in selected time zone"
        Apply       = "Apply"
        Fetching    = "Fetching accurate time..."
        Unavailable = "Accurate time unavailable; waiting to retry"
        WaitForNetwork = "Fetching accurate time. Please click Apply again shortly."
        NeedAdmin   = "Right-click the launcher and select Run as administrator."
        Applied     = "Applied. System time:"
        Failed      = "Failed:"
        PartialFailure = "Time zone changed, but setting the clock failed:"
    }
}

# 提供中文名称
$chineseZoneNames = @{
    "China Standard Time"    = "中国标准时间"
    "Pacific Standard Time"  = "美国太平洋时区"
    "Mountain Standard Time" = "美国山地时区"
    "Central Standard Time"  = "美国中部时区"
    "Eastern Standard Time"  = "美国东部时区"
    "Tokyo Standard Time"    = "日本标准时间"
    "GMT Standard Time"      = "英国时区"
    "UTC"                    = "协调世界时"
}

# 缓存
$zoneLookup = @{}
foreach ($zone in (Get-TimeZone -ListAvailable)) {
    $zoneLookup[$zone.Id] = $zone
}

function Get-UiText {
    if ($languageCombo.SelectedIndex -eq 0) {
        return $translations.zh
    }

    return $translations.en
}

function Get-ZoneName {
    param([string]$Id)

    if ($languageCombo.SelectedIndex -eq 0) {
        if ($chineseZoneNames.ContainsKey($Id)) {
            return $chineseZoneNames[$Id]
        }

        return $zoneLookup[$Id].StandardName
    }

    # windows时区id本身是英文且不受系统语言影响
    return $Id
}

function Update-Clocks {
    $text = Get-UiText
    $utcNow = Get-ReferenceUtc
    $currentZone = Get-TimeZone

    $currentLabel.Text = "$($text.CurrentZone): $(Get-ZoneName $currentZone.Id)"
    $systemClockLabel.Text = "$($text.SystemTime): $(
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    )"

    if ($null -eq $utcNow) {
        $targetClockLabel.Text = if ($null -ne $referenceClock.Pending) { $text.Fetching } else { $text.Unavailable }
    return
    }

    $index = $timeZoneCombo.SelectedIndex

    if ($index -ge 0) {
        $zone = $zoneLookup[$timeZoneItems[$index].Id]
        $targetTime = [TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $zone)

        $targetClockLabel.Text = "$($text.TargetTime): $(
            $targetTime.ToString('yyyy-MM-dd HH:mm:ss')
        )"
    }
}

function Update-ZoneList {
    $selectedIndex = $timeZoneCombo.SelectedIndex
    $utcNow = Get-ReferenceUtc

    # 批量修改完成后再绘制
    $timeZoneCombo.BeginUpdate()

    try {
        for ($i = 0; $i -lt $timeZoneItems.Count; $i++) {
            $item = $timeZoneItems[$i]

        $name = Get-ZoneName $item.Id

        if ($null -eq $utcNow) {
            $item.Text = "$name | --"
            $timeZoneCombo.Items[$i] = $item.Text
            continue
        }

            $zone = $zoneLookup[$item.Id]

            $localTime = [TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $zone)
            $offset = $zone.GetUtcOffset($utcNow)
            $sign = if ($offset.Ticks -lt 0) { "-" } else { "+" }
            $offsetText = $sign + $offset.Duration().ToString("hh\:mm")

            $timeText = $localTime.ToString("yyyy-MM-dd HH:mm:ss")

            $item.Text = "$name | UTC$offsetText | $timeText"
            $timeZoneCombo.Items[$i] = $item.Text
        }

        $timeZoneCombo.SelectedIndex = $selectedIndex
    }
    finally {
        $timeZoneCombo.EndUpdate()
    }
}

function Update-Language {
    $text = Get-UiText

    $form.Text = $text.Title
    $targetLabel.Text = $text.TargetZone
    $zoneMode.Text = $text.ZoneMode
    $customMode.Text = $text.CustomMode
    $applyButton.Text = $text.Apply

    Update-ZoneList
    Update-Clocks
}

$languageCombo.Add_SelectedIndexChanged({
    Update-Language
})

$timeZoneCombo.Add_SelectedIndexChanged({
    Update-Clocks
})

# 展开列表时更新其中的时间
$timeZoneCombo.Add_DropDown({
    Update-ZoneList
})

# 保存自定义时钟的起点和经过的时长
$customClock = @{
    BaseTime = $datePicker.Value
    Watch    = [System.Diagnostics.Stopwatch]::StartNew()
    Updating = $false
}

# 修改后以新时间为起点继续走
$datePicker.Add_ValueChanged({
    if (-not $customClock.Updating) {
        $customClock.BaseTime = $datePicker.Value
        $customClock.Watch.Restart()
    }
})

# WinForms计时器在界面线程触发，便于安全更新控件
$clockTimer = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = 1000
$clockTimer.Add_Tick({
    Complete-NetworkTimeRefresh
    # 首次取时失败后每分钟重试，成功后每十五分钟校准参考时钟。
    $refreshInterval = if ($null -eq $referenceClock.Utc) { 60 } else { 900 }
    if ($referenceClock.LastAttempt.Elapsed.TotalSeconds -ge $refreshInterval) {
        Start-NetworkTimeRefresh
    }
    Update-Clocks

    # 自定义时间 = 用户设定的起点 + 实际经过的时长
    $nextTime = $customClock.BaseTime.Add(
        $customClock.Watch.Elapsed
    )

    # 防止程序刷新触发ValueChanged后，反过来重置时钟起点
    $customClock.Updating = $true

    try {
        if ($nextTime -le $datePicker.MaxDate) { $datePicker.Value = $nextTime }
    }
    finally {
        $customClock.Updating = $false
    }
})

$form.Add_FormClosed({
    $clockTimer.Stop()
    $clockTimer.Dispose()
    if ($null -ne $referenceClock.Worker) {
        $referenceClock.Worker.Stop()
        $referenceClock.Worker.Dispose()
    }
})

Start-NetworkTimeRefresh
Update-Language
$clockTimer.Start()

[void]$form.ShowDialog()
