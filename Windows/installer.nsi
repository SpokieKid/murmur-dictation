Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!define VERSION "0.6.0"
Name "Murmur Windows"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\Murmur"
InstallDirRegKey HKCU "Software\Murmur" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
VIProductVersion "0.6.0.0"
VIAddVersionKey "ProductName" "Murmur Windows"
VIAddVersionKey "FileDescription" "Murmur Windows preview installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Murmur contributors · MIT"
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${PROJECT_ROOT}/LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\Murmur.exe"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "Murmur requires 64-bit Windows 10 or Windows 11."
    Abort
  ${EndIf}
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "Murmur requires Windows 10 or Windows 11."
    Abort
  ${EndIf}
  SetRegView 64
  retry:
  FindWindow $0 "" "Murmur · Windows"
  ${If} $0 != 0
    MessageBox MB_RETRYCANCEL|MB_ICONINFORMATION "请先从系统托盘退出 Murmur，再继续安装。$\nQuit Murmur from the system tray before continuing." IDRETRY retry IDCANCEL stop
    stop:
    Abort
  ${EndIf}
FunctionEnd

Section "Murmur" SecMain
  SectionIn RO
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File "${PAYLOAD_DIR}/Murmur.exe"
  File /oname=LICENSE.txt "${PROJECT_ROOT}/LICENSE"
  File /oname=使用说明.txt "${PROJECT_ROOT}/Windows/使用说明.txt"
  File /oname=dotnet-notices.txt "${BUILD_DIR}/runtime-notices.txt"
  CreateDirectory "$SMPROGRAMS\Murmur"
  CreateShortcut "$SMPROGRAMS\Murmur\Murmur.lnk" "$INSTDIR\Murmur.exe"
  CreateShortcut "$SMPROGRAMS\Murmur\使用说明.lnk" "$INSTDIR\使用说明.txt"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Murmur" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "DisplayName" "Murmur Windows"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "Publisher" "Murmur contributors"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "DisplayIcon" "$INSTDIR\Murmur.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext current
  retry:
  FindWindow $0 "" "Murmur · Windows"
  ${If} $0 != 0
    MessageBox MB_RETRYCANCEL "请先从托盘退出 Murmur。 / Quit Murmur first." IDRETRY retry IDCANCEL stop
    stop:
    Abort
  ${EndIf}
  Delete "$INSTDIR\Murmur.exe"
  Delete "$INSTDIR\LICENSE.txt"
  Delete "$INSTDIR\使用说明.txt"
  Delete "$INSTDIR\dotnet-notices.txt"
  Delete "$INSTDIR\Uninstall.exe"
  Delete "$SMPROGRAMS\Murmur\Murmur.lnk"
  Delete "$SMPROGRAMS\Murmur\使用说明.lnk"
  RMDir "$SMPROGRAMS\Murmur"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Murmur"
  DeleteRegKey HKCU "Software\Murmur"
  ; Keep %LOCALAPPDATA%\Murmur settings. Never delete user data recursively.
SectionEnd
