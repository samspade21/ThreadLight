#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_PATH="$PROJECT_DIR/build/ThreadLight.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/ThreadLight"

require_app() {
    [[ -x "$EXECUTABLE_PATH" ]] || {
        print -u2 "Build ThreadLight first: ./scripts/build-app.sh --development"
        exit 2
    }
}

activate_app() {
    osascript -e 'tell application "ThreadLight" to activate'
}

window_id() {
    swift -e 'import CoreGraphics; let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []; for row in rows where (row[kCGWindowOwnerName as String] as? String) == "ThreadLight" { if let id = row[kCGWindowNumber as String] { print(id); break } }'
}

case "${1:-}" in
    launch)
        require_app
        pkill -f "$EXECUTABLE_PATH" 2>/dev/null || true
        open -n "$APP_PATH"
        ;;
    launch-demo)
        require_app
        pkill -f "$EXECUTABLE_PATH" 2>/dev/null || true
        open -n "$APP_PATH" --args --threadlight-demo
        ;;
    launch-demo-complete)
        require_app
        pkill -f "$EXECUTABLE_PATH" 2>/dev/null || true
        open -n "$APP_PATH" --args --threadlight-demo-complete
        ;;
    activate)
        activate_app
        ;;
    capture)
        require_app
        name=${2:-threadlight-window.png}
        [[ "$name" == ${name:t} && "$name" == *.png ]] || {
            print -u2 "Capture name must be a PNG filename without directories."
            exit 2
        }
        mkdir -p "$PROJECT_DIR/build/ui-captures"
        activate_app
        sleep 1
        id=$(window_id | tail -1)
        [[ -n "$id" ]] || {
            print -u2 "No visible ThreadLight window found."
            exit 3
        }
        screencapture -x -o -l "$id" "$PROJECT_DIR/build/ui-captures/$name"
        print "$PROJECT_DIR/build/ui-captures/$name"
        ;;
    open-settings)
        activate_app
        osascript -e 'tell application "System Events" to keystroke "," using command down'
        ;;
    open-install-settings)
        activate_app
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button "Install Slack App in Org" of toolbar 1 of window 1'
        ;;
    manifest-link-role)
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to get {role, description, name} of UI element 2 of group 1 of scroll area 1 of group 1 of window 1'
        ;;
    select-hold)
        index=${2:-1}
        [[ "$index" == <-> && "$index" -ge 1 ]] || {
            print -u2 "Hold index must be a positive integer."
            exit 2
        }
        row=$((index + 3))
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to set selected of row $row of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true"
        ;;
    select-result)
        index=${2:-1}
        [[ "$index" == <-> && "$index" -ge 1 ]] || {
            print -u2 "Result index must be a positive integer."
            exit 2
        }
        row=$((index + 1))
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to set selected of row $row of outline 1 of scroll area 3 of group 1 of splitter group 1 of group 1 of window 1 to true"
        ;;
    toggle-result)
        index=${2:-1}
        [[ "$index" == <-> && "$index" -ge 1 ]] || {
            print -u2 "Result index must be a positive integer."
            exit 2
        }
        row=$((index + 1))
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to click button 1 of UI element 1 of row $row of outline 1 of scroll area 3 of group 1 of splitter group 1 of group 1 of window 1"
        ;;
    export-selected)
        activate_app
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "e" using {command down, shift down}'
        ;;
    choose-export-destination)
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button 2 of group 1 of sheet 1 of window 1'
        ;;
    choose-folder)
        folder=${2:-}
        [[ -d "$folder" && "$folder" == "$PROJECT_DIR"/build/ui-smoke-* && "$folder" != *[^A-Za-z0-9._/-]* ]] || {
            print -u2 "Folder must exist under build/ui-smoke-* and contain only safe path characters."
            exit 2
        }
        activate_app
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "g" using {command down, shift down}'
        sleep 1
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to keystroke \"$folder\""
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to key code 36'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button "Export here" of splitter group 1 of window 1'
        ;;
    verify-package)
        activate_app
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "v" using {command down, shift down}'
        ;;
    choose-package)
        package=${2:-}
        [[ -d "$package" && "$package" == "$PROJECT_DIR"/build/ui-smoke-output/*.threadlight-evidence && "$package" != *[^A-Za-z0-9._/-]* ]] || {
            print -u2 "Package must be an existing .threadlight-evidence directory under build/ui-smoke-output."
            exit 2
        }
        activate_app
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "g" using {command down, shift down}'
        sleep 1
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to keystroke \"$package\""
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to key code 36'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button "Verify" of splitter group 1 of window 1'
        ;;
    resize)
        width=${2:-1320}
        height=${3:-820}
        [[ "$width" == <-> && "$width" -ge 1200 && "$width" -le 2000 && "$height" == <-> && "$height" -ge 700 && "$height" -le 1400 ]] || {
            print -u2 "Size must be WIDTH 1200…2000 and HEIGHT 700…1400."
            exit 2
        }
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to set size of window 1 to {$width, $height}"
        ;;
    press-tab)
        count=${2:-1}
        [[ "$count" == <-> && "$count" -ge 1 && "$count" -le 50 ]] || {
            print -u2 "Tab count must be 1…50."
            exit 2
        }
        activate_app
        for _ in {1..$count}; do osascript -e 'tell application "System Events" to tell process "ThreadLight" to key code 48'; done
        ;;
    ax-tree)
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to get entire contents of window 1'
        ;;
    focused)
        osascript "$SCRIPT_DIR/threadlight-ax.applescript" focused
        ;;
    smoke-setup)
        require_app
        stamp=$(date +%Y%m%d-%H%M%S)
        capture_dir="$PROJECT_DIR/build/ui-captures"
        mkdir -p "$capture_dir"

        pkill -f "$EXECUTABLE_PATH" 2>/dev/null || true
        open -n "$APP_PATH" --args --threadlight-demo-complete
        ready=false
        for _ in {1..30}; do
            id=$(window_id | tail -1)
            if [[ -n "$id" ]]; then ready=true; break; fi
            sleep 1
        done
        [[ "$ready" == true ]] || { print -u2 "ThreadLight did not open a window."; exit 3; }
        activate_app
        osascript -e 'tell application "System Events" to keystroke "," using command down'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button "Install Slack App in Org" of toolbar 1 of window 1'

        settings_tree=""
        for _ in {1..10}; do
            settings_tree=$(osascript -e 'tell application "System Events" to tell process "ThreadLight" to get entire contents of window 1' 2>/dev/null || true)
            [[ "$settings_tree" == *"This installation is done once for the organization"* ]] && break
            sleep 1
        done
        [[ "$settings_tree" == *"One-time setup for your Slack organization"* && "$settings_tree" == *"Use ThreadLight's single manifest"* && "$settings_tree" == *"This installation is done once for the organization"* ]] || {
            print -u2 "One-time Slack app setup is missing required guidance."
            exit 4
        }
        id=$(window_id | tail -1)
        [[ -n "$id" ]] || { print -u2 "No visible ThreadLight window found."; exit 5; }
        capture_path="$capture_dir/slack-app-setup-$stamp.png"
        screencapture -x -o -l "$id" "$capture_path"
        print "SLACK_APP_SETUP_VALID"
        print "CAPTURE=$capture_path"
        ;;
    smoke)
        require_app
        stamp=$(date +%Y%m%d-%H%M%S)
        smoke_dir="$PROJECT_DIR/build/ui-smoke-$stamp"
        capture_dir="$PROJECT_DIR/build/ui-captures"
        mkdir -p "$smoke_dir" "$capture_dir"

        pkill -f "$EXECUTABLE_PATH" 2>/dev/null || true
        open -n "$APP_PATH" --args --threadlight-demo-complete
        ready=false
        for _ in {1..30}; do
            tree=$(osascript -e 'tell application "System Events" to tell process "ThreadLight" to get entire contents of window 1' 2>/dev/null || true)
            if [[ "$tree" == *"3 matching messages"* ]]; then ready=true; break; fi
            sleep 1
        done
        [[ "$ready" == true ]] || { print -u2 "ThreadLight demo did not become ready."; exit 3; }

        osascript -e 'tell application "System Events" to tell process "ThreadLight" to set selected of row 2 of outline 1 of scroll area 3 of group 1 of splitter group 1 of group 1 of window 1 to true'
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button 1 of UI element 1 of row 2 of outline 1 of scroll area 3 of group 1 of splitter group 1 of group 1 of window 1'
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "e" using {command down, shift down}'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click checkbox "Include evidence signing" of sheet 1 of window 1'
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button 2 of group 1 of sheet 1 of window 1'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "g" using {command down, shift down}'
        sleep 1
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to keystroke \"$smoke_dir\""
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to key code 36'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button "Export here" of splitter group 1 of window 1'

        package=""
        for _ in {1..30}; do
            packages=("$smoke_dir"/*.threadlight-evidence(N))
            if (( ${#packages} == 1 )); then package=${packages[1]}; break; fi
            sleep 1
        done
        [[ -n "$package" && -f "$package/evidence.json" && -f "$package/evidence.pdf" && -d "$package/resources" ]] || {
            print -u2 "ThreadLight did not create a complete evidence package."
            exit 4
        }
        "$PROJECT_DIR/scripts/verify-evidence.sh" "$package"

        osascript -e 'tell application "ThreadLight" to activate'
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "v" using {command down, shift down}'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to keystroke "g" using {command down, shift down}'
        sleep 1
        osascript -e "tell application \"System Events\" to tell process \"ThreadLight\" to keystroke \"$package\""
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to key code 36'
        sleep 1
        osascript -e 'tell application "System Events" to tell process "ThreadLight" to click button "Verify" of splitter group 1 of window 1'

        verified=false
        for _ in {1..20}; do
            tree=$(osascript -e 'tell application "System Events" to tell process "ThreadLight" to get entire contents of window 1' 2>/dev/null || true)
            if [[ "$tree" == *"Verified internally. Compare signer key"* ]]; then verified=true; break; fi
            sleep 1
        done
        [[ "$verified" == true ]] || { print -u2 "ThreadLight did not report in-app verification success."; exit 5; }

        id=$(window_id | tail -1)
        [[ -n "$id" ]] || { print -u2 "No visible ThreadLight window found."; exit 6; }
        capture_path="$capture_dir/ui-smoke-$stamp.png"
        screencapture -x -o -l "$id" "$capture_path"
        print "UI_SMOKE_VALID"
        print "PACKAGE=$package"
        print "CAPTURE=$capture_path"
        ;;
    *)
        print -u2 "Usage: $0 {launch|launch-demo|launch-demo-complete|activate|capture NAME.png|open-settings|open-install-settings|manifest-link-role|select-hold INDEX|select-result INDEX|toggle-result INDEX|export-selected|choose-export-destination|choose-folder PATH|verify-package|choose-package PATH|resize WIDTH HEIGHT|press-tab COUNT|ax-tree|focused|smoke-setup|smoke}"
        exit 64
        ;;
esac
