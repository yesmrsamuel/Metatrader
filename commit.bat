@echo off
setlocal enabledelayedexpansion

echo =========================================
echo    Git Auto Add, Commit, and Push Tool
echo =========================================
echo.

:: Stage all files
echo [1/3] Staging changes...
git add .
if %errorlevel% neq 0 (
    echo [ERROR] Git add failed!
    goto :error
)

:: Prompt for commit message
echo.
set /p "commit_msg=Enter commit message (Press ENTER for default): "

:: Use default message if blank
if "!commit_msg!"=="" set "commit_msg=Update MetaTrader workspace files"

:: Commit changes
echo.
echo [2/3] Committing changes with message: "!commit_msg!"
git commit -m "!commit_msg!"
if %errorlevel% neq 0 (
    echo [NOTICE] Nothing to commit or commit failed.
)

:: Push changes to GitHub
echo.
echo [3/3] Pushing to GitHub (origin main)...
git push origin main
if %errorlevel% neq 0 (
    echo [ERROR] Git push failed!
    goto :error
)

echo.
echo =========================================
echo    SUCCESS! Changes pushed to GitHub.
echo =========================================
goto :end

:error
echo.
echo Process ended with errors. Please check the output above.

:end
pause