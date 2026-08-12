Option Explicit

Dim shell, fileSystem, repositoryRoot, commandLine, waitForExit, exitCode
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
repositoryRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)

commandLine = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    QuoteArgument(repositoryRoot & "\proxy-manager-ui.ps1")
waitForExit = False

If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "--smoke-test" Then
        commandLine = commandLine & " -SmokeTest -Config " & _
            QuoteArgument(repositoryRoot & "\config.example.json")
        waitForExit = True
    End If
End If

On Error Resume Next
exitCode = shell.Run(commandLine, 0, waitForExit)
If Err.Number <> 0 Then
    If waitForExit Then
        WScript.Quit 1
    End If
    shell.Popup "Unable to start Clash SSH Proxy Manager:" & vbCrLf & Err.Description, _
        0, "Clash SSH Proxy Manager", 16
    WScript.Quit 1
End If
On Error GoTo 0

If waitForExit Then
    WScript.Quit exitCode
End If
WScript.Quit 0

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
