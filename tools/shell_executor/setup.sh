#!/bin/bash

################################################################################
# Shell Executor Tool
# Executes shell commands and returns output
################################################################################

TOOL_NAME="shell_executor"
TOOL_DESCRIPTION="Execute shell commands in a safe environment"

get_definition() {
    cat << 'EOF'
{
    "type": "function",
    "function": {
        "name": "shell_executor",
        "description": "Execute shell commands and return their output. Use this to run system commands, scripts, or perform file operations.",
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
                }
            },
            "required": ["command"]
        }
    }
}
EOF
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
    
    # Execute command in subshell
    local output=""
    local exit_code=0
    
    output=$(cd "$working_dir" && eval "$command" 2>&1) || exit_code=$?
    
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

