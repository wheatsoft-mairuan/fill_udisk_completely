<#
.SYNOPSIS
    彻底填满U盘直到空间耗尽，并报告实际填充大小。
.DESCRIPTION
    此脚本会提示用户选择一个目标文件夹（通常为U盘的根目录），
    然后在该文件夹中持续生成临时文件，每次尝试写入小数据块，
    直至磁盘空间完全耗尽（无法再写入任何字节），最后以GB、MB、KB为单位
    显示实际写入的总数据量。
.NOTES
    文件名：Fill-Udisk-Completely.ps1
    版本：2.0
    仅供娱乐，注意备份数据
#>

# 引入用于选择文件夹的程序集
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 设置错误动作：继续执行（我们需要捕获异常）
$ErrorActionPreference = 'Continue'

# 初始化总写入字节数
$totalBytesWritten = 0

# 临时文件的前缀和后缀
$filePrefix = "FillTemp_"
$fileSuffix = ".dat"

# 单次写入的块大小（使用更小的块以便更精确地填满）
$blockSize = 64KB

# 生成的文件初始大小（先尝试写入大文件提高速度）
$initialFileSize = 500MB

# 当剩余空间小于此值时，切换到小文件模式
$smallFileThreshold = 100MB

# 小文件模式下每次写入的文件大小（逐步减小以精确填满）
$smallFileSizes = @(50MB, 10MB, 5MB, 1MB, 512KB, 256KB, 128KB, 64KB, 32KB, 16KB, 8KB, 4KB, 2KB, 1KB)

# 选择文件夹对话框
$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = "请选择要填充的目标文件夹（例如 U 盘的根目录）"
$folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
$folderBrowser.ShowNewFolderButton = $true

# 显示对话框，并检查用户是否点击了“确定”
if ($folderBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "用户取消了选择，脚本退出。" -ForegroundColor Yellow
    exit
}

$targetFolder = $folderBrowser.SelectedPath
Write-Host "目标文件夹: $targetFolder" -ForegroundColor Cyan

# 检查目标文件夹是否存在
if (-not (Test-Path -Path $targetFolder -PathType Container)) {
    Write-Host "错误：选择的路径不是有效文件夹。" -ForegroundColor Red
    exit
}

# 获取当前驱动器的信息
$driveInfo = Get-PSDrive -Name (Get-Item $targetFolder).PSDrive.Name
$driveRoot = $driveInfo.Root
$freeSpaceBefore = $driveInfo.Free
$totalSpaceBefore = $driveInfo.Used + $driveInfo.Free

Write-Host "目标驱动器: $driveRoot"
Write-Host "驱动器总容量: $([math]::Round($totalSpaceBefore / 1GB, 2)) GB"
Write-Host "当前剩余空间: $([math]::Round($freeSpaceBefore / 1MB, 2)) MB"
Write-Host "开始彻底填充操作..."
Write-Host "---------------------------------------------"

# 计数器
$fileIndex = 1
$phase = "initial"  # 阶段: initial(大文件), small(小文件), final(最终)
$currentSmallSizeIndex = 0

try {
    while ($true) {
        # 获取当前剩余空间
        $currentFree = (Get-PSDrive -Name (Get-Item $targetFolder).PSDrive.Name).Free
        
        # 显示当前状态
        Write-Host "当前剩余空间: $([math]::Round($currentFree / 1MB, 2)) MB" -ForegroundColor Gray
        
        # 如果剩余空间小于1KB，认为已经彻底填满
        if ($currentFree -lt 1KB) {
            Write-Host "剩余空间已小于1KB，U盘已彻底填满！" -ForegroundColor Green
            break
        }
        
        # 确定本次要创建的文件大小
        $currentFileSize = 0
        
        if ($phase -eq "initial") {
            # 初始阶段：使用大文件快速填充
            if ($currentFree -gt $smallFileThreshold) {
                # 文件大小不能超过剩余空间（留一点余量）
                $currentFileSize = [math]::Min($initialFileSize, $currentFree - 10MB)
                if ($currentFileSize -le 0) {
                    $currentFileSize = $currentFree - 1MB
                }
            } else {
                # 剩余空间低于阈值，切换到小文件模式
                $phase = "small"
                Write-Host "剩余空间低于阈值，切换到小文件精确填充模式..." -ForegroundColor Yellow
                continue
            }
        }
        
        if ($phase -eq "small") {
            # 小文件模式：使用递减的文件大小列表
            if ($currentSmallSizeIndex -lt $smallFileSizes.Count) {
                $currentFileSize = $smallFileSizes[$currentSmallSizeIndex]
                # 如果当前设定的大小大于剩余空间，则尝试更小的尺寸
                if ($currentFileSize -ge $currentFree) {
                    $currentSmallSizeIndex++
                    continue
                }
            } else {
                # 小文件列表用尽，进入最终模式：每次写入一个块大小
                $phase = "final"
                Write-Host "小文件列表用尽，进入最终块写入模式..." -ForegroundColor Yellow
                continue
            }
        }
        
        if ($phase -eq "final") {
            # 最终模式：每次写入一个数据块，尽可能填满剩余空间
            $currentFileSize = [math]::Min($blockSize, $currentFree)
            if ($currentFileSize -le 0) {
                break
            }
        }
        
        # 确保文件大小至少为1字节且不超过剩余空间
        $currentFileSize = [math]::Max(1, [math]::Min($currentFileSize, $currentFree))
        
        # 生成新文件名
        do {
            $fileName = "$filePrefix$fileIndex$fileSuffix"
            $filePath = Join-Path -Path $targetFolder -ChildPath $fileName
            $fileIndex++
        } while (Test-Path -Path $filePath)
        
        Write-Host "正在创建: $fileName (目标大小: $([math]::Round($currentFileSize / 1KB, 0)) KB) ..." -NoNewline
        
        # 创建文件并写入数据
        $bytesWrittenThisFile = 0
        $fileSuccess = $false
        
        try {
            $fileStream = [System.IO.File]::OpenWrite($filePath)
            $stream = New-Object System.IO.BinaryWriter($fileStream)
            
            # 根据当前剩余空间动态调整块大小（最终模式使用小块的目的是精确填充）
            $writeBlockSize = $blockSize
            if ($phase -eq "final") {
                $writeBlockSize = 4KB  # 最终模式使用更小的块
            }
            
            $buffer = New-Object byte[] $writeBlockSize
            
            while ($bytesWrittenThisFile -lt $currentFileSize) {
                $remaining = $currentFileSize - $bytesWrittenThisFile
                $writeSize = [math]::Min($writeBlockSize, $remaining)
                
                if ($writeSize -lt $writeBlockSize) {
                    $buffer = New-Object byte[] $writeSize
                }
                
                $stream.Write($buffer, 0, $writeSize)
                $bytesWrittenThisFile += $writeSize
            }
            
            $stream.Close()
            $fileStream.Close()
            
            # 验证文件大小是否正确（防止某些情况下写入不完全）
            $actualFileSize = (Get-Item $filePath).Length
            if ($actualFileSize -ne $currentFileSize) {
                Write-Host " 警告：文件大小不符，预期 $currentFileSize，实际 $actualFileSize" -ForegroundColor Red
                $bytesWrittenThisFile = $actualFileSize
            }
            
            $totalBytesWritten += $bytesWrittenThisFile
            $fileSuccess = $true
            
            Write-Host " 完成 (实际写入: $([math]::Round($bytesWrittenThisFile / 1KB, 0)) KB)" -ForegroundColor Green
            
            # 如果是在小文件模式下成功写入，增加索引以尝试更小的文件大小
            if ($phase -eq "small") {
                $currentSmallSizeIndex++
            }
            
        } catch {
            # 写入失败，可能是磁盘已满
            Write-Host " 写入失败: $_" -ForegroundColor Red
            
            # 尝试删除可能不完整的文件
            if (Test-Path $filePath) {
                Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
            }
            
            # 如果是最终模式且写入失败，说明已经无法再写入任何数据
            if ($phase -eq "final") {
                Write-Host "无法再写入任何数据，U盘已彻底填满。" -ForegroundColor Green
                break
            } else {
                # 否则切换到最终模式继续尝试
                $phase = "final"
                Write-Host "切换到最终块写入模式继续尝试..." -ForegroundColor Yellow
                continue
            }
        }
        
        # 小文件模式下，如果当前索引已用完，切换到最终模式
        if ($phase -eq "small" -and $currentSmallSizeIndex -ge $smallFileSizes.Count) {
            $phase = "final"
            Write-Host "小文件列表已用尽，进入最终块写入模式..." -ForegroundColor Yellow
        }
        
        # 防止无限循环（安全措施）
        if ($fileIndex -gt 10000) {
            Write-Host "达到最大文件数限制，停止填充。" -ForegroundColor Red
            break
        }
    }
} catch {
    Write-Host "脚本执行过程中发生意外错误: $_" -ForegroundColor Red
}

Write-Host "---------------------------------------------"
Write-Host "填充操作结束。" -ForegroundColor Cyan

# 最终检查剩余空间
$finalFree = (Get-PSDrive -Name (Get-Item $targetFolder).PSDrive.Name).Free
$usedChange = $freeSpaceBefore - $finalFree

# 确保总写入字节数与剩余空间减少量一致（取较大值，因为可能有之前残留的文件）
$totalBytesWritten = [math]::Max($totalBytesWritten, $usedChange)

# 计算最终写入的总数据量（GB, MB, KB）
$totalGB = $totalBytesWritten / 1GB
$totalMB = $totalBytesWritten / 1MB
$totalKB = $totalBytesWritten / 1KB

# 格式化输出
Write-Host "`n实际填充的总数据量:" -ForegroundColor White
Write-Host "  GB : $([math]::Round($totalGB, 3)) GB" -ForegroundColor Yellow
Write-Host "  MB : $([math]::Round($totalMB, 2)) MB" -ForegroundColor Yellow
Write-Host "  KB : $([math]::Round($totalKB, 0)) KB" -ForegroundColor Yellow

# 显示剩余空间信息
Write-Host "`n最终剩余空间: $([math]::Round($finalFree / 1KB, 0)) KB" -ForegroundColor Gray
Write-Host "驱动器剩余空间减少: $([math]::Round($usedChange / 1MB, 2)) MB" -ForegroundColor Gray

# 如果剩余空间大于0，提示已尽可能填满
if ($finalFree -gt 0) {
    Write-Host "`n注意：仍有 $([math]::Round($finalFree / 1KB, 0)) KB 剩余空间无法写入（可能由于文件系统预留块或权限限制）" -ForegroundColor Yellow
} else {
    Write-Host "`nU盘已完全填满，没有剩余空间！" -ForegroundColor Green
}

# 暂停，以便用户查看结果
Write-Host "`n按任意键退出..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")