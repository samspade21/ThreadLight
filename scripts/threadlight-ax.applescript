on run arguments
    tell application "System Events"
        tell process "ThreadLight"
            set focusedElement to value of attribute "AXFocusedUIElement"
            return {role of focusedElement, name of focusedElement, description of focusedElement}
        end tell
    end tell
end run
