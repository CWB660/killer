#!/bin/bash

################################################################################
# Shell Executor Tool
# Executes shell commands and returns output
################################################################################

TOOL_NAME="shell_executor"
TOOL_DESCRIPTION="Execute shell commands in a safe environment with destructive command confirmation"

# Colors for output
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

get_definition() {
    cat << 'EOF'
{
    "type": "function",
    "function": {
        "name": "shell_executor",
        "description": "Execute shell commands and return their output. Use this to run system commands, scripts, or perform file operations. For commands requiring sudo, the tool will automatically request authentication if needed. IMPORTANT: Destructive commands (rm, rmdir, unlink, shred, etc.) will require user confirmation before execution. WARNING: Avoid commands that produce massive output or run for extended periods as they can overflow the context window. Instead, use strategies like: 1) Pipe to 'head -n N' or 'tail -n N' to limit output lines; 2) Use 'wc -l' or 'wc -c' to count instead of displaying full content; 3) Filter with 'grep' to show only relevant lines; 4) For large files, read specific sections with 'sed -n START,ENDp'; 5) Add timeout or background execution for long-running commands. Always prefer targeted, incremental queries over bulk operations.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute"
                },
                "working_directory": {
                    "type": "string",
                    "description": "Working directory for command execution (optional)",
                    "default": "."
                },
                "request_sudo": {
                    "type": "boolean",
                    "description": "Set to true if the command requires sudo privileges. The tool will request authentication interactively before execution (optional)",
                    "default": false
                },
                "user_confirmed": {
                    "type": "boolean",
                    "description": "SECURITY PARAMETER - DO NOT set this to true unless a system message explicitly instructs you to do so after user approval. This parameter bypasses destructive command confirmation and should ONLY be used when retrying a previously blocked command after the user has confirmed the operation (optional, default: false)",
                    "default": false
                }
            },
            "required": ["command"]
        }
    }
}
EOF
}

# Check if command contains destructive operations
is_destructive_command() {
    local cmd="$1"
    
    # List of destructive command patterns
    local destructive_patterns=(
        '\brm\b'
        '\brmdir\b'
        '\bunlink\b'
        '\bshred\b'
        '\bdd\b.*of='
        '\bmkfs\b'
        '\bfdisk\b'
        '\bparted\b'
        '>\s*/dev/'
        '\btruncate\b.*-s\s*0'
    )
    
    # Check each pattern
    for pattern in "${destructive_patterns[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            return 0  # Is destructive
        fi
    done
    
    return 1  # Not destructive
}

# Report that destructive command needs confirmation
report_needs_confirmation() {
    local command="$1"
    
    echo -e "${YELLOW}[WARNING]${NC} Destructive command detected!" >&2
    echo -e "Command: ${YELLOW}$command${NC}" >&2
    echo -e "This command requires user confirmation before execution." >&2
    echo -e "${YELLOW}[CANCELLED]${NC} Command execution cancelled - awaiting user confirmation." >&2
}

get_environment() {
    local working_dir="${1:-.}"
    
    # Validate working directory
    if [ ! -d "$working_dir" ]; then
        cat << EOF
{
    "success": false,
    "error": "Invalid working directory: $working_dir"
}
EOF
        return 1
    fi
    
    # Get current directory absolute path
    local abs_path=$(cd "$working_dir" && pwd)
    
    # Get directory listing (current level only, max 1000 items)
    local files_json="[]"
    local dirs_json="[]"
    local file_count=0
    local dir_count=0
    local total_count=0
    
    # Arrays to store items
    local -a file_list
    local -a dir_list
    
    # Read directory contents
    while IFS= read -r item; do
        if [ $total_count -ge 1000 ]; then
            break
        fi
        
        local full_path="$working_dir/$item"
        if [ -d "$full_path" ]; then
            dir_list+=("$item")
            ((dir_count++))
        elif [ -f "$full_path" ]; then
            file_list+=("$item")
            ((file_count++))
        fi
        ((total_count++))
    done < <(ls -A "$working_dir" 2>/dev/null)
    
    # Convert arrays to JSON
    if [ ${#file_list[@]} -gt 0 ]; then
        files_json=$(printf '%s\n' "${file_list[@]}" | jq -R . | jq -s .)
    fi
    
    if [ ${#dir_list[@]} -gt 0 ]; then
        dirs_json=$(printf '%s\n' "${dir_list[@]}" | jq -R . | jq -s .)
    fi
    
    # Return environment info
    cat << EOF
{
    "success": true,
    "current_directory": "$abs_path",
    "file_count": $file_count,
    "directory_count": $dir_count,
    "total_count": $total_count,
    "files": $files_json,
    "directories": $dirs_json,
    "truncated": $([ $total_count -ge 1000 ] && echo "true" || echo "false")
}
EOF
}

execute() {
    local args="$1"
    local command=$(echo "$args" | jq -r '.command')
    local working_dir=$(echo "$args" | jq -r '.working_directory // "."')
    local request_sudo=$(echo "$args" | jq -r '.request_sudo // false')
    local user_confirmed=$(echo "$args" | jq -r '.user_confirmed // false')
    
    # Security: Validate working directory
    if [ ! -d "$working_dir" ]; then
        cat << EOF
{
    "success": false,
    "error": "Invalid working directory: $working_dir"
}
EOF
        return 1
    fi
    
    # Check for destructive commands and report need for confirmation
    if is_destructive_command "$command"; then
        # Only proceed if user_confirmed parameter is explicitly set to true
        if [ "$user_confirmed" != "true" ]; then
            report_needs_confirmation "$command"
            cat << EOF
{
    "success": false,
    "error": "Destructive command detected. User confirmation required before execution. DO NOT retry with 'user_confirmed: true' until you receive explicit instruction from a system message.",
    "command": $(echo "$command" | jq -Rs .),
    "cancelled": true,
    "reason": "destructive_command_not_confirmed"
}
EOF
            return 1
        else
            log_info "Destructive command confirmed by user, proceeding..."
        fi
    fi
    
    # Handle sudo commands
    if [[ "$command" =~ ^[[:space:]]*sudo ]] || [ "$request_sudo" = "true" ]; then
        # Check if sudo is available without password (cached or NOPASSWD)
        if ! sudo -n true 2>/dev/null; then
            # Sudo requires password - try to request it interactively
            echo -e "${YELLOW}[SUDO]${NC} Command requires sudo privileges. Requesting authentication..." >&2
            
            # Try to get sudo access interactively
            if ! sudo -v; then
                cat << EOF
{
    "success": false,
    "error": "Sudo authentication failed or cancelled. Please run 'sudo -v' manually first, or configure NOPASSWD in sudoers for this command.",
    "command": $(echo "$command" | jq -Rs .),
    "sudo_required": true
}
EOF
                return 1
            fi
            echo -e "${GREEN}[SUDO]${NC} Authentication successful" >&2
        fi
    fi
    
    # Create temp files for output capture
    local temp_output=$(mktemp)
    local temp_status=$(mktemp)
    
    # Cleanup function for temp files
    cleanup_execution() {
        # Kill the entire process group if it still exists
        if [ -n "$cmd_pid" ]; then
            kill -TERM -$cmd_pid 2>/dev/null || true
            # Give it a moment to terminate gracefully
            sleep 0.2
            # Force kill if still running
            kill -KILL -$cmd_pid 2>/dev/null || true
        fi
        rm -f "$temp_output" "$temp_status" 2>/dev/null || true
    }
    
    # Set up trap for cleanup on script interruption
    trap cleanup_execution EXIT INT TERM
    
    # Execute command in background with its own process group
    # This allows us to kill the entire process tree
    (
        cd "$working_dir" || exit 1
        # Start a new process group
        set -m
        # For sudo commands, add timeout to prevent hanging
        if [[ "$command" =~ ^[[:space:]]*sudo ]]; then
            # Use timeout command if available, fallback to direct execution
            if command -v timeout &> /dev/null; then
                timeout 300 bash -c "$command"
            else
                eval "$command"
            fi
        else
            eval "$command"
        fi
        echo $? > "$temp_status"
    ) > "$temp_output" 2>&1 &
    
    # Save the PID
    local cmd_pid=$!
    
    # Wait for command to complete with timeout (5 minutes max)
    local timeout_counter=0
    while kill -0 $cmd_pid 2>/dev/null; do
        sleep 1
        ((timeout_counter++))
        if [ $timeout_counter -ge 300 ]; then
            log_warn "Command timeout after 300 seconds, terminating..."
            kill -TERM -$cmd_pid 2>/dev/null || true
            sleep 1
            kill -KILL -$cmd_pid 2>/dev/null || true
            echo "124" > "$temp_status"  # Timeout exit code
            break
        fi
    done
    
    wait $cmd_pid 2>/dev/null
    local wait_status=$?
    
    # Read exit code from temp file if available
    local exit_code=$wait_status
    if [ -f "$temp_status" ] && [ -s "$temp_status" ]; then
        exit_code=$(cat "$temp_status")
    fi
    
    # Read output
    local output=""
    if [ -f "$temp_output" ]; then
        output=$(cat "$temp_output")
    fi
    
    # Clean up temp files
    rm -f "$temp_output" "$temp_status"
    
    # Remove trap
    trap - EXIT INT TERM
    
    # Escape output for JSON
    local escaped_output=$(echo "$output" | jq -Rs .)
    local escaped_command=$(echo "$command" | jq -Rs .)
    
    cat << EOF
{
    "success": $([ $exit_code -eq 0 ] && echo "true" || echo "false"),
    "command": $escaped_command,
    "output": $escaped_output,
    "exit_code": $exit_code,
    "working_directory": "$working_dir"
}
EOF
}

# Main entry point
case "$1" in
    get_definition)
        get_definition
        ;;
    get_environment)
        get_environment "${2:-.}"
        ;;
    execute)
        execute "$2"
        ;;
    *)
        echo "Usage: $0 {get_definition|get_environment|execute}" >&2
        exit 1
        ;;
esac

