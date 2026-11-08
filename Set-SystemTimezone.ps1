# 显示当前时区
$currentTimeZone = Get-TimeZone

Write-Host "Current time zone: $($currentTimeZone.Id)"

#显示目标时区
$targetTimeZoneId = "China Standard Time"

$targetTimeZone = Get-TimeZone -Id $targetTimeZoneId

Write-Host "Target time zone: $($targetTimeZone.Id)"

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

# 保存同一个时间点，保证所有时区的计算基准一致
$utcNow = [DateTime]::UtcNow

# 为每个时区创建一个包含实际 ID 和显示文字的对象
$timeZoneItems = foreach ($zone in (Get-TimeZone -ListAvailable)) {
    $localTime = [TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $zone)
    $offset = $zone.GetUtcOffset($utcNow)

    # 将偏移量格式化为 +08:00 或 -08:00
    $sign = if ($offset.Ticks -lt 0) { "-" } else { "+" }
    $offsetText = $sign + $offset.Duration().ToString("hh\:mm")

    # 初始化显示名称，后续由 Update-Language 按界面语言更新
    $name = $zone.StandardName
    $timeText = $localTime.ToString("yyyy-MM-dd HH:mm:ss")

    [PSCustomObject]@{
        Id   = $zone.Id
        Text = "$name | UTC$offsetText | $timeText"
    }
}

# 不使用数据绑定，直接把显示文字加入下拉框
$timeZoneCombo.DataSource = $null
$timeZoneCombo.DisplayMember = ""
$timeZoneCombo.ValueMember = ""
$timeZoneCombo.Items.Clear()

# 保证即使只有一个选项，也保持数组结构
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
$timeZoneCombo.DropDownWidth = 720

# 设置易读的字体
$timeZoneCombo.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

# 自定义绘制，允许设置每行高度
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

    # 绘制背景，包含选中状态
    $e.DrawBackground()

    # 在左侧留出空隙
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

# 模式一：只切换时区
$zoneMode = New-Object System.Windows.Forms.RadioButton
$zoneMode.Text = "Use current time in selected time zone"
$zoneMode.Location = New-Object System.Drawing.Point(20, 135)
$zoneMode.AutoSize = $true
$zoneMode.Checked = $true
$form.Controls.Add($zoneMode)

# 模式二：切换时区，并设置自定义时间
$customMode = New-Object System.Windows.Forms.RadioButton
$customMode.Text = "Set custom date and time"
$customMode.Location = New-Object System.Drawing.Point(20, 170)
$customMode.AutoSize = $true
$form.Controls.Add($customMode)

# 自定义时间输入框
# 输入的日期时间按“目标时区的当地时间”解释
$datePicker = New-Object System.Windows.Forms.DateTimePicker
$datePicker.Location = New-Object System.Drawing.Point(40, 205)
$datePicker.Size = New-Object System.Drawing.Size(340, 25)
$datePicker.Format = "Custom"
$datePicker.CustomFormat = "yyyy-MM-dd HH:mm:ss"
$datePicker.ShowUpDown = $true
$datePicker.Enabled = $false
$form.Controls.Add($datePicker)

# 只有选择自定义模式时，才允许编辑日期时间
$customMode.Add_CheckedChanged({
    $datePicker.Enabled = $customMode.Checked
})

# 操作结果
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 300)
$statusLabel.Size = New-Object System.Drawing.Size(420, 60)
$form.Controls.Add($statusLabel)

# 应用按钮
$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = "Apply"
$applyButton.Location = New-Object System.Drawing.Point(320, 250)
$applyButton.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($applyButton)

# 点击按钮时执行实际操作
$applyButton.Add_Click({
    $zoneChanged = $false

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

        # 修改系统前，先检查自定义时间是否有效
        if ($customMode.Checked) {
            $wallTime = [DateTime]::SpecifyKind(
                $datePicker.Value,
                [DateTimeKind]::Unspecified
            )

            # 夏令时跳转可能导致某个当地时间不存在或出现两次
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

        # 真正修改系统时区
        Set-TimeZone -Id $selectedId -ErrorAction Stop
        $zoneChanged = $true

        # 清除 .NET 缓存，让后续转换使用新的系统时区
        [TimeZoneInfo]::ClearCachedData()

        if ($customMode.Checked) {
            # 将目标时区的自定义时间转换为系统当地时间，再设置时钟
            Set-Date -Date ($customUtc.ToLocalTime()) -ErrorAction Stop |
                Out-Null
        }

        $currentLabel.Text = "Current time zone: $((Get-TimeZone).Id)"
        $statusLabel.Text = "Applied. System time: $(
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        )"
    }
    catch {
        # 时区可能已经成功切换，而修改时钟失败，分别说明结果
        $currentLabel.Text = "Current time zone: $((Get-TimeZone).Id)"

        if ($zoneChanged) {
            $statusLabel.Text = "Time zone applied, but setting the clock failed: $($_.Exception.Message)"
        }
        else {
            $statusLabel.Text = "Failed: $($_.Exception.Message)"
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
    }
}

# 先为常用时区提供中文名称，可以逐步扩充
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

# 缓存时区对象
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

    # Windows 时区 ID 本身是英文，且不受系统语言影响
    return $Id
}

function Update-Clocks {
    $text = Get-UiText
    $utcNow = [DateTime]::UtcNow
    $currentZone = Get-TimeZone

    $currentLabel.Text = "$($text.CurrentZone): $(Get-ZoneName $currentZone.Id)"
    $systemClockLabel.Text = "$($text.SystemTime): $(
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    )"

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
    $utcNow = [DateTime]::UtcNow

    # 批量修改完成后再绘制，减少闪烁
    $timeZoneCombo.BeginUpdate()

    try {
        for ($i = 0; $i -lt $timeZoneItems.Count; $i++) {
            $item = $timeZoneItems[$i]
            $zone = $zoneLookup[$item.Id]

            $localTime = [TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $zone)
            $offset = $zone.GetUtcOffset($utcNow)
            $sign = if ($offset.Ticks -lt 0) { "-" } else { "+" }
            $offsetText = $sign + $offset.Duration().ToString("hh\:mm")

            $name = Get-ZoneName $item.Id
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

# 用户修改时间后，以新时间为起点继续走
$datePicker.Add_ValueChanged({
    if (-not $customClock.Updating) {
        $customClock.BaseTime = $datePicker.Value
        $customClock.Watch.Restart()
    }
})

# WinForms 计时器在界面线程触发，便于安全更新控件
$clockTimer = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = 1000
$clockTimer.Add_Tick({
    Update-Clocks

    # 自定义时间 = 用户设定的起点 + 实际经过的时长
    $nextTime = $customClock.BaseTime.Add(
        $customClock.Watch.Elapsed
    )

    # 防止程序刷新触发 ValueChanged 后，反过来重置时钟起点
    $customClock.Updating = $true

    try {
        $datePicker.Value = $nextTime
    }
    finally {
        $customClock.Updating = $false
    }
})

$form.Add_FormClosed({
    $clockTimer.Stop()
    $clockTimer.Dispose()
})

Update-Language
$clockTimer.Start()

[void]$form.ShowDialog()