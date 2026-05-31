' Run-SaveClaudeAuto.vbs
' Wrapper invoked by the ClaudeCode-AutoSave-WezTerm scheduled task.
' Runs Save-ClaudeAuto.ps1 (its sibling) with mode 0 (hidden) so
' STARTUPINFO.wShowWindow=SW_HIDE is set before CreateProcess, which suppresses
' the Win11 default-terminal handover that flashes a Windows Terminal window.
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, "Save-ClaudeAuto.ps1")
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
