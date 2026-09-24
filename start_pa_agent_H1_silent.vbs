' PA Agent — 静默启动（不显示控制台黑窗），周期 H1
' 日志照常写到 profiles\H1\logs\pa_agent.log
Option Explicit

Dim fso, sh, here, pyw
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here

' 该实例使用独立状态目录 profiles\H1
sh.Environment("PROCESS")("PA_AGENT_PROFILE") = "H1"

' 优先用 pythonw.exe（无控制台），缺失时退回 python.exe
pyw = here & "\.venv\Scripts\pythonw.exe"
If Not fso.FileExists(pyw) Then pyw = here & "\.venv\Scripts\python.exe"

' 第 2 个参数 0 = 隐藏窗口
sh.Run """" & pyw & """ """ & here & "\run.py""", 0, False
