@echo off
setlocal
REM ============================================================
REM  PA Agent — 15 分钟周期专用实例
REM  状态目录：profiles\M15\（config / logs / records / trade_records）
REM  与主实例互不干扰，可同时打开多个周期实例。
REM ============================================================
title PA Agent [M15]

set "PA_AGENT_PROFILE=M15"
echo 启动 PA Agent 实例：周期 M15 （状态目录 profiles\M15）
echo.

call "%~dp0start_pa_agent.bat"
