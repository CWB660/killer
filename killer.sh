#!/bin/bash

################################################################################
# Killer.sh - A Perfect Shell-Based AI Agent
# 
# Features:
# - OpenAI Chat Completions API Support
# - Tool Calling & Function Execution
# - Multi-round Self-iteration
# - Prompt Templates from prompts/ directory
# - Custom Tools from tools/ directory
################################################################################

# set -e  # Disabled to allow proper error handling
set -o pipefail  # Fail on pipe errors

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
# Support both local execution and global installation
if [ -n "$KILLER_INSTALL_DIR" ]; then
    # Running from global installation
    SCRIPT_DIR="$KILLER_INSTALL_DIR"
    ENV_FILE="$HOME/.killer.env"
else
    # Running locally
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ENV_FILE="$SCRIPT_DIR/.env"
fi

# Load .env file if exists
if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
    set -a  # automatically export all variables
    source "$ENV_FILE" 2>/dev/null || true
    set +a
fi

PROMPTS_DIR="${SCRIPT_DIR}/prompts"
TOOLS_DIR="${SCRIPT_DIR}/tools"
GLM_CODING_API_BASE="${GLM_CODING_API_BASE:-https://open.bigmodel.cn/api/coding/paas/v4}"
GLM_CODING_MODEL="${GLM_CODING_MODEL:-glm-4.6}"
MAX_ITERATIONS="${MAX_ITERATIONS:-25}"

# Use user's home directory for temp files to avoid permission issues
if [ -n "$KILLER_INSTALL_DIR" ]; then
    # Global installation: use user's home directory
    TEMP_DIR="$HOME/.killer/tmp"
else
    # Local execution: use project directory
    TEMP_DIR="${SCRIPT_DIR}/.tmp"
fi

# Global variables
CONVERSATION_HISTORY=()
AVAILABLE_TOOLS=()
TOOL_DEFINITIONS=""
CURRENT_ITERATION=0
AUTO_INSTALL_DEPS=false

################################################################################
# Utility Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_agent() {
    echo -e "${MAGENTA}[AGENT]${NC} $1"
}

log_tool() {
    echo -e "${CYAN}[TOOL]${NC} $1"
}

# Auto-install dependencies based on OS
auto_install_dependencies() {
    local deps="$1"
    
    log_info "Attempting to auto-install: $deps"
    
    # Detect OS and package manager
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            log_info "Using Homebrew to install dependencies..."
            brew install $deps
            return $?
        else
            log_warn "Homebrew not found. Install it from https://brew.sh"
            return 1
        fi
    elif [[ -f /etc/debian_version ]]; then
        # Debian/Ubuntu
        log_info "Using apt to install dependencies..."
        sudo apt-get update && sudo apt-get install -y $deps
        return $?
    elif [[ -f /etc/redhat-release ]]; then
        # CentOS/RHEL/Fedora
        if command -v dnf &> /dev/null; then
            log_info "Using dnf to install dependencies..."
            sudo dnf install -y $deps
            return $?
        elif command -v yum &> /dev/null; then
            log_info "Using yum to install dependencies..."
            sudo yum install -y $deps
            return $?
        fi
    elif [[ -f /etc/arch-release ]]; then
        # Arch Linux
        log_info "Using pacman to install dependencies..."
        sudo pacman -S --noconfirm $deps
        return $?
    fi
    
    log_error "Could not determine package manager for auto-install"
    return 1
}

# Check if required commands are available
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        
        # Check if auto-install is enabled or ask user
        local should_install=false
        
        if [ "$AUTO_INSTALL_DEPS" = true ]; then
            should_install=true
        elif [ -t 0 ]; then
            # Interactive mode - ask user
            echo -e "${YELLOW}Would you like to automatically install missing dependencies? (y/N)${NC}"
            read -r response
            
            if [[ "$response" =~ ^[Yy]$ ]]; then
                should_install=true
            fi
        fi
        
        if [ "$should_install" = true ]; then
            if auto_install_dependencies "${missing_deps[*]}"; then
                log_success "Dependencies installed successfully!"
                return 0
            else
                log_error "Auto-install failed"
                echo ""
            fi
        fi
        
        # Show manual install instructions
        log_info "Please install them manually:"
        echo ""
        
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "  brew install ${missing_deps[*]}"
        elif [[ -f /etc/debian_version ]]; then
            echo "  sudo apt-get install ${missing_deps[*]}"
        elif [[ -f /etc/redhat-release ]]; then
            echo "  sudo yum install ${missing_deps[*]}"
        elif [[ -f /etc/arch-release ]]; then
            echo "  sudo pacman -S ${missing_deps[*]}"
        else
            echo "  Use your system's package manager to install: ${missing_deps[*]}"
        fi
        
        echo ""
        exit 1
    fi
}

# Interactive configuration setup
setup_config() {
    log_info "Setting up killer.sh configuration..."
    echo ""
    
    # Ask for API key
    if [ -z "$GLM_CODING_API_KEY" ]; then
        echo -e "${YELLOW}Enter your GLM Coding API key:${NC}"
        read -r GLM_CODING_API_KEY
        if [ -z "$GLM_CODING_API_KEY" ]; then
            log_error "API key is required!"
            exit 1
        fi
    fi
    
    # Ask for model (with default)
    echo ""
    echo -e "${YELLOW}Enter default model (press Enter for 'glm-4.6'):${NC}"
    read -r input_model
    if [ -n "$input_model" ]; then
        GLM_CODING_MODEL="$input_model"
    fi
    
    # Ask for API base URL (with default)
    echo ""
    echo -e "${YELLOW}Enter API base URL (press Enter for 'https://open.bigmodel.cn/api/coding/paas/v4'):${NC}"
    read -r input_api_base
    if [ -n "$input_api_base" ]; then
        GLM_CODING_API_BASE="$input_api_base"
    fi
    
    # Ask for max iterations (with default)
    echo ""
    echo -e "${YELLOW}Enter maximum iterations (press Enter for '25'):${NC}"
    read -r input_max_iterations
    if [ -n "$input_max_iterations" ]; then
        MAX_ITERATIONS="$input_max_iterations"
    fi
    
    # Save to .env file
    echo ""
    log_info "Saving configuration to $ENV_FILE..."
    cat > "$ENV_FILE" << EOF
# Killer.sh Configuration
# Generated on $(date)

# GLM Coding API Configuration
GLM_CODING_API_KEY=$GLM_CODING_API_KEY
GLM_CODING_MODEL=$GLM_CODING_MODEL
GLM_CODING_API_BASE=$GLM_CODING_API_BASE
MAX_ITERATIONS=$MAX_ITERATIONS
EOF
    
    chmod 600 "$ENV_FILE"  # Secure the file
    log_success "Configuration saved!"
    echo ""
}

# Check if GLM_CODING_API_KEY is set
check_api_key() {
    if [ -z "$GLM_CODING_API_KEY" ]; then
        log_warn "GLM_CODING_API_KEY environment variable is not set"
        echo ""
        read -p "Would you like to configure it now? [Y/n] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_config
        else
            log_error "API key is required to run killer.sh"
            log_info "Please set it using: export GLM_CODING_API_KEY='your-api-key'"
            log_info "Or run 'killer --setup' to configure interactively"
            exit 1
        fi
    fi
}

# Initialize directories
init_dirs() {
    mkdir -p "$PROMPTS_DIR"
    mkdir -p "$TOOLS_DIR"
    mkdir -p "$TEMP_DIR"
}

################################################################################
# Prompt Management
################################################################################

# List available prompts
list_prompts() {
    if [ ! -d "$PROMPTS_DIR" ]; then
        return
    fi
    
    local prompts=($(find "$PROMPTS_DIR" -name "*.md" -type f))
    
    if [ ${#prompts[@]} -eq 0 ]; then
        return
    fi
    
    log_info "Available prompts:"
    for prompt in "${prompts[@]}"; do
        local name=$(basename "$prompt" .md)
        echo "  - $name"
    done
}

# Load prompt from file
load_prompt() {
    local prompt_name="$1"
    local prompt_file="${PROMPTS_DIR}/${prompt_name}.md"
    
    if [ ! -f "$prompt_file" ]; then
        log_error "Prompt file not found: $prompt_file"
        return 1
    fi
    
    cat "$prompt_file"
}

################################################################################
# Tool Management
################################################################################

# Initialize all tools
init_tools() {
    if [ ! -d "$TOOLS_DIR" ]; then
        return
    fi
    
    local tool_dirs=($(find "$TOOLS_DIR" -mindepth 1 -maxdepth 1 -type d))
    
    for tool_dir in "${tool_dirs[@]}"; do
        local setup_script="${tool_dir}/setup.sh"
        
        if [ -f "$setup_script" ]; then
            log_info "Initializing tool: $(basename "$tool_dir")"
            
            # Source the setup script to get tool definition
            if bash "$setup_script" "get_definition" > /dev/null 2>&1; then
                local tool_name=$(basename "$tool_dir")
                AVAILABLE_TOOLS+=("$tool_name")
            fi
        fi
    done
    
    # Build tool definitions JSON
    build_tool_definitions
}

# Build tool definitions for GLM Coding API
build_tool_definitions() {
    local tools_json="["
    local first=true
    
    for tool_name in "${AVAILABLE_TOOLS[@]}"; do
        local tool_dir="${TOOLS_DIR}/${tool_name}"
        local definition=$(bash "${tool_dir}/setup.sh" "get_definition")
        
        if [ ! -z "$definition" ]; then
            if [ "$first" = true ]; then
                first=false
            else
                tools_json+=","
            fi
            tools_json+="$definition"
        fi
    done
    
    tools_json+="]"
    TOOL_DEFINITIONS="$tools_json"
}

# Execute a tool
execute_tool() {
    local tool_name="$1"
    local tool_args="$2"
    
    local tool_dir="${TOOLS_DIR}/${tool_name}"
    local setup_script="${tool_dir}/setup.sh"
    
    if [ ! -f "$setup_script" ]; then
        echo "{\"error\": \"Tool not found: $tool_name\"}"
        return 1
    fi
    
    # Execute the tool with arguments
    local result=$(bash "$setup_script" "execute" "$tool_args" 2>&1)
    local exec_status=$?
    
    if [ $exec_status -ne 0 ]; then
        log_warn "Tool execution returned non-zero status: $exec_status"
    fi
    
    echo "$result"
    return $exec_status
}

################################################################################
# OpenAI API Functions
################################################################################

# Build messages JSON from conversation history
build_messages_json() {
    local messages="["
    local first=true
    
    for msg in "${CONVERSATION_HISTORY[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            messages+=","
        fi
        messages+="$msg"
    done
    
    messages+="]"
    echo "$messages"
}

# Add message to conversation history
add_message() {
    local role="$1"
    local content="$2"
    
    # Escape content for JSON
    local escaped_content=$(echo "$content" | jq -Rs .)
    
    local message="{\"role\":\"$role\",\"content\":$escaped_content}"
    CONVERSATION_HISTORY+=("$message")
}

# Add tool call message to history
add_tool_call_message() {
    local tool_calls="$1"
    local message="{\"role\":\"assistant\",\"content\":null,\"tool_calls\":$tool_calls}"
    CONVERSATION_HISTORY+=("$message")
}

# Add tool response to history
add_tool_response() {
    local tool_call_id="$1"
    local tool_name="$2"
    local result="$3"
    
    local escaped_result=$(echo "$result" | jq -Rs .)
    local message="{\"role\":\"tool\",\"tool_call_id\":\"$tool_call_id\",\"name\":\"$tool_name\",\"content\":$escaped_result}"
    CONVERSATION_HISTORY+=("$message")
}

# Call OpenAI Chat Completions API
call_openai_api() {
    local messages=$(build_messages_json)
    
    if [ -z "$messages" ]; then
        log_error "Failed to build messages JSON"
        return 1
    fi
    
    # Build request payload
    local payload=$(jq -n \
        --arg model "$GLM_CODING_MODEL" \
        --argjson messages "$messages" \
        --argjson tools "$TOOL_DEFINITIONS" \
        '{
            model: $model,
            messages: $messages
        } + (if ($tools | length) > 0 then {tools: $tools, tool_choice: "auto"} else {} end)')
    
    if [ -z "$payload" ]; then
        log_error "Failed to build request payload"
        return 1
    fi
    
    # Make API request
    local response=$(curl -s -w "\n%{http_code}" -X POST "$GLM_CODING_API_BASE/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $GLM_CODING_API_KEY" \
        -d "$payload")
    
    # Extract HTTP status code
    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | sed '$d')
    
    # Check HTTP status
    if [ "$http_code" != "200" ]; then
        log_error "API HTTP Error: $http_code"
        log_error "Response: $response_body"
        return 1
    fi
    
    # Validate JSON response
    if ! echo "$response_body" | jq empty 2>/dev/null; then
        log_error "Invalid JSON response from API"
        log_error "Response: $response_body"
        return 1
    fi
    
    # Check for API errors
    local error=$(echo "$response_body" | jq -r '.error.message // empty')
    if [ ! -z "$error" ]; then
        log_error "API Error: $error"
        return 1
    fi
    
    echo "$response_body"
}

################################################################################
# Agent Logic
################################################################################

# Process a single iteration
process_iteration() {
    CURRENT_ITERATION=$((CURRENT_ITERATION + 1))
    
    if [ $CURRENT_ITERATION -gt $MAX_ITERATIONS ]; then
        log_warn "Maximum iterations ($MAX_ITERATIONS) reached"
        return 1
    fi
    
    log_info "Iteration $CURRENT_ITERATION/$MAX_ITERATIONS"
    
    # Call OpenAI API
    local response=$(call_openai_api)
    local api_status=$?
    
    if [ $api_status -ne 0 ]; then
        log_error "API call failed with status $api_status"
        return 1
    fi
    
    if [ -z "$response" ]; then
        log_error "Empty response from API"
        return 1
    fi
    
    # Save response for debugging
    echo "$response" > "$TEMP_DIR/last_response.json"
    
    # Parse response with error checking
    local finish_reason=$(echo "$response" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null)
    if [ -z "$finish_reason" ]; then
        log_error "Failed to parse finish_reason from response"
        log_error "Response saved to: $TEMP_DIR/last_response.json"
        return 1
    fi
    
    local message=$(echo "$response" | jq -r '.choices[0].message // empty' 2>/dev/null)
    if [ -z "$message" ] || [ "$message" = "empty" ]; then
        log_error "Failed to parse message from response"
        return 1
    fi
    
    local content=$(echo "$message" | jq -r '.content // empty' 2>/dev/null)
    local tool_calls=$(echo "$message" | jq -r '.tool_calls // empty' 2>/dev/null)
    
    log_info "Finish reason: $finish_reason"
    
    # Handle different finish reasons
    case "$finish_reason" in
        "stop")
            if [ ! -z "$content" ] && [ "$content" != "empty" ] && [ "$content" != "null" ]; then
                log_agent "$content"
                add_message "assistant" "$content"
            fi
            return 0
            ;;
            
        "tool_calls")
            # Validate tool_calls
            if [ -z "$tool_calls" ] || [ "$tool_calls" = "empty" ] || [ "$tool_calls" = "null" ]; then
                log_error "No tool_calls found in response despite finish_reason=tool_calls"
                return 1
            fi
            
            # Add tool call message to history
            add_tool_call_message "$tool_calls"
            
            # Process each tool call
            local num_calls=$(echo "$tool_calls" | jq 'length' 2>/dev/null)
            if [ -z "$num_calls" ] || [ "$num_calls" = "0" ]; then
                log_error "Invalid tool_calls array"
                return 1
            fi
            
            log_info "Processing $num_calls tool call(s)"
            
            for ((i=0; i<num_calls; i++)); do
                local tool_call=$(echo "$tool_calls" | jq ".[$i]" 2>/dev/null)
                local call_id=$(echo "$tool_call" | jq -r '.id // empty' 2>/dev/null)
                local tool_name=$(echo "$tool_call" | jq -r '.function.name // empty' 2>/dev/null)
                local tool_args=$(echo "$tool_call" | jq -r '.function.arguments // empty' 2>/dev/null)
                
                if [ -z "$call_id" ] || [ -z "$tool_name" ]; then
                    log_error "Invalid tool call format at index $i"
                    continue
                fi
                
                log_tool "Calling: $tool_name"
                
                # Execute tool
                local tool_result=$(execute_tool "$tool_name" "$tool_args")
                local tool_status=$?
                
                if [ $tool_status -ne 0 ]; then
                    log_warn "Tool execution failed with status $tool_status"
                fi
                
                # Add tool response to history
                add_tool_response "$call_id" "$tool_name" "$tool_result"
            done
            
            # Continue iteration
            return 2
            ;;
            
        *)
            log_warn "Unexpected finish reason: $finish_reason"
            log_error "Response saved to: $TEMP_DIR/last_response.json"
            return 1
            ;;
    esac
}

# Main agent loop
run_agent() {
    local user_query="$1"
    
    # Add user message
    add_message "user" "$user_query"
    
    log_info "Starting AI Agent"
    log_info "Query: $user_query"
    
    # Run iteration loop
    while true; do
        process_iteration
        local status=$?
        
        if [ $status -eq 0 ]; then
            # Task completed
            log_success "Task completed successfully"
            break
        elif [ $status -eq 2 ]; then
            # Continue iteration
            continue
        else
            # Error occurred
            log_error "Agent failed"
            break
        fi
    done
}

################################################################################
# CLI Interface
################################################################################

show_help() {
    cat << EOF
Killer.sh - A Perfect Shell-Based AI Agent

Usage: $0 [OPTIONS] <command|query>

Commands:
    <query>                  Run the agent with a query (default)
    <prompt-name> <query>    Run with a specific prompt template
    list-prompts             List available prompts
    list-tools               List available tools
    setup                    Interactive configuration setup
    help                     Show this help message

Options:
    --model <model>          Set GLM model (default: glm-4.6)
    --max-iterations <n>     Set maximum iterations (default: 25)
    --api-url <url>          Set custom API URL (default: https://open.bigmodel.cn/api/coding/paas/v4)
    --setup                  Run interactive configuration setup

Environment Variables:
    GLM_CODING_API_KEY          GLM Coding API key (required)
    GLM_CODING_MODEL            Default model to use
    GLM_CODING_API_BASE          Custom API URL
    MAX_ITERATIONS          Maximum iteration count
EOF
}

main() {
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --model)
                GLM_CODING_MODEL="$2"
                shift 2
                ;;
            --max-iterations)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --api-url)
                GLM_CODING_API_BASE="$2"
                shift 2
                ;;
            --auto-install)
                AUTO_INSTALL_DEPS=true
                shift
                ;;
            setup|--setup)
                setup_config
                exit 0
                ;;
            help|--help|-h)
                show_help
                exit 0
                ;;
            list-prompts)
                init_dirs
                list_prompts
                exit 0
                ;;
            list-tools)
                init_dirs
                init_tools
                log_info "Available tools:"
                for tool in "${AVAILABLE_TOOLS[@]}"; do
                    echo "  - $tool"
                done
                exit 0
                ;;
            run)
                if [ -z "$2" ]; then
                    log_error "Query is required"
                    show_help
                    exit 1
                fi
                
                check_dependencies
                check_api_key
                init_dirs
                init_tools
                
                run_agent "$2"
                exit 0
                ;;
            prompt)
                if [ -z "$2" ] || [ -z "$3" ]; then
                    log_error "Prompt name and query are required"
                    show_help
                    exit 1
                fi
                
                check_dependencies
                check_api_key
                init_dirs
                init_tools
                
                local prompt_content=$(load_prompt "$2")
                if [ $? -ne 0 ]; then
                    exit 1
                fi
                
                # Add system message with prompt
                add_message "system" "$prompt_content"
                
                run_agent "$3"
                exit 0
                ;;
            *)
                # Check if first argument is a prompt name
                init_dirs
                
                # If two arguments are provided, first must be a valid prompt name
                if [ ! -z "$2" ]; then
                    local prompt_file="${PROMPTS_DIR}/${1}.md"
                    if [ ! -f "$prompt_file" ]; then
                        log_error "Prompt not found: $1"
                        list_prompts
                        exit 1
                    fi
                    
                    # Use as prompt command: killer.sh <prompt-name> <query>
                    check_dependencies
                    check_api_key
                    init_tools
                    
                    local prompt_content=$(load_prompt "$1")
                    if [ $? -ne 0 ]; then
                        exit 1
                    fi
                    
                    # Add system message with prompt
                    add_message "system" "$prompt_content"
                    
                    run_agent "$2"
                    exit 0
                elif [ ! -z "$1" ]; then
                    # Treat as direct query: killer.sh <query>
                    check_dependencies
                    check_api_key
                    init_tools
                    
                    run_agent "$1"
                    exit 0
                else
                    log_error "Unknown command: $1"
                    show_help
                    exit 1
                fi
                ;;
        esac
    done
    
    show_help
}

# Run main
main "$@"

