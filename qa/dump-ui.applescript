property outputLines : {}

on appendLine(valueText)
    global outputLines
    copy valueText to end of outputLines
end appendLine

on run argv
    global outputLines
    set outputLines to {}
    set outPath to item 1 of argv
    my appendLine("# QuotaMonitor AX snapshot")

    tell application "System Events"
        tell application process "QuotaMonitor"
            set frontmostText to "unknown"
            try
                set frontmostText to ((frontmost as boolean) as text)
            end try
            my appendLine("frontmost=" & frontmostText)

            repeat with w in windows
                my appendLine("window title=" & (name of w as text))
                my appendLine("  role=" & (role of w as text))
                my appendLine("  subrole=" & (subrole of w as text))
                set childCount to count of UI elements of w
                my appendLine("  children=" & (childCount as text))
                repeat with i from 1 to childCount
                    set childElement to UI element i of w
                    set childName to ""
                    try
                        set childName to name of childElement as text
                    end try
                    my appendLine("    " & (role of childElement as text) & " " & childName)
                end repeat
            end repeat
        end tell
    end tell

    set text item delimiters to linefeed
    set body to outputLines as text
    set text item delimiters to ""
    set outFile to open for access POSIX file outPath with write permission
    try
        set eof of outFile to 0
        write body to outFile as «class utf8»
        close access outFile
    on error errMsg number errNo
        close access outFile
        error errMsg number errNo
    end try
end run
