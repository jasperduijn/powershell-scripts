<#
    .SYNOPSIS
        Script to download configs of network devices over SSH using a TFTP server
    .DESCRIPTION
        Gather network device configuration with TFTP over SSH.
            1. Validate the given config files path
            2. Take input for process names to kill, name of program, destination, and excluded items to not search for or download

    .PARAMETER Path
        Accepts a single Json file in array format
    .PARAMETER Name
        Name of the Program you wish to find in the Json File
    .PARAMETER Process
        Process name that you are going to kill
    .PARAMETER Destination
        Destination that you wish to download the files to
    .PARAMETER ExcludedItems
        Exclusion list for to keep from copying the listed files or folders or directories
    .PARAMETER LogPath
        Path of the logfile you want it to log to. Default is C:\Temp.
    .PARAMETER Clean
        Switch to forcfully clean the downloaded files, even if there was an error during install
    .INPUTS
        Json and String based items
    .OUTPUTS
        Description of objects that are output by the script.
    .EXAMPLE
        Install-SoftwareTemplate -Path \\Server\Path\Here\Json.Json
    .EXAMPLE
        Install-SoftwareTemplate -Path \\Server\Path\Here\Json.Json -Name FakeProgramListed
    .LINK
        https://github.com/jasperduijn/powershell-scripts/blob/master/Get-Switchconfig/README.md
    .NOTES
        None
#>

#Optional parameters
# {0} = hostname
$Filenamestructure = "$(get-date -format 'yyMMdd') {0} running-config.txt" # Example: "200917 SJ-SER1-SW01 running-config.txt"

$PredefinedCommands = @()
# {0} = TFTP server IP 
# {1} = filename
$PredefinedCommands += New-Object PSObject -Property @{brand = "Aruba"; function = "backup"; command = "copy running-config tftp {0} '{1}'"}

$TFTPserverIP = (Resolve-DnsName -Name $env:computername -Type A).IPAddress #Get's current IP
#$Logfile = ""

###############################################
## Do not change below this line
###############################################
try {
    Import-Module Posh-SSH
} catch {
    if (!(Get-Module "Posh-SSH")) {
        Write-Host "Module Posh-SSH not installed"
        # Self-elevate the script if required
        if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
            if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
                Write-Host "Not running as administrator. Elevating script to admin"
                $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
                Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine
                Exit
            }
        } else {
            Write-Host "Please wait while downloading and installing Posh-SSH module...."
            Install-Module Posh-SSH
            Set-ExecutionPolicy Bypass
            Import-Module Posh-SSH
        }
    }
}

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") 

$defaultcredentials = Get-Credential -Message "Enter de default credentials for the networkdevices"

Function LogWrite
{
    Param(
        [Parameter(Mandatory=$true, ValueFromPipeLine=$true, ValueFromPipeLineByPropertyName=$true, Position=0)] [String]$logstring, 
        [Parameter(Mandatory=$false, Position=1)] [ValidateSet("Black","Blue","Cyan","DarkBlue","DarkCyan","DarkGray","DarkGreen","DarkMagenta","DarkRed","DarkYellow","Gray","Green","Magenta","Red","White","Yellow")] [String]$Color = "White"
    )
    if(-Not($Logfile)){$Logfile = "$pwd/$(get-date -format 'yyMMdd') script.log"}
    Write-Host ("{0} - {1}" -f (Get-Date), $logstring) -foregroundcolor $Color
    Add-content $Logfile -value ("{0} - {1}" -f (Get-Date), $logstring)
}

Function Start-TFTPDserver
{
    try { 
        # Is al actief check
        if (-Not(Test-Path "$PWD\OpenTFTPServerMT.ini")) { LogWrite "GENERAL ERROR: TFTP server INI doesn't exist" Red; throw ".INI file doesn't exist" }
        Start-Process -WorkingDirectory $pwd -WindowStyle Minimized "$PWD\OpenTFTPServerMT" "-v"
        LogWrite "GENERAL INFO: TFTP server started"
    } catch {
        LogWrite "GENERAL ERROR: TFTPserver not started" Red
        throw "GENERAL ERROR: TFTPserver not started"
    }
}

function Stop-TFTPDserver {
    try {
        $process = Get-Process -Name "OpenTFTPServerMT" 
        $process | Stop-Process -Force 
        LogWrite "GENERAL INFO: TFTP server stopped"
    } catch {
        LogWrite "GENERAL ERROR: Couldn't stop TFTPserver. Is it running?" Red
    }
}

function Connect-SSHDevice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$IP,

        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential[]]$credentials
    )
    try {
        $SSHSession = New-SSHSession -ComputerName $device.IP -Credential $devicecredentials -AcceptKey
        $SSHStream = New-SSHShellStream -SessionId $SSHSession.SessionId
        $SSHStream.WriteLine("") # Press enter to continue
        return $SSHSession,$SSHStream
    } catch {
        LogWrite "$($device.hostname) ERROR: Session couldn't be established" Red
    }
}

function Get-RunningConfigs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [PSObject[]]$device
    )

    try {
        $Filename = $Filenamestructure -f $device.hostname
        $command = (($PredefinedCommands | Where-Object { $_.brand -match $device.brand}).command -f $TFTPserverIP, $Filename)
        $null = Invoke-SSHStreamShellCommand -ShellStream $SSHStream -Command $command
        $null = Get-SSHSession | Remove-SSHSession # SSH Sessie sluiten

        try {
            $Timeout = 10
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while (($timer.Elapsed.TotalSeconds -lt $Timeout) -and (-not (Test-Path -Path "$($pwd)\$($Filename)" -PathType Leaf))) {
                Start-Sleep -Milliseconds 200
            }
            $timer.Stop()
            if (-not (Test-Path -Path "$($pwd)\$($Filename)")){ throw ""}
            if (!(Test-Path -path "$($pwd)\$($device.hostname)")) {$null = New-Item "$($pwd)\$($device.hostname)" -Type Directory}
            $null = Copy-Item "$($pwd)\$($Filename)" "$($pwd)\$($device.hostname)\$($Filename)" -Recurse -Force

            if (!(Test-Path -path "$($pwd)\$(get-date -format 'yyMMdd') running-configs")) {$null = New-Item "$($pwd)\$(get-date -format 'yyMMdd') running-configs" -Type Directory}
            $null = Move-Item "$($pwd)\$($Filename)" "$($pwd)\$(get-date -format 'yyMMdd') running-configs\$($Filename)" -Force
            LogWrite "$($device.hostname) INFO: Copied running-config to $($pwd)\$($device.hostname)\$($Filename)" Green
        } catch {
            LogWrite "$($device.hostname) ERROR: copy time-out. Is the firewall blocking TFTP?" Red
        }
        
    } catch {
        LogWrite "$($device.hostname) ERROR: error sending command" Red
    }     
}

Function Send-CustomSSHCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [PSObject[]]$device
    )
}

Function Invoke-DeviceBackup  {
    Param(
        [Parameter(Mandatory=$false, ValueFromPipeLine=$true, ValueFromPipeLineByPropertyName=$true,Position=0)]
            [ValidateNotNullorEmpty()]
            [String]$Path=$null,

        [Parameter(ValueFromPipeLine=$true, ValueFromPipeLineByPropertyName=$true,Position=1)]
            [String]$Delimiter=";"
    )

    if (!($Path)) {
        $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{
        Title = "Selecteer CSV switches" 
        InitialDirectory = $PWD
        Filter = 'Switches CSV (*.csv)|*.csv'
        }  
        $result = $FileBrowser.ShowDialog()
    
        if ($result -eq "OK") {    
            $Path = $FileBrowser.FileName
        } else {
            LogWrite "Switches CSV File selection cancelled." Red
            Exit
        }
    }
    
    $devices = Import-Csv -Delimiter ";" -Path $Path
    $devices | ForEach-Object {
        if ($_.defaultcredentials -eq "True"){ 
            $_.defaultcredentials = $true
        }
    }
    try { 
        Start-TFTPDserver -ErrorAction Stop
    } catch {
        LogWrite "GENERAL ERROR: error starting TFTP server" Red
        exit
    }

    foreach ($device in $devices) {
        if ($device.defaultcredentials) { $devicecredentials = $defaultcredentials } else { $devicecredentials = Get-Credential -Message "Enter credentials for $($device.hostname)"}
        $SSHSession,$SSHStream = Connect-SSHDevice -IP $device.IP -Credentials $devicecredentials

        if ($device.Function -eq "backup") {
            Get-Runningconfigs $device
        } elseif ($device.command) {
            Invoke-CustomSSHCommand -Command "Command" -SSHSession
        }
        
    }
    Stop-TFTPDserver
}


Invoke-DeviceBackup