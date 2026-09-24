' PA Agent — 静默启动（不显示控制台黑窗），周期 M30
' 日志照常写到 profiles\M30\logs\pa_agent.log
Option Explicit

Dim fso, sh, here, pyw
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here

' 优先用 pythonw.exe（无控制台），缺失时退回 python.exe
pyw = here & "\.venv\Scripts\pythonw.exe"
If Not fso.FileExists(pyw) Then pyw = here & "\.venv\Scripts\python.exe"

' 第 2 个参数 0 = 隐藏窗口
' 注意：PA_AGENT_PROFILE 必须在同一条 cmd /c 里 set，再启动 pythonw，
' 这样子进程才能可靠继承（sh.Environment("PROCESS") 对 sh.Run 启动的
' 子进程经常不生效，导致周期回落到主实例的默认周期）。
sh.Run "cmd.exe /c set PA_AGENT_PROFILE=M30 && """ & pyw & """ """ & here & "\run.py""", 0, False
