' WorkBuddy Keeper - hidden launcher.
'
' wscript.exe is a GUI-subsystem host: it never creates a console window, so
' nothing flashes on screen. The PowerShell backend is started with window
' style 0 (hidden) from here.
'
' Double-click this file instead of start.cmd. start.cmd is kept for
' troubleshooting only - it keeps a visible console so errors can be read.

Option Explicit

Dim fso, sh, dir, ps, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = dir

ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(ps) Then ps = "powershell.exe"

cmd = """" & ps & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
      " -WindowStyle Hidden -File """ & dir & "\app.ps1"""

' 0 = hidden window, False = do not wait for the process to finish
sh.Run cmd, 0, False
