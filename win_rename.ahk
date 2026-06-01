#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

;==============================================================================
; win_rename  —  Explorer/Desktop batch prefix/suffix renamer
;------------------------------------------------------------------------------
; Select files/folders in File Explorer (or on the Desktop) and press Alt+F2.
; A small dialog lets you type a PREFIX and a SUFFIX with a live preview, then
; renames every selected item — keeping the original name, adding the prefix to
; the front and the suffix BEFORE the extension.
;
;   report.pdf  --(prefix "2024_", suffix "_final")-->  2024_report_final.pdf
;
; AutoHotkey v2 only.  Run NON-elevated (see notes at bottom of file).
;==============================================================================


;------------------------- startup / tray (auto-execute) ----------------------

; Startup runs only when this file is the MAIN script — skipped when the file is
; #Include'd elsewhere (e.g. from the test harness) so the functions stay reusable.
if (A_LineFile = A_ScriptFullPath) {
    ; Hotkey is live only when an Explorer window or the Desktop is the active
    ; window.  A window GROUP keeps the #HotIf fast-path optimizer happy (a single
    ; WinActive call), unlike an `or` of several WinActive calls.
    GroupAdd "ExplorerOrDesktop", "ahk_class CabinetWClass"   ; File Explorer (incl. Win11 tabs)
    GroupAdd "ExplorerOrDesktop", "ahk_class WorkerW"         ; Desktop (active layer)
    GroupAdd "ExplorerOrDesktop", "ahk_class Progman"         ; Desktop (fallback)

    A_IconTip := "win_rename  —  select files in Explorer, then press Alt+F2"
    try TraySetIcon "shell32.dll", 280                        ; a rename-ish icon (best effort)

    A_TrayMenu.Add()
    A_TrayMenu.Add("Add to Startup", InstallStartup)
    A_TrayMenu.Add("Remove from Startup", UninstallStartup)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add("Exit", (*) => ExitApp())

    TrayTip "Select files in Explorer and press Alt+F2.", "win_rename is running"
}


;-------------------------------- hotkey --------------------------------------

#HotIf WinActive("ahk_group ExplorerOrDesktop")
!F2::ShowRenameDialog()                                   ; Alt+F2  ( ! = Alt )
#HotIf


;========================= selected-item enumeration ==========================
; Returns an Array of full filesystem paths currently SELECTED in the ACTIVE
; Explorer window/tab (or on the Desktop).  Handles Windows 11 tabbed Explorer
; by matching the ACTIVE tab, not just the frame HWND.
GetSelectedPaths() {
    paths := []
    hwnd := WinExist("A")
    if !hwnd
        return paths
    cls := WinGetClass("ahk_id " hwnd)
    shell := ComObject("Shell.Application")

    ; ---- Desktop (Progman / WorkerW) ----
    if (cls = "Progman" || cls = "WorkerW") {
        SWC_DESKTOP := 8, SWFO_NEEDDISPATCH := 1
        try {
            desktop := shell.Windows.FindWindowSW(0, 0, SWC_DESKTOP, 0, SWFO_NEEDDISPATCH)
            for item in desktop.Document.SelectedItems()
                if (item.Path != "")
                    paths.Push(item.Path)
        }
        return paths
    }

    ; ---- File Explorer (CabinetWClass) ----
    if (cls != "CabinetWClass")
        return paths

    ; The ACTIVE tab is hosted by ShellTabWindowClass1 (always top of z-order).
    activeTab := 0
    try activeTab := ControlGetHwnd("ShellTabWindowClass1", "ahk_id " hwnd)

    SID_STopLevelBrowser := "{4C96BE40-915C-11CF-99D3-00AA004AE837}"
    IID_IShellBrowser    := "{000214E2-0000-0000-C000-000000000046}"

    target := ""
    for window in shell.Windows {
        try {
            if (window.HWND != hwnd)                ; same Explorer FRAME?
                continue
            if (activeTab) {                        ; disambiguate which TAB this is
                sb := ComObjQuery(window, SID_STopLevelBrowser, IID_IShellBrowser)
                ComCall(3, sb, "ptr*", &thisTab := 0)   ; IShellBrowser::GetWindow (slot 3)
                if (thisTab != activeTab)
                    continue                        ; not the active tab -> skip
            }
            target := window
            break
        }
    }
    if !target
        return paths

    try {
        for item in target.Document.SelectedItems()
            if (item.Path != "")                    ; skip virtual / namespace items
                paths.Push(item.Path)
    }
    return paths
}


;============================ name transform ==================================
; New BASE name (no directory).  Suffix goes before the extension.
BuildNewName(path, prefix, suffix) {
    SplitPath(path, &name, &dir, &ext, &nameNoExt)
    isFolder := InStr(FileExist(path), "D") ? true : false

    if (isFolder || ext = "")                       ; folder or extension-less file
        return prefix . name . suffix
    if (nameNoExt = "" && SubStr(name, 1, 1) = ".")  ; dotfile (.gitignore): whole name = "extension"
        return prefix . suffix . name
    return prefix . nameNoExt . suffix . "." . ext  ; normal: suffix before extension
}

BuildNewPath(path, prefix, suffix) {
    SplitPath(path, &name, &dir)
    return dir "\" BuildNewName(path, prefix, suffix)
}


;============================ validation ======================================
; Characters illegal in Windows filenames (also blocks FileMove '*'/'?' wildcards).
ValidateAffix(prefix, suffix) {
    if (prefix = "" && suffix = "")
        return "Enter a prefix or a suffix."
    if RegExMatch(prefix suffix, "[\\/:*?`"<>|]")
        return "Illegal characters not allowed:  \ / : * ? `" < > |"
    return ""
}

; Per-result name checks (reserved device names, trailing space/dot).
ValidateResultName(name) {
    if (name = "")
        return "resulting name is empty"
    last := SubStr(name, -1)
    if (last = " " || last = ".")
        return "name ends with a space or period"
    base := name
    if (dotPos := InStr(name, "."))
        base := SubStr(name, 1, dotPos - 1)
    static reserved := "CON,PRN,AUX,NUL,COM1,COM2,COM3,COM4,COM5,COM6,COM7,COM8,COM9,LPT1,LPT2,LPT3,LPT4,LPT5,LPT6,LPT7,LPT8,LPT9"
    for r in StrSplit(reserved, ",")
        if (StrUpper(base) = r)
            return "reserved device name not allowed: " base
    return ""
}


;============================ rename engine ===================================
DoRename(paths, prefix, suffix) {
    plan         := []          ; [{src, dst, isDir, caseOnly}]
    skipped      := []          ; [{src, reason}]
    targetsLower := Map()       ; lower(dst) -> src   (duplicate-target detection)
    sourcesLower := Map()       ; lower(src) -> true  (cycle detection)

    for src in paths
        sourcesLower[StrLower(src)] := true

    ; ---- pre-scan: build plan, detect collisions ----
    for src in paths {
        if !FileExist(src) {
            skipped.Push({src: src, reason: "source not found"})
            continue
        }
        isDir   := InStr(FileExist(src), "D") ? true : false
        newName := BuildNewName(src, prefix, suffix)

        if (rsn := ValidateResultName(newName)) {
            skipped.Push({src: src, reason: rsn})
            continue
        }

        dst    := BuildNewPath(src, prefix, suffix)
        keyDst := StrLower(dst), keySrc := StrLower(src)

        if (dst = src) {
            skipped.Push({src: src, reason: "no change"})
            continue
        }
        if (targetsLower.Has(keyDst)) {
            skipped.Push({src: src, reason: "duplicate target with " FileName(targetsLower[keyDst])})
            continue
        }
        if (FileExist(dst) && keyDst != keySrc) {       ; target on disk, not itself
            skipped.Push({src: src, reason: "a file with that name already exists"})
            continue
        }

        targetsLower[keyDst] := src
        plan.Push({src: src, dst: dst, isDir: isDir, caseOnly: (keyDst = keySrc)})
    }

    ; ---- detect cyclic collisions (a target equals another source in the batch) ----
    needTemp := false
    for item in plan {
        if (sourcesLower.Has(StrLower(item.dst)) && StrLower(item.dst) != StrLower(item.src)) {
            needTemp := true
            break
        }
    }

    done := 0, failed := []     ; failed: [{src, reason}]

    if (needTemp) {
        ; ---- two-pass through temp names: src -> temp, then temp -> dst ----
        staged := []
        for i, item in plan {
            try {
                tmp := MakeTempPath(PathDir(item.src), i)
                RenameRaw(item.src, tmp, item.isDir)
                staged.Push({tmp: tmp, dst: item.dst, isDir: item.isDir, src: item.src})
            } catch as e {
                failed.Push({src: item.src, reason: ErrText(e)})
            }
        }
        for s in staged {
            try {
                RenameRaw(s.tmp, s.dst, s.isDir)
                done++
            } catch as e {
                try RenameRaw(s.tmp, s.src, s.isDir)     ; best-effort restore
                failed.Push({src: s.src, reason: ErrText(e)})
            }
        }
    } else {
        ; ---- direct rename per item; case-only renames go via a temp step ----
        for i, item in plan {
            try {
                if (item.caseOnly) {
                    tmp := MakeTempPath(PathDir(item.src), i)
                    RenameRaw(item.src, tmp, item.isDir)
                    RenameRaw(tmp, item.dst, item.isDir)
                } else {
                    RenameRaw(item.src, item.dst, item.isDir)
                }
                done++
            } catch as e {
                failed.Push({src: item.src, reason: ErrText(e)})
            }
        }
    }

    return {done: done, skipped: skipped, failed: failed}
}

RenameRaw(src, dst, isDir) {
    if (isDir)
        DirMove(src, dst, "R")          ; rename folder in place (same volume); throws on failure
    else
        FileMove(src, dst, 0)           ; rename file, never overwrite; throws on failure
}

MakeTempPath(dir, seed) {
    loop {
        cand := dir "\~winrename_" A_TickCount "_" seed "_" A_Index ".tmp"
        if !FileExist(cand)
            return cand
    }
}

PathDir(path) {
    SplitPath(path, &name, &dir)
    return dir
}

FileName(path) {
    SplitPath(path, &name)
    return name
}

ErrText(e) {
    msg := (e is Error) ? e.Message : String(e)
    return Trim(StrReplace(msg, "`n", " ")) " (err " A_LastError ")"
}

ShowResult(res) {
    msg := res.done " item(s) renamed."
    msg .= ListSection(res.skipped, "Skipped")
    msg .= ListSection(res.failed,  "Failed")
    icon := (res.skipped.Length || res.failed.Length) ? "Icon!" : "Iconi"
    MsgBox msg, "win_rename — Result", icon
}

ListSection(items, label) {
    if !items.Length
        return ""
    s := "`n`n" label " (" items.Length "):"
    shown := 0
    for it in items {
        if (shown >= 15) {
            s .= "`n  … and " (items.Length - shown) " more"
            break
        }
        s .= "`n  • " FileName(it.src) "  →  " it.reason
        shown++
    }
    return s
}


;================================ dialog ======================================
ShowRenameDialog(paths := "") {
    if (!IsObject(paths))               ; hotkey calls with no arg -> read the live selection
        paths := GetSelectedPaths()
    if (!paths.Length) {
        MsgBox "No files or folders are selected.`nSelect items in Explorer, then press Alt+F2.", "win_rename", "Icon!"
        return
    }

    g := Gui("+AlwaysOnTop +OwnDialogs", "win_rename — " paths.Length " selected")
    g.SetFont "s10", "Segoe UI"
    g.MarginX := 12, g.MarginY := 10

    g.AddText "xm", "Prefix:"
    ePrefix := g.AddEdit("xm w320")
    g.AddText "xm", "Suffix (before extension):"
    eSuffix := g.AddEdit("xm w320")

    lv := g.AddListView("xm w560 r14 Grid -Multi", ["Original name", "New name"])

    status := g.AddText("xm w560", "")

    btnApply  := g.AddButton("xm w130 Default", "Apply")
    btnCancel := g.AddButton("x+12 w130", "Cancel")

    UpdatePreview(*) {
        prefix := ePrefix.Value, suffix := eSuffix.Value
        lv.Opt("-Redraw")
        lv.Delete()
        for src in paths
            lv.Add(, FileName(src), BuildNewName(src, prefix, suffix))
        lv.Opt("+Redraw")
        lv.ModifyCol()                  ; auto-fit columns to contents

        err := ValidateAffix(prefix, suffix)
        if (err = "") {
            status.Text := "✓ Ready — " paths.Length " item(s) will be renamed."
            btnApply.Enabled := true
        } else {
            status.Text := "⚠ " err
            btnApply.Enabled := false
        }
    }

    ApplyNow(*) {
        prefix := ePrefix.Value, suffix := eSuffix.Value
        if (ValidateAffix(prefix, suffix) != "")
            return
        g.Destroy()
        ShowResult(DoRename(paths, prefix, suffix))
    }

    ePrefix.OnEvent "Change", UpdatePreview
    eSuffix.OnEvent "Change", UpdatePreview
    btnApply.OnEvent "Click", ApplyNow
    btnCancel.OnEvent "Click", (*) => g.Destroy()
    g.OnEvent "Escape", (*) => g.Destroy()
    g.OnEvent "Close",  (*) => g.Destroy()

    UpdatePreview()                     ; initial fill (Apply starts disabled)
    g.Show "AutoSize Center"
    ePrefix.Focus()
}


;============================ startup install ==================================
StartupLinkPath() => A_Startup "\win_rename.lnk"

InstallStartup(*) {
    try {
        FileCreateShortcut A_ScriptFullPath, StartupLinkPath(), A_ScriptDir, , "win_rename file renamer"
        MsgBox "Added to Windows startup.`n" StartupLinkPath(), "win_rename", "Iconi"
    } catch as e {
        MsgBox "Failed to add to startup: " e.Message, "win_rename", "Icon!"
    }
}

UninstallStartup(*) {
    try {
        if FileExist(StartupLinkPath()) {
            FileDelete StartupLinkPath()
            MsgBox "Removed from startup.", "win_rename", "Iconi"
        } else {
            MsgBox "Not registered in startup.", "win_rename", "Iconi"
        }
    } catch as e {
        MsgBox "Failed to remove from startup: " e.Message, "win_rename", "Icon!"
    }
}

;------------------------------------------------------------------------------
; NOTE: Run NON-elevated.  If this script is elevated (admin) while Explorer is
; not, UAC/UIPI isolation hides the user's Explorer windows and the selection
; comes back empty.  Renames in protected paths (Program Files, Windows, …)
; surface as per-file "Access Denied" errors in the result summary.
;------------------------------------------------------------------------------
