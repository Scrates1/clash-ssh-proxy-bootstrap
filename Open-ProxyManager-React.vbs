Option Explicit

Dim shell, fileSystem, repositoryRoot, commandLine
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
repositoryRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)

commandLine = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    QuoteArgument(repositoryRoot & "\proxy-manager-react-host.ps1") & " -OpenBrowser"

On Error Resume Next
shell.Run commandLine, 0, False
If Err.Number <> 0 Then
    shell.Popup "Unable to start the React UI:" & vbCrLf & Err.Description, _
        0, "Clash SSH Proxy Manager", 16
    WScript.Quit 1
End If
On Error GoTo 0
WScript.Quit 0

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
