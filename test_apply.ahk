#Requires AutoHotkey v2.0
#SingleInstance Off
; GUI integration test: drives the real dialog + Apply button and verifies an on-disk
; rename happens (guards the "control is destroyed" bug where ApplyNow read a control
; after g.Destroy()).  Writes %TEMP%\wr_apply.txt.
SetTitleMatchMode 2
ApplyTest()
ApplyTest() {
    out := A_Temp "\wr_apply.txt"
    try FileDelete out
    log := ""
    try {
        T := A_Temp "\wrapply" A_TickCount
        DirCreate T
        f1 := T "\one.txt", f2 := T "\two.txt"
        FileAppend "a", f1
        FileAppend "b", f2
        ShowRenameDialog([f1, f2])
        if !WinWait("win_rename", , 5) {
            log .= "FAIL: dialog did not open`n"
        } else {
            Sleep 400
            ControlSend "TEST_", "Edit1", "win_rename"    ; prefix field
            Sleep 250
            SetTimer(CloseResultBox, 100)                 ; auto-dismiss the result MsgBox
            ControlClick "Apply", "win_rename"            ; the Apply button (by caption, robust to control order)
            Sleep 1200
            SetTimer(CloseResultBox, 0)
            r1 := (FileExist(T "\TEST_one.txt") != "")
            r2 := (FileExist(T "\TEST_two.txt") != "")
            gone := (FileExist(f1) = "" && FileExist(f2) = "")
            log .= "TEST_one.txt exists : " r1 "`n"
            log .= "TEST_two.txt exists : " r2 "`n"
            log .= "originals gone      : " gone "`n"
            log .= (r1 && r2 && gone ? "APPLY OK`n" : "APPLY FAILED`n")
        }
        try DirDelete T, true
    } catch as e {
        log .= "EXC: " e.Message "`n"
    }
    FileAppend log, out
    ExitApp
}
CloseResultBox() {
    if WinExist("win_rename ahk_class #32770")   ; result MsgBox (not the Gui dialog)
        WinClose
}
#Include win_rename.ahk
