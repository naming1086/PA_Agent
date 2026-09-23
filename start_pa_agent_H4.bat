@echo off
setlocal
REM ============================================================
REM  PA Agent — 4 小时周期专用实例
REM  状态目录：profiles\H4\（config / logs / records / trade_records）
REM  与主实例互不干扰，可同时打开多个周期实例。
REM ============================================================
title PA Agent [H4]

set "PA_AGENT_PROFILE=H4"
echo 启动 PA Agent 实例：周期 H4 （状态目录 profiles\H4）
echo.

call "%~dp0start_pa_agent.bat"
