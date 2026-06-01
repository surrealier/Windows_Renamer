#Requires AutoHotkey v2.0
#SingleInstance Off
;==============================================================================
; Automated tests for win_rename's pure logic + rename engine.
; Run:  AutoHotkey64.exe test_win_rename.ahk
; Writes a PASS/FAIL report to  %TEMP%\win_rename_test_result.txt  (and stdout).
;
; Note: win_rename.ahk is #Include'd at the BOTTOM and its logic runs via Main()
; at the top, so the included Alt+F2 hotkey definition never cuts off our
; auto-execute section.  ExitApp() ends the run cleanly.
;==============================================================================

Main()

Main() {
    global RES, PASS, FAIL
    RES := ""
    PASS := 0
    FAIL := 0

  try {
    T := A_Temp "\win_rename_test_" A_TickCount
    DirCreate T

    ; ---- 1) BuildNewName transform (prefix "2024_", suffix "_final") ----
    fPdf   := Mk(T, "report.pdf")
    fXls   := Mk(T, "data.xlsx")
    fNoExt := Mk(T, "README")
    fDot   := Mk(T, ".gitignore")
    dSub   := T "\sub"
    DirCreate dSub

    Assert("transform: normal file (suffix before ext)", BuildNewName(fPdf, "2024_", "_final"), "2024_report_final.pdf")
    Assert("transform: another extension",                 BuildNewName(fXls, "2024_", "_final"), "2024_data_final.xlsx")
    Assert("transform: no-extension file",                 BuildNewName(fNoExt, "2024_", "_final"), "2024_README_final")
    Assert("transform: dotfile (.gitignore)",              BuildNewName(fDot, "2024_", "_final"), "2024__final.gitignore")
    Assert("transform: folder",                            BuildNewName(dSub, "2024_", "_final"), "2024_sub_final")
    Assert("transform: prefix only",                       BuildNewName(fPdf, "img_", ""), "img_report.pdf")
    Assert("transform: suffix only",                      BuildNewName(fPdf, "", "_v2"), "report_v2.pdf")

    ; ---- 2) ValidateAffix (illegal chars / empty) ----
    AssertTrue("validate: both empty -> rejected",   ValidateAffix("", "") != "")
    AssertTrue("validate: colon -> rejected",        ValidateAffix("a:b", "") != "")
    AssertTrue("validate: asterisk -> rejected",     ValidateAffix("", "x*") != "")
    AssertTrue("validate: backslash -> rejected",    ValidateAffix("a\b", "") != "")
    AssertTrue("validate: quote -> rejected",        ValidateAffix("a`"b", "") != "")
    Assert("validate: clean affixes -> ok",      ValidateAffix("good_", "_ok"), "")

    ; ---- 3) ValidateResultName (reserved / trailing) ----
    AssertTrue("resultname: reserved CON -> rejected",   ValidateResultName("CON.txt") != "")
    AssertTrue("resultname: reserved nul -> rejected",   ValidateResultName("nul") != "")
    AssertTrue("resultname: trailing dot -> rejected",   ValidateResultName("name.") != "")
    AssertTrue("resultname: trailing space -> rejected", ValidateResultName("name ") != "")
    Assert("resultname: normal -> ok",               ValidateResultName("2024_report_final.pdf"), "")

    ; ---- 4) DoRename: real batch rename on disk ----
    dr := DoRename([fPdf, fXls, fNoExt], "2024_", "_final")
    Assert("dorename: 3 renamed",           dr.done, 3)
    AssertTrue("dorename: no skips",            dr.skipped.Length = 0)
    AssertTrue("dorename: no failures",         dr.failed.Length = 0)
    AssertTrue("dorename: new report exists",   FileExist(T "\2024_report_final.pdf") != "")
    AssertTrue("dorename: new data exists",     FileExist(T "\2024_data_final.xlsx") != "")
    AssertTrue("dorename: new README exists",   FileExist(T "\2024_README_final") != "")
    AssertTrue("dorename: old report gone",     FileExist(fPdf) = "")

    ; ---- 5) DoRename: collision with a pre-existing target is skipped (not clobbered) ----
    src      := Mk(T, "alpha.txt")
    existing := Mk(T, "p_alpha.txt")        ; target name already on disk
    FileAppend "ORIGINAL", existing         ; marker to prove it is not overwritten
    dr2 := DoRename([src], "p_", "")
    AssertTrue("collision: nothing renamed",        dr2.done = 0)
    AssertTrue("collision: one skipped",            dr2.skipped.Length = 1)
    AssertTrue("collision: source still there",     FileExist(src) != "")
    AssertTrue("collision: existing target intact", InStr(FileRead(existing), "ORIGINAL") > 0)

    ; ---- 6) DoRename: per-file failure does not abort the batch ----
    okFile     := Mk(T, "keep.dat")
    lockedFile := Mk(T, "locked.dat")
    fh := FileOpen(lockedFile, "r-wd")      ; deny write+delete -> forces a rename failure
    dr3 := DoRename([lockedFile, okFile], "x_", "")
    fh.Close()
    AssertTrue("partial-fail: ok file still renamed",  FileExist(T "\x_keep.dat") != "")
    AssertTrue("partial-fail: locked file not renamed", FileExist(lockedFile) != "")
    AssertTrue("partial-fail: failure recorded",       dr3.failed.Length >= 1)

    ; ---- 7) counter (auto-increment number before the extension) ----
    Assert("number: appended after suffix",  BuildNewName("C:\x\file.png", "", "_", "00001"), "file_00001.png")
    Assert("number: no suffix text",         BuildNewName("C:\x\photo.jpg", "", "", "042"), "photo042.jpg")
    Assert("number: with prefix and suffix", BuildNewName("C:\x\a.txt", "p_", "_s", "007"), "p_a_s007.txt")
    Assert("number: format 5-digit",         NumStrFor({digits:5, start:1}, 1), "00001")
    Assert("number: start offset",           NumStrFor({digits:3, start:10}, 5), "014")
    Assert("number: opts empty -> no str",   NumStrFor("", 3), "")
    ndp1 := Mk(T, "shot1.png")
    ndp2 := Mk(T, "shot2.png")
    ndr := DoRename([ndp1, ndp2], "", "_", {digits:4, start:1})
    AssertTrue("dorename+num: 2 renamed",       ndr.done = 2)
    AssertTrue("dorename+num: shot1 -> _0001",  FileExist(T "\shot1_0001.png") != "")
    AssertTrue("dorename+num: shot2 -> _0002",  FileExist(T "\shot2_0002.png") != "")

  } catch as e {
        RES := RES . "`n!!! EXCEPTION: " . e.Message
        RES := RES . "`n    What: " . (e.HasProp("What") ? e.What : "?")
        RES := RES . "`n    Line: " . (e.HasProp("Line") ? e.Line : "?")
        RES := RES . "`n    Stack:`n" . (e.HasProp("Stack") ? e.Stack : "?") . "`n"
        FAIL := FAIL + 1
  }

    ; ---- cleanup + report ----
    try DirDelete T, true

    summary := "==== win_rename tests ====`n" RES "`n" PASS " passed, " FAIL " failed`n"
    out := A_Temp "\win_rename_test_result.txt"
    try FileDelete out
    FileAppend summary, out
    try FileAppend summary, "*"             ; also to stdout if a console is attached
    ExitApp(FAIL = 0 ? 0 : 1)
}

Assert(name, got, want) {
    global RES, PASS, FAIL
    nm := Str(name), g := Str(got), w := Str(want)
    if (g == w) {
        RES := RES . "PASS  " . nm . "`n"
        PASS := PASS + 1
    } else {
        RES := RES . "FAIL  " . nm . "`n        got =[" . g . "]`n        want=[" . w . "]`n"
        FAIL := FAIL + 1
    }
}

AssertTrue(name, cond) => Assert(name, cond ? "true" : "false", "true")

Str(v) {
    if IsObject(v)
        return "<object:" Type(v) ">"
    return v ""
}

Mk(dir, rel) {
    p := dir "\" rel
    FileAppend "x", p
    return p
}

#Include win_rename.ahk
