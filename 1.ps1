param (
  [Parameter()]
  [switch]
  $UninstallSpotifyStoreEdition = (Read-Host -Prompt '[+ Windows] Desea desinstalar la version de spotify de la Microsoft Store? (Y/N)') -eq 'y',
  [Parameter()]
  [switch]
  $UpdateSpotify
)

# Ignorar errores de `Stop-Process`
$PSDefaultParameterValues['Stop-Process:ErrorAction'] = [System.Management.Automation.ActionPreference]::SilentlyContinue

# Cambiar colores de la consola
$Host.UI.RawUI.BackgroundColor = 'Black'
$Host.UI.RawUI.ForegroundColor = 'Green'
Clear-Host

[System.Version] $minimalSupportedSpotifyVersion = '1.2.8.923'

function Get-File {
  param (
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [System.Uri]
    $Uri,
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [System.IO.FileInfo]
    $TargetFile,
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [Int32]
    $BufferSize = 1,
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('KB', 'MB')]
    [String]
    $BufferUnit = 'MB',
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [Int32]
    $Timeout = 10000
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $useBitTransfer = $null -ne (Get-Module -Name BitsTransfer -ListAvailable) -and ($PSVersionTable.PSVersion.Major -le 5) -and ((Get-Service -Name BITS).StartType -ne [System.ServiceProcess.ServiceStartMode]::Disabled)

  if ($useBitTransfer) {
    Write-Information -MessageData '[+ Windows] Usando método alternativo de BitTransfer ya que estás ejecutando Windows PowerShell'
    Start-BitsTransfer -Source $Uri -Destination "$($TargetFile.FullName)"
  } else {
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.set_Timeout($Timeout) # Tiempo de espera de 10 segundos
    $response = $request.GetResponse()
    $totalLength = [System.Math]::Floor($response.get_ContentLength() / 1024)
    $responseStream = $response.GetResponseStream()
    $targetStream = New-Object -TypeName ([System.IO.FileStream]) -ArgumentList "$($TargetFile.FullName)", 'Create'
    switch ($BufferUnit) {
      'KB' { $BufferSize = $BufferSize * 1024 }
      'MB' { $BufferSize = $BufferSize * 1024 * 1024 }
      Default { $BufferSize = 1024 * 1024 }
    }
    Write-Verbose -Message "[+ Windows] Tamano del buffer: $BufferSize B ($($BufferSize/("1$BufferUnit")) $BufferUnit)"
    $buffer = New-Object byte[] $BufferSize
    $count = $responseStream.Read($buffer, 0, $buffer.length)
    $downloadedBytes = $count
    $downloadedFileName = $Uri -split '/' | Select-Object -Last 1
    while ($count -gt 0) {
      $targetStream.Write($buffer, 0, $count)
      $count = $responseStream.Read($buffer, 0, $buffer.length)
      $downloadedBytes += $count
      Write-Progress -Activity "[+ Windows] Descargando archivo '$downloadedFileName'" -Status "Descargado ($([System.Math]::Floor($downloadedBytes/1024))K de $($totalLength)K): " -PercentComplete ((([System.Math]::Floor($downloadedBytes / 1024)) / $totalLength) * 100)
    }
    Write-Progress -Activity "[+ Windows] Archivo '$downloadedFileName' descargado"
    $targetStream.Flush()
    $targetStream.Close()
    $responseStream.Close()
  }
}

function Test-SpotifyVersion {
  param (
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [System.Version]
    $MinimalSupportedVersion,
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [System.Version]
    $TestedVersion
  )
  process {
    return ($MinimalSupportedVersion.CompareTo($TestedVersion) -le 0)
  }
}

Write-Host @'
**********************************
[+ Windows] [UTILIDAD SPOTIFY]
**********************************
'@

$spotifyDirectory = Join-Path -Path $env:APPDATA -ChildPath 'Spotify'
$spotifyExecutable = Join-Path -Path $spotifyDirectory -ChildPath 'Spotify.exe'
$spotifyApps = Join-Path -Path $spotifyDirectory -ChildPath 'Apps'

[System.Version] $actualSpotifyClientVersion = (Get-ChildItem -LiteralPath $spotifyExecutable -ErrorAction SilentlyContinue).VersionInfo.ProductVersionRaw

Write-Host "[+ Windows] Deteniendo Spotify...`n"
Stop-Process -Name Spotify
Stop-Process -Name SpotifyWebHelper

if ($PSVersionTable.PSVersion.Major -ge 7) {
  Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
}

if (Get-AppxPackage -Name SpotifyAB.SpotifyMusic) {
  Write-Host "[+ Windows] Se detecto la version de la tienda de Microsoft de Spotify, que no es compatible.`n"

  if ($UninstallSpotifyStoreEdition) {
    Write-Host "[+ Windows] Desinstalando Spotify.`n"
    Get-AppxPackage -Name SpotifyAB.SpotifyMusic | Remove-AppxPackage
  } else {
    Read-Host "[+ Windows] Saliendo...`nPresiona cualquier tecla para salir..."
    exit
  }
}

Push-Location -LiteralPath $env:TEMP
try {
  New-Item -Type Directory -Name "BlockTheSpot-$(Get-Date -UFormat '%Y-%m-%d_%H-%M-%S')" | Convert-Path | Set-Location
}
catch {
  Write-Output $_
  Read-Host '[+ Windows] Presiona cualquier tecla para salir...'
  exit
}

$spotifyInstalled = Test-Path -LiteralPath $spotifyExecutable

if (-not $spotifyInstalled) {
  $unsupportedClientVersion = $true
} else {
  $unsupportedClientVersion = ($actualSpotifyClientVersion | Test-SpotifyVersion -MinimalSupportedVersion $minimalSupportedSpotifyVersion) -eq $false
}

if (-not $UpdateSpotify -and $unsupportedClientVersion) {
  if ((Read-Host -Prompt '[+ Windows] Para instalar SPOTIFY/BYPASS tu cliente de Spotify debe actualizarse Deseas continuar? (Y/N)') -ne 'y') {
    exit
  }
}

if (-not $spotifyInstalled -or $UpdateSpotify -or $unsupportedClientVersion) {
  Write-Host '[+ Windows] Descargando la ultima version completa de Spotify, por favor espera...'
  $spotifySetupFilePath = Join-Path -Path $PWD -ChildPath 'SpotifyFullSetup.exe'
  try {
    if ([Environment]::Is64BitOperatingSystem) {
      $uri = 'https://download.scdn.co/SpotifyFullSetupX64.exe'
    } else {
      $uri = 'https://download.scdn.co/SpotifyFullSetup.exe'
    }
    Get-File -Uri $uri -TargetFile "$spotifySetupFilePath"
  }
  catch {
    Write-Output $_
    Read-Host '[+ Windows] Presiona cualquier tecla para salir...'
    exit
  }
  New-Item -Path $spotifyDirectory -ItemType Directory -Force | Write-Verbose

  [System.Security.Principal.WindowsPrincipal] $principal = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $isUserAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
  Write-Host '[+ Windows] Ejecutando instalacion...'
  if ($isUserAdmin) {
    Write-Host '[+ Windows] Creando tarea programada...'
    $apppath = 'powershell.exe'
    $taskname = 'Instalar Spotify'
    $action = New-ScheduledTaskAction -Execute $apppath -Argument "-NoLogo -NoProfile -Command & `'$spotifySetupFilePath`'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -WakeToRun
    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskname -Settings $settings -Force | Write-Verbose
    Write-Host '[+ Windows] La tarea de instalacion ha sido programada. Iniciando la tarea...'
    Start-ScheduledTask -TaskName $taskname
    Start-Sleep -Seconds 2
    Write-Host '[+ Windows] Eliminando la tarea...'
    Unregister-ScheduledTask -TaskName $taskname -Confirm:$false
  } else {
    try {
      Start-Process -FilePath "$spotifySetupFilePath" -Verb RunAs -Wait
    }
    catch {
      Write-Host '[+ Windows] Error: instalacion fallida.'
      exit
    }
  }
}

Write-Host '[+ Windows] Listo La ultima version de Spotify se ha instalado con exito.'
Pop-Location
