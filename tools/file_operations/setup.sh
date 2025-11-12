#!/bin/bash

################################################################################
# File Operations Tool
# Read and write files
################################################################################

TOOL_NAME="file_operations"
TOOL_DESCRIPTION="Read and write files on the filesystem"

get_definition() {
    cat << 'EOF'
{
    "type": "function",
    "function": {
        "name": "file_operations",
        "description": "Perform file operations like reading and writing files. Supports reading file contents and writing data to files.",
        "parameters": {
            "type": "object",
            "properties": {
                "operation": {
                    "type": "string",
                    "enum": ["read", "write", "append", "list"],
                    "description": "The operation to perform: read, write, append, or list"
                },
                "path": {
                    "type": "string",
                    "description": "File or directory path"
                },
                "content": {
                    "type": "string",
                    "description": "Content to write (for write/append operations)"
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

