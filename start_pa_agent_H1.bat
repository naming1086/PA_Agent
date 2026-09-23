@echo off
setlocal
REM ============================================================
REM  PA Agent — 1 小时周期专用实例
REM  状态目录：profiles\H1\（config / logs / records / trade_records）
REM  与主实例互不干扰，可同时打开多个周期实例。
REM ============================================================
title PA Agent [H1]

set "PA_AGENT_PROFILE=H1"
echo 启动 PA Agent 实例：周期 H1 （状态目录 profiles\H1）
echo.

call "%~dp0start_pa_agent.bat"
