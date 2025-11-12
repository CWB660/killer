#!/bin/bash

################################################################################
# Calculator Tool
# Performs mathematical calculations
################################################################################

TOOL_NAME="calculator"
TOOL_DESCRIPTION="Perform mathematical calculations"

get_definition() {
    cat << 'EOF'
{
    "type": "function",
    "function": {
        "name": "calculator",
        "description": "Perform mathematical calculations. Supports basic arithmetic, scientific calculations, and mathematical expressions.",
        "parameters": {
            "type": "object",
            "properties": {
                "expression": {
                    "type": "string",
                    "description": "Mathematical expression to evaluate (e.g., '2 + 2', 'sqrt(16)', 'sin(3.14159/2)')"
                }
            },
            "required": ["expression"]
        }
    }
}
EOF
}

execute() {
    local args="$1"
    local expression=$(echo "$args" | jq -r '.expression')
    
    # Use bc for calculation (with math library)
    local result=""
    local error=""
    
    # Try to evaluate using bc
    result=$(echo "scale=10; $expression" | bc -l 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        cat << EOF
{
    "success": true,
    "expression": "$(echo "$expression" | jq -Rs .)",
    "result": "$result"
}
EOF
    else
        cat << EOF
{
    "success": false,
    "expression": "$(echo "$expression" | jq -Rs .)",
    "error": "Invalid expression or calculation error"
}
EOF
    fi
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

