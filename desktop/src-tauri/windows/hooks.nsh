!macro NSIS_HOOK_PREINSTALL
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "CurrentBuildNumber"
  ${If} $0 == ""
    MessageBox MB_ICONSTOP "ArtShot X Preview requires Windows 11 or later."
    Abort
  ${EndIf}
  IntCmp $0 22000 artshot_windows_supported artshot_windows_unsupported artshot_windows_supported
  artshot_windows_unsupported:
    MessageBox MB_ICONSTOP "ArtShot X Preview requires Windows 11 (build 22000) or later."
    Abort
  artshot_windows_supported:
!macroend
