@echo off
chcp 65001 >nul
title FQ Oracle (fanqie app source)
set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "ADB=%SDK%\platform-tools\adb.exe"

echo [1/4] 启动模拟器 fqsig（冷启动约 2 分钟）...
start "" "%SDK%\emulator\emulator.exe" -avd fqsig -gpu swiftshader_indirect -memory 4096 -no-boot-anim -no-snapshot

echo [2/4] 等待设备 + 系统启动完成...
"%ADB%" wait-for-device
:waitboot
"%ADB%" shell getprop sys.boot_completed 2>nul | findstr "1" >nul
if errorlevel 1 (timeout /t 5 /nobreak >nul & goto waitboot)
echo       已开机

echo [3/4] adb root + frida-server + 启动番茄...
"%ADB%" root >nul 2>&1
timeout /t 2 /nobreak >nul
"%ADB%" shell "pkill -f frida-server; nohup /data/local/tmp/frida-server -D >/dev/null 2>&1 &" >nul 2>&1
timeout /t 2 /nobreak >nul
"%ADB%" shell "monkey -p com.dragon.read -c android.intent.category.LAUNCHER 1" >nul 2>&1
echo       等待番茄网络栈就绪（12s）...
timeout /t 12 /nobreak >nul

echo [4/4] 启动 oracle HTTP 服务 0.0.0.0:8765（Ctrl+C 停止）...
cd /d %~dp0
python oracle_server.py 8765
