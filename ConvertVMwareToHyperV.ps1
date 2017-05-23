#This change is in Branch 1
#This script creates a new VM, converts VMDK to VHDX, attaches the disk, and starts the VM


#region: Common Parameters

$OsCSVsPath = @("C:\ClusterStorage\Volume2","C:\ClusterStorage\Volume4")
$VMMClusterName = "dcVMMHA"

$QEMUToolsPath = "C:\qemu-img-win-x64-2_3_0"

#endregion

#region: Functions
Function Select-Item 
{    
#Source: https://blogs.technet.microsoft.com/jamesone/2009/06/24/how-to-get-user-input-more-nicely-in-powershell/
<# 
     .Synopsis
        Allows the user to select simple items, returns a number to indicate the selected item. 

    .Description 

        Produces a list on the screen with a caption followed by a message, the options are then
        displayed one after the other, and the user can one. 
  
        Note that help text is not supported in this version. 

    .Example 

        PS> select-item -Caption "Configuring RemoteDesktop" -Message "Do you want to: " -choice "&Disable Remote Desktop",
           "&Enable Remote Desktop","&Cancel"  -default 1
       Will display the following 
  
        Configuring RemoteDesktop   
        Do you want to:   
        [D] Disable Remote Desktop  [E] Enable Remote Desktop  [C] Cancel  [?] Help (default is "E"): 

    .Parameter Choicelist 

        An array of strings, each one is possible choice. The hot key in each choice must be prefixed with an & sign 

    .Parameter Default 

        The zero based item in the array which will be the default choice if the user hits enter. 

    .Parameter Caption 

        The First line of text displayed 

     .Parameter Message 

        The Second line of text displayed     
#> 

Param(   [String[]]$choiceList, 

         [String]$Caption="Please make a selection", 

         [String]$Message="Choices are presented below", 

         [int]$default=0 

      ) 

   $choicedesc = New-Object System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription] 

   $choiceList | foreach  { $choicedesc.Add((New-Object "System.Management.Automation.Host.ChoiceDescription" -ArgumentList $_))} 

   $Host.ui.PromptForChoice($caption, $message, $choicedesc, $default) 
}
Function Input-Text
{
    $Field = New-Object System.Collections.ObjectModel.Collection[System.Management.Automation.Host.FieldDescription]
    $Prop = New-Object 'System.Collections.IDictionary'
    $Field.Add((New-Object 'System.Management.Automation.Host.FieldDescription' -ArgumentList "VM Name" -Property "test"))
    $VMName = $Host.UI.Prompt("Caption","Message",$Field)
}
  
#endregion

#region: Inputs

#Admin Credentials

$AdminCredsCheck = $false
do
{
    $AdminCreds = Get-Credential -UserName "dmsd\walmoselhy-a" -Message "Admin password for VMM and Hyper-V"
    try
    {
        Start-Process cmd.exe -ArgumentList "/C" -Credential $AdminCreds
        $AdminCredsCheck = $true
    }
    Catch
    {
     
    }
}
while ($AdminCredsCheck -eq $false)

#Select Hyper-V Host
$HVHostList = "srvHV&1","srvHV&2"
$HVHost = $HVHostList[(Select-Item -choiceList $HVHostList -Caption "Hyper-V Host Name" -Message "Please select a Hyper-V host" -default 0)].Replace("&","").ToString()

#Input VM Name
    $Field = New-Object System.Collections.ObjectModel.Collection[System.Management.Automation.Host.FieldDescription]
    $Field.Add((New-Object 'System.Management.Automation.Host.FieldDescription' -ArgumentList "VM Name"))
$VMName = [string]$Host.UI.Prompt("VM Name","Please input the VM Name",$Field).values

#Select VM Generation
$VMTemplateList = "Blank Generation &1 Template","Blank Generation &2 Template"
$VMTemplate = $VMTemplateList[(Select-Item -choiceList $VMTemplateList -Caption "VM Template" -Message "Please select a template to use for the VM:" -default 0)].Replace("&","").ToString()

#VMDK Path
    $Field = New-Object System.Collections.ObjectModel.Collection[System.Management.Automation.Host.FieldDescription]
    $Field.Add((New-Object 'System.Management.Automation.Host.FieldDescription' -ArgumentList "Path"))
$VMDKPath = [string]$Host.UI.Prompt("VMDK Path","Please input path to the VMDK file",$Field).values.replace("""","")

#endregion

#region: Main part

#Create new session on HVHost
$HVHostSession = New-PSSession -ComputerName srvHV1 -Credential $AdminCreds -Authentication Kerberos

Write-Host "Created a new session on srvHV1."    

#Connect to VMM Cluster
Import-Module -Name virtualmachinemanager
Get-VMMServer -ComputerName $VMMClusterName -Credential $AdminCreds | Out-Null

Write-Host "Connected to $VMMClusterName."


#Find most appropriate CSV (by number of VMs stored)
$TargetCSV = (Invoke-Command -Session $HVHostSession -ArgumentList (,$OsCSVsPath) -ScriptBlock {
    Param ($OsCSVsPath)
    $FolderCountArray = @()
    Try{
        foreach ($path in $OsCSVsPath)
        {
            $FolderCountArray += [PSCustomObject]@{Path = $Path;FolderCount = (Get-ChildItem -Path $path).count}
        }
        $Error[0]
        return $FolderCountArray | Sort-Object -Property FolderCount | Select-Object -First 1
    }
    Catch
    {
        Throw $Error[0]
    }   
}).Path

Write-Host "Selected $TargetCSV for VM Placement."

#Create VM using selected template
$VM = New-SCVirtualMachine -VMTemplate $VMTemplate -Name $VMName -VMHost $VMHost -Path $TargetCSV

Write-Host "Created VM."

#Convert VMDK to VHDX fixed using QEMU tools
$VHDXPath = "$TargetCSV\$VMName\$VMName`_OS.VHDX"

$QEMUArguments = "convert `"$VMDKPath`" -O vhdx -o subformat=fixed `"$VHDXPath`""

Write-Host "Starting VMDK to VHDX conversion using QEMU tools."
Write-Host "QEMU arguments: $QEMUArguments"

$VMDKtoVHDXTime = Measure-Command -Expression {
    Invoke-Command -Session $HVHostSession -ArgumentList ($QEMUToolsPath,$QEMUArguments) -ScriptBlock {
        Param ($QEMUToolsPath, $QEMUArguments)
        Try
        {
            Start-Process -Wait -FilePath "$QEMUToolsPath\qemu-img.exe" -ArgumentList $QEMUArguments
        }
        Catch
        {
            Throw $Error[0]
        }
    }
    }

Write-Host "Completed VMDK conversion in"$VMDKtoVHDXTime.ToString()

#Optimize VHDX

Write-Host "Starting VHDX optimization."

$VHDXOptimizationTime = Measure-Command -Expression {
    Invoke-Command -Session $HVHostSession -ArgumentList ($VHDXPath) -ScriptBlock {
        Param ($VHDXPath)
        Try
        {
            Optimize-VHD -Path $VHDXPath
        }
        Catch
        {
            Throw $Error[0]
        }
    }
    }

Write-Host "Completed VHDX optimization in"$VHDXOptimizationTime.ToString()

#Add VHDX to VM


switch ($VM.Generation)
{
    1 {New-SCVirtualDiskDrive -VM $VMName -Path "$TargetCSV\$VMName" -FileName "$VMName`_OS.VHDX" -UseLocalVirtualHardDisk -VolumeType BootAndSystem -IDE -Bus 0 -LUN 0 | Out-Null}
    2 {New-SCVirtualDiskDrive -VM $VMName -Path "$TargetCSV\$VMName" -FileName "$VMName`_OS.VHDX" -UseLocalVirtualHardDisk -VolumeType BootAndSystem -SCSI -Bus 0 -LUN 0| Out-Null}
}

Write-Host "Attached VHDX to VM."

#Start VM

Start-SCVirtualMachine -VM $VM

Write-Host "Conversion Complete. Starting VM."


#Close open session
Get-PSSession | Remove-PSSession

#endregion