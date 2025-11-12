#!/bin/bash

################################################################################
# File Operations Tool
# Read and write files
################################################################################

TOOL_NAME="file_operations"
TOOL_DESCRIPTION="Read, write, and search files on the filesystem"

get_definition() {
    cat << 'EOF'
{
    "type": "function",
    "function": {
        "name": "file_operations",
        "description": "Perform file operations like reading, writing, and searching files. Supports reading file contents, writing data to files, and searching with grep.",
        "parameters": {
            "type": "object",
            "properties": {
                "operation": {
                    "type": "string",
                    "enum": ["read", "write", "append", "list", "grep"],
                    "description": "The operation to perform: read, write, append, list, or grep"
                },
                "path": {
                    "type": "string",
                    "description": "File or directory path"
                },
                "content": {
                    "type": "string",
                    "description": "Content to write (for write/append operations)"
                },
                "pattern": {
                    "type": "string",
                    "description": "Search pattern for grep operation"
                },
                "recursive": {
                    "type": "boolean",
                    "description": "Whether to search recursively in directories (for grep)"
                },
                "case_sensitive": {
                    "type": "boolean",
                    "description": "Whether grep search is case sensitive (default: true)"
                }
            },
            "required": ["operation", "path"]
        }
    }
}
EOF
}

execute() {
    local args="$1"
    local operation=$(echo "$args" | jq -r '.operation')
    local path=$(echo "$args" | jq -r '.path')
    local content=$(echo "$args" | jq -r '.content // ""')
    local pattern=$(echo "$args" | jq -r '.pattern // ""')
    local recursive=$(echo "$args" | jq -r '.recursive // false')
    local case_sensitive=$(echo "$args" | jq -r '.case_sensitive // true')
    
    case "$operation" in
        read)
            if [ ! -f "$path" ]; then
                cat << EOF
{
    "success": false,
    "error": "File not found: $path"
}
EOF
                return 1
            fi
            
            local file_content=$(cat "$path" | jq -Rs .)
            cat << EOF
{
    "success": true,
    "operation": "read",
    "path": "$path",
    "content": $file_content,
    "size": $(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
}
EOF
            ;;
            
        write)
            echo "$content" > "$path"
            if [ $? -eq 0 ]; then
                cat << EOF
{
    "success": true,
    "operation": "write",
    "path": "$path",
    "bytes_written": ${#content}
}
EOF
            else
                cat << EOF
{
    "success": false,
    "error": "Failed to write to file: $path"
}
EOF
            fi
            ;;
            
        append)
            echo "$content" >> "$path"
            if [ $? -eq 0 ]; then
                cat << EOF
{
    "success": true,
    "operation": "append",
    "path": "$path",
    "bytes_appended": ${#content}
}
EOF
            else
                cat << EOF
{
    "success": false,
    "error": "Failed to append to file: $path"
}
EOF
            fi
            ;;
            
        list)
            if [ ! -d "$path" ]; then
                cat << EOF
{
    "success": false,
    "error": "Directory not found: $path"
}
EOF
                return 1
            fi
            
            local files=$(ls -la "$path" | tail -n +2 | jq -R . | jq -s .)
            cat << EOF
{
    "success": true,
    "operation": "list",
    "path": "$path",
    "files": $files
}
EOF
            ;;
            
        grep)
            if [ -z "$pattern" ]; then
                cat << EOF
{
    "success": false,
    "error": "Pattern is required for grep operation"
}
EOF
                return 1
            fi
            
            if [ ! -e "$path" ]; then
                cat << EOF
{
    "success": false,
    "error": "Path not found: $path"
}
EOF
                return 1
            fi
            
            # Build grep options
            local grep_opts=""
            [ "$case_sensitive" = "false" ] && grep_opts="-i"
            [ "$recursive" = "true" ] && grep_opts="$grep_opts -r"
            
            # Add line numbers and color output
            grep_opts="$grep_opts -n"
            
            # Execute grep and capture results
            local grep_result
            if grep_result=$(grep $grep_opts "$pattern" "$path" 2>&1); then
                local matches=$(echo "$grep_result" | jq -R . | jq -s .)
                local match_count=$(echo "$grep_result" | wc -l | tr -d ' ')
                cat << EOF
{
    "success": true,
    "operation": "grep",
    "path": "$path",
    "pattern": "$pattern",
    "matches": $matches,
    "match_count": $match_count,
    "case_sensitive": $case_sensitive,
    "recursive": $recursive
}
EOF
            else
                # Check if it's a real error or just no matches
                if [ $? -eq 1 ]; then
                    # Exit code 1 means no matches found
                    cat << EOF
{
    "success": true,
    "operation": "grep",
    "path": "$path",
    "pattern": "$pattern",
    "matches": [],
    "match_count": 0,
    "case_sensitive": $case_sensitive,
    "recursive": $recursive
}
EOF
                else
                    # Other errors
                    local error_msg=$(echo "$grep_result" | jq -Rs .)
                    cat << EOF
{
    "success": false,
    "error": "Grep failed: $error_msg"
}
EOF
                    return 1
                fi
            fi
            ;;
            
        *)
            cat << EOF
{
    "success": false,
    "error": "Unknown operation: $operation"
}
EOF
            return 1
            ;;
    esac
}

# Main entry point
case "$1" in
    get_definition)
        get_definition
        ;;
    execute)
        execute "$2"
        ;;
    *)
        echo "Usage: $0 {get_definition|execute}" >&2
        exit 1
        ;;
esac

