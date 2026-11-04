' WorkBuddy Keeper - hidden launcher.
'
' wscript.exe is a GUI-subsystem host: it never creates a console window, so
' nothing flashes on screen. The PowerShell backend is started with window
' style 0 (hidden) from here.
'
' Double-click this file instead of start.cmd. start.cmd is kept for
' troubleshooting only - it keeps a visible console so errors can be read.

Option Explicit

Dim fso, sh, dir, ps, cmd, appPs

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = dir

appPs = dir & "\app.ps1"

' A zip viewer (7-Zip, WinRAR, Explorer's built-in preview) extracts only the
' file that was double-clicked, into %TEMP%, and runs it from there. app.ps1 is
' then not next to us, and PowerShell would fail with a window nobody sees.
' Say what actually happened instead.
If Not fso.FileExists(appPs) Then
  MsgBox U("627E,4E0D,5230,0020,0061,0070,0070,002E,0070,0073,0031,FF0C,65E0,6CD5,542F,52A8,3002") & vbCrLf & vbCrLf & _
         U("4F60,53EF,80FD,662F,5728,538B,7F29,8F6F,4EF6,91CC,76F4,63A5,53CC,51FB,8FD0,884C,7684,3002") & vbCrLf & _
         U("538B,7F29,5305,91CC,7684,6587,4EF6,4E0D,80FD,76F4,63A5,8FD0,884C,FF0C,8BF7,5148,628A,538B,7F29,5305,89E3,538B,5230,6587,4EF6,5939,FF0C,518D,53CC,51FB,542F,52A8,3002") & vbCrLf & vbCrLf & _
         U("7F3A,5C11,6587,4EF6,FF1A") & vbCrLf & appPs, _
         16, U("0057,006F,0072,006B,0042,0075,0064,0064,0079,0020,5BF9,8BDD,7BA1,5BB6")
  WScript.Quit 1
End If

ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(ps) Then ps = "powershell.exe"

cmd = """" & ps & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
      " -WindowStyle Hidden -File """ & appPs & """"

' 0 = hidden window, False = do not wait for the process to finish
sh.Run cmd, 0, False

' Build a string from a comma separated list of hex Unicode code points.
' Keeps this file 7-bit clean while still showing Chinese in the message box:
' a .vbs is read with the OEM code page, so a UTF-8 literal would arrive as
' mojibake on any machine whose default code page is not UTF-8.
Function U(s)
  Dim a, i, out
  a = Split(s, ",")
  out = ""
  For i = 0 To UBound(a)
    out = out & ChrW(CLng("&H" & a(i)))
  Next
  U = out
End Function
