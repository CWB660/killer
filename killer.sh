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

# Tool execution timeout (in seconds)
TOOL_TIMEOUT="${TOOL_TIMEOUT:-180}"  # 3 minutes default

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
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"

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
INTERACTIVE_MODE=false
NEEDS_USER_INPUT=false
USER_JUST_CONFIRMED=false
USER_REQUESTED_EXIT=false

# Token management and compression
TOTAL_TOKENS_USED=0
CURRENT_CONTEXT_TOKENS=0
MAX_CONTEXT_TOKENS="${MAX_CONTEXT_TOKENS:-204800}"  # Maximum context size
COMPRESSION_THRESHOLD="${COMPRESSION_THRESHOLD:-184300}"  # Trigger compression at this threshold

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

# Show thinking animation while processing
show_thinking_animation() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local dots=0
    
    # Hide cursor
    tput civis 2>/dev/null || true
    
    while kill -0 $pid 2>/dev/null; do
        for i in $(seq 0 9); do
            local spinner_char=$(echo "$spinstr" | cut -c$((i+1)))
            local dot_str=""
            case $((dots % 4)) in
                0) dot_str="" ;;
                1) dot_str="." ;;
                2) dot_str=".." ;;
                3) dot_str="..." ;;
            esac
            printf "\r ${MAGENTA}${spinner_char}${NC} ${CYAN}Thinking${dot_str}${NC}   "
            sleep $delay
            
            # Check if process still exists
            kill -0 $pid 2>/dev/null || break
        done
        dots=$((dots + 1))
    done
    
    # Clear the line and show cursor
    printf "\r\033[K"
    tput cnorm 2>/dev/null || true
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
    echo -e "${YELLOW}Enter maximum iterations (press Enter for '50'):${NC}"
    read -r input_max_iterations
    if [ -n "$input_max_iterations" ]; then
        MAX_ITERATIONS="$input_max_iterations"
    fi
    
    # Ask for context compression settings
    echo ""
    echo -e "${CYAN}Context Compression Settings:${NC}"
    
    echo ""
    echo -e "${YELLOW}Enter maximum context tokens (press Enter for '16000'):${NC}"
    read -r input_max_context
    if [ -n "$input_max_context" ]; then
        MAX_CONTEXT_TOKENS="$input_max_context"
    fi
    
    echo ""
    echo -e "${YELLOW}Enter compression threshold tokens (press Enter for '12000'):${NC}"
    read -r input_compression_threshold
    if [ -n "$input_compression_threshold" ]; then
        COMPRESSION_THRESHOLD="$input_compression_threshold"
    fi
    
    # Ask for tool timeout
    echo ""
    echo -e "${YELLOW}Enter tool execution timeout in seconds (press Enter for '180' = 3 minutes):${NC}"
    read -r input_tool_timeout
    if [ -n "$input_tool_timeout" ]; then
        TOOL_TIMEOUT="$input_tool_timeout"
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

# Context Compression Settings
MAX_CONTEXT_TOKENS=$MAX_CONTEXT_TOKENS
COMPRESSION_THRESHOLD=$COMPRESSION_THRESHOLD

# Tool Execution Settings
TOOL_TIMEOUT=$TOOL_TIMEOUT
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
# Token Management & Context Compression
################################################################################

# Extract and display token usage from API response
extract_and_display_usage() {
    local response="$1"
    
    local prompt_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
    local completion_tokens=$(echo "$response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    local total_tokens=$(echo "$response" | jq -r '.usage.total_tokens // 0' 2>/dev/null)
    
    if [ "$total_tokens" -gt 0 ]; then
        # Store previous cumulative for display
        local previous_cumulative=$TOTAL_TOKENS_USED
        
        # Update totals
        TOTAL_TOKENS_USED=$((TOTAL_TOKENS_USED + total_tokens))
        CURRENT_CONTEXT_TOKENS=$prompt_tokens
        
        # Build display string with clear breakdown
        local usage_info=""
        
        # Line 1: Current round breakdown
        usage_info+="${CYAN}Prompt${NC}=${prompt_tokens} + "
        usage_info+="${CYAN}Completion${NC}=${completion_tokens} = "
        usage_info+="${GREEN}${total_tokens}${NC} tokens"
        
        # Add context warning if needed
        if [ $CURRENT_CONTEXT_TOKENS -ge $COMPRESSION_THRESHOLD ]; then
            usage_info+=" ${YELLOW}[⚠️ Context will be compressed]${NC}"
        elif [ $CURRENT_CONTEXT_TOKENS -ge $((COMPRESSION_THRESHOLD * 8 / 10)) ]; then
            usage_info+=" ${YELLOW}[⚠️ Near threshold]${NC}"
        fi
        
        # Line 2: Cumulative statistics
        usage_info+=" | Total=${MAGENTA}${TOTAL_TOKENS_USED}${NC} tokens"
        if [ $previous_cumulative -gt 0 ]; then
            usage_info+=" | Added=${GREEN}+${total_tokens}${NC}"
        fi
        
        # Calculate context usage percentage
        local context_percentage=$((CURRENT_CONTEXT_TOKENS * 100 / MAX_CONTEXT_TOKENS))
        usage_info+=" | Context: ${CYAN}${CURRENT_CONTEXT_TOKENS}${NC}/${MAX_CONTEXT_TOKENS}"
        
        # Color code the percentage based on usage level
        if [ $context_percentage -ge 90 ]; then
            usage_info+=" (${RED}${context_percentage}%${NC})"
        elif [ $context_percentage -ge 75 ]; then
            usage_info+=" (${YELLOW}${context_percentage}%${NC})"
        else
            usage_info+=" (${GREEN}${context_percentage}%${NC})"
        fi
        
        echo -e "${BLUE}[TOKEN]${NC} $usage_info"
    fi
}

# Use LLM to compress tool results with user context
compress_tool_results_with_llm() {
    local tool_messages="$1"
    local user_messages="$2"
    
    # Build a prompt for LLM to compress the tool results with user context
    local compression_prompt="You are compressing tool execution results to save context space. Please provide a concise summary that preserves information relevant to the user's questions and requests.

User's Messages (for reference):
$user_messages

Tool Execution Results to Compress:
$tool_messages

Instructions:
1. Focus on information directly relevant to the user's questions above
2. Keep important outputs, errors, and key results
3. Remove verbose logs, repetitive data, and irrelevant details
4. Maintain any critical errors or warnings
5. Keep the summary under 200 words

Provide a focused summary:"

    # Create a temporary minimal conversation for compression
    local compress_payload=$(jq -n \
        --arg model "$GLM_CODING_MODEL" \
        --arg prompt "$compression_prompt" \
        '{
            model: $model,
            messages: [
                {
                    role: "user",
                    content: $prompt
                }
            ],
            max_tokens: 500,
            temperature: 0.3
        }')
    
    # Call API to compress
    local response=$(curl -s -w "\n%{http_code}" -X POST "$GLM_CODING_API_BASE/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $GLM_CODING_API_KEY" \
        -d "$compress_payload" 2>/dev/null)
    
    # Extract HTTP status code
    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | sed '$d')
    
    # Check if compression succeeded
    if [ "$http_code" = "200" ] && echo "$response_body" | jq empty 2>/dev/null; then
        local compressed_content=$(echo "$response_body" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if [ ! -z "$compressed_content" ] && [ "$compressed_content" != "empty" ]; then
            echo "$compressed_content"
            return 0
        fi
    fi
    
    # If compression failed, return a generic summary
    echo "[Tool executions summary: Multiple tool calls were executed. Details have been compressed to save context.]"
    return 0
}

# Compress conversation history to reduce context size
compress_conversation_history() {
    local total_messages=${#CONVERSATION_HISTORY[@]}

    log_warn "Context size ($CURRENT_CONTEXT_TOKENS tokens) exceeds threshold ($COMPRESSION_THRESHOLD tokens)"
    log_info "Compressing conversation history..."
    
    # New compression strategy:
    # 1. Keep ALL system, user, and assistant messages
    # 2. Compress tool messages using LLM with user context
    # 3. Replace consecutive tool messages with a compressed summary
    
    # First pass: collect all user messages for context
    local user_messages_text=""
    local user_msg_count=0
    for ((i=0; i<total_messages; i++)); do
        local msg="${CONVERSATION_HISTORY[$i]}"
        local role=$(echo "$msg" | jq -r '.role // empty' 2>/dev/null)
        
        if [ "$role" = "user" ]; then
            local content=$(echo "$msg" | jq -r '.content // ""' 2>/dev/null)
            if [ ! -z "$content" ]; then
                user_msg_count=$((user_msg_count + 1))
                user_messages_text+="[$user_msg_count] $content\n\n"
            fi
        fi
    done
    
    log_info "Collected $user_msg_count user message(s) as compression context"
    
    # Second pass: process and compress messages
    local new_history=()
    local tool_batch=()
    local tool_count=0
    
    for ((i=0; i<total_messages; i++)); do
        local msg="${CONVERSATION_HISTORY[$i]}"
        local role=$(echo "$msg" | jq -r '.role // empty' 2>/dev/null)
        
        if [ "$role" = "tool" ]; then
            # Collect tool messages for batch compression
            tool_batch+=("$msg")
            tool_count=$((tool_count + 1))
        else
            # Before adding non-tool message, process any accumulated tool messages
            if [ ${#tool_batch[@]} -gt 0 ]; then
                log_info "Compressing $tool_count tool message(s) using LLM (with user context)..."
                
                # Extract tool contents for compression
                local tool_contents=""
                for tool_msg in "${tool_batch[@]}"; do
                    local tool_name=$(echo "$tool_msg" | jq -r '.name // "unknown"' 2>/dev/null)
                    local tool_content=$(echo "$tool_msg" | jq -r '.content // ""' 2>/dev/null)
                    tool_contents+="Tool: $tool_name\n$tool_content\n\n"
                done
                
                # Compress using LLM with user context
                local compressed_summary=$(compress_tool_results_with_llm "$tool_contents" "$user_messages_text")
                
                # Create a single compressed tool message
                # Use the first tool message's ID to maintain structure
                local first_tool_id=$(echo "${tool_batch[0]}" | jq -r '.tool_call_id // "compressed"' 2>/dev/null)
                local compressed_msg=$(jq -n \
                    --arg id "$first_tool_id" \
                    --arg summary "$compressed_summary" \
                    --arg count "$tool_count" \
                    '{
                        role: "tool",
                        tool_call_id: $id,
                        name: "compressed_tools",
                        content: "[Compressed \($count) tool results] \($summary)"
                    }')
                
                new_history+=("$compressed_msg")
                
                # Clear the batch
                tool_batch=()
                tool_count=0
            fi
            
            # Add the non-tool message (system/user/assistant)
            if [ "$role" = "system" ] || [ "$role" = "user" ] || [ "$role" = "assistant" ]; then
                new_history+=("$msg")
            fi
        fi
    done
    
    # Process any remaining tool messages at the end
    if [ ${#tool_batch[@]} -gt 0 ]; then
        log_info "Compressing final $tool_count tool message(s) using LLM (with user context)..."
        
        local tool_contents=""
        for tool_msg in "${tool_batch[@]}"; do
            local tool_name=$(echo "$tool_msg" | jq -r '.name // "unknown"' 2>/dev/null)
            local tool_content=$(echo "$tool_msg" | jq -r '.content // ""' 2>/dev/null)
            tool_contents+="Tool: $tool_name\n$tool_content\n\n"
        done
        
        local compressed_summary=$(compress_tool_results_with_llm "$tool_contents" "$user_messages_text")
        
        local first_tool_id=$(echo "${tool_batch[0]}" | jq -r '.tool_call_id // "compressed"' 2>/dev/null)
        local compressed_msg=$(jq -n \
            --arg id "$first_tool_id" \
            --arg summary "$compressed_summary" \
            --arg count "$tool_count" \
            '{
                role: "tool",
                tool_call_id: $id,
                name: "compressed_tools",
                content: "[Compressed \($count) tool results] \($summary)"
            }')
        
        new_history+=("$compressed_msg")
    fi
    
    # Update conversation history
    CONVERSATION_HISTORY=("${new_history[@]}")
    
    local new_count=${#CONVERSATION_HISTORY[@]}
    
    # Estimate new token count (rough approximation: ~4 chars per token)
    local messages_json=$(build_messages_json)
    
    # Validate the built messages JSON
    if [ -z "$messages_json" ]; then
        log_error "Failed to build messages JSON after compression"
        return 1
    fi
    
    if ! echo "$messages_json" | jq empty 2>/dev/null; then
        log_error "Invalid messages JSON after compression"
        log_error "Messages JSON: $messages_json"
        return 1
    fi
    
    local estimated_tokens=$((${#messages_json} / 4))
    CURRENT_CONTEXT_TOKENS=$estimated_tokens
    
    log_success "Compressed from $total_messages to $new_count messages"
    log_info "Estimated context tokens after compression: $CURRENT_CONTEXT_TOKENS"
    
    # Check if still too large
    if [ $CURRENT_CONTEXT_TOKENS -ge $MAX_CONTEXT_TOKENS ]; then
        log_error "Context size ($CURRENT_CONTEXT_TOKENS) still exceeds maximum ($MAX_CONTEXT_TOKENS) after compression"
        return 1
    fi
    
    return 0
}

# Check if compression is needed and perform it
check_and_compress_context() {
    # Only compress if we exceed the threshold
    if [ $CURRENT_CONTEXT_TOKENS -ge $COMPRESSION_THRESHOLD ]; then
        compress_conversation_history
        return $?
    fi
    
    return 0
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

# Display text in a scrolling 5-line window
display_scrolling_output() {
    local text="$1"
    local max_lines=5
    
    # Split text into lines
    local -a lines
    while IFS= read -r line; do
        lines+=("$line")
    done <<< "$text"
    
    local total_lines=${#lines[@]}
    
    if [ $total_lines -le $max_lines ]; then
        # If less than max lines, just display all
        for line in "${lines[@]}"; do
            echo "$line" >&2
        done
    else
        # Reserve space for the scrolling window
        for ((i=0; i<max_lines; i++)); do
            echo "" >&2
        done
        
        # Move cursor up to start of window
        tput cuu $max_lines >&2
        
        # Display lines with scrolling effect
        local display_start=0
        local display_end=$((max_lines - 1))
        
        while [ $display_end -lt $total_lines ]; do
            # Clear the window area and display current lines
            tput sc >&2  # Save cursor position
            
            for ((i=0; i<max_lines; i++)); do
                local line_idx=$((display_start + i))
                if [ $line_idx -lt $total_lines ]; then
                    # Clear line and print content
                    tput el >&2
                    echo -n "${lines[$line_idx]}" >&2
                fi
                
                if [ $i -lt $((max_lines - 1)) ]; then
                    echo "" >&2  # Move to next line
                fi
            done
            
            # Restore cursor and move up
            tput rc >&2
            
            # Scroll: increment the display window
            display_start=$((display_start + 1))
            display_end=$((display_end + 1))
        done
        
        # Display final window
        tput sc >&2
        for ((i=0; i<max_lines; i++)); do
            local line_idx=$((total_lines - max_lines + i))
            if [ $line_idx -ge 0 ] && [ $line_idx -lt $total_lines ]; then
                tput el >&2
                echo -n "${lines[$line_idx]}" >&2
            fi
            if [ $i -lt $((max_lines - 1)) ]; then
                echo "" >&2
            fi
        done
        echo "" >&2  # Final newline
    fi
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
    
    # Display tool call parameters (to stderr so it's not captured)
    echo -e "${CYAN}[TOOL]${NC} Calling: ${CYAN}${tool_name}${NC}" >&2
    
    # Pretty print arguments
    if [ ! -z "$tool_args" ] && [ "$tool_args" != "null" ] && [ "$tool_args" != "empty" ]; then
        echo -e "${CYAN}Parameters:${NC}" >&2
        # Try to parse and pretty print JSON, fall back to raw output
        if echo "$tool_args" | jq empty 2>/dev/null; then
            echo "$tool_args" | jq '.' >&2
        else
            echo "$tool_args" >&2
        fi
    else
        echo -e "${CYAN}Parameters: ${NC}(none)" >&2
    fi

    echo -e "${CYAN}Output:${NC}" >&2
    
    # Execute the tool with arguments and capture output with timeout
    # Using a cross-platform bash-native timeout mechanism
    local result
    local exec_status=0
    local output_file="$TEMP_DIR/tool_output_$$_${tool_name}.tmp"
    local status_file="$TEMP_DIR/tool_status_$$_${tool_name}.tmp"
    
    # Start tool execution in background
    (
        tool_output=$(bash "$setup_script" "execute" "$tool_args" 2>&1)
        tool_exit=$?
        echo "$tool_output" > "$output_file"
        echo "$tool_exit" > "$status_file"
    ) &
    local tool_pid=$!
    
    # Wait for process with timeout
    local elapsed=0
    local check_interval=1
    while kill -0 $tool_pid 2>/dev/null; do
        if [ $elapsed -ge $TOOL_TIMEOUT ]; then
            # Timeout reached - kill the process
            kill -TERM $tool_pid 2>/dev/null
            sleep 1
            # Force kill if still running
            kill -KILL $tool_pid 2>/dev/null
            
            log_warn "Tool execution timed out after ${TOOL_TIMEOUT} seconds" >&2
            result="{\"error\": \"Tool execution timed out after ${TOOL_TIMEOUT} seconds (3 minutes)\", \"tool\": \"$tool_name\", \"timeout\": true}"
            exec_status=124
            
            # Cleanup temp files
            rm -f "$output_file" "$status_file"
            
            # Break out of the execution flow
            break
        fi
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    # If not timed out, read the results
    if [ $exec_status -ne 124 ]; then
        wait $tool_pid 2>/dev/null
        
        if [ -f "$output_file" ]; then
            result=$(cat "$output_file" 2>/dev/null)
        else
            result="{\"error\": \"Tool execution failed: no output file\"}"
        fi
        
        if [ -f "$status_file" ]; then
            exec_status=$(cat "$status_file" 2>/dev/null)
        else
            exec_status=1
        fi
        
        # Cleanup temp files
        rm -f "$output_file" "$status_file"
    fi
    
    # Extract and display the meaningful content from JSON result
    local display_output=""
    
    # Try to parse as JSON and extract meaningful fields
    if echo "$result" | jq empty 2>/dev/null; then
        # Valid JSON response
        # Try common output fields in order: output, files, content, matches
        local field_name=""
        local extracted=""
        
        # Try 'output' field first (shell_executor uses this)
        if echo "$result" | jq -e 'has("output")' >/dev/null 2>&1; then
            field_name="output"
            extracted=$(echo "$result" | jq '.output' 2>/dev/null)
        # Try 'files' field (file_operations list uses this)
        elif echo "$result" | jq -e 'has("files")' >/dev/null 2>&1; then
            field_name="files"
            extracted=$(echo "$result" | jq '.files' 2>/dev/null)
        # Try 'content' field (file_operations read uses this)
        elif echo "$result" | jq -e 'has("content")' >/dev/null 2>&1; then
            field_name="content"
            extracted=$(echo "$result" | jq '.content' 2>/dev/null)
        # Try 'matches' field (file_operations grep uses this)
        elif echo "$result" | jq -e 'has("matches")' >/dev/null 2>&1; then
            field_name="matches"
            extracted=$(echo "$result" | jq '.matches' 2>/dev/null)
        fi
        
        # If we extracted a field
        if [ ! -z "$extracted" ] && [ "$extracted" != "null" ]; then
            # Check what type it is
            local field_type=$(echo "$extracted" | jq -r 'type' 2>/dev/null)
            
            case "$field_type" in
                "array")
                    # Array: display each element on a line
                    display_output=$(echo "$extracted" | jq -r '.[]' 2>/dev/null)
                    ;;
                "string")
                    # String: remove quotes and use as-is
                    display_output=$(echo "$extracted" | jq -r '.' 2>/dev/null)
                    ;;
                "object")
                    # Object: pretty print
                    display_output=$(echo "$extracted" | jq -r '.' 2>/dev/null)
                    ;;
                *)
                    # Other types: use as-is
                    display_output=$(echo "$extracted" | jq -r '.' 2>/dev/null)
                    ;;
            esac
        else
            # No recognized field, check for error
            local error_msg=$(echo "$result" | jq -r '.error // empty' 2>/dev/null)
            if [ ! -z "$error_msg" ] && [ "$error_msg" != "empty" ]; then
                display_output="Error: $error_msg"
            else
                # Show whole result as formatted JSON
                display_output=$(echo "$result" | jq '.' 2>/dev/null)
            fi
        fi
    else
        # Not valid JSON, use whole result
        display_output="$result"
    fi
    
    # Display output in scrolling window (to stderr)
    display_scrolling_output "$display_output"
    
    if [ $exec_status -ne 0 ]; then
        log_warn "Tool execution returned non-zero status: $exec_status" >&2
    fi
    
    # Return the actual result to stdout (for API)
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
    # Safety check: ensure context size is within limits
    if [ $CURRENT_CONTEXT_TOKENS -ge $MAX_CONTEXT_TOKENS ]; then
        log_error "Context size ($CURRENT_CONTEXT_TOKENS) exceeds maximum ($MAX_CONTEXT_TOKENS)"
        log_error "Cannot proceed with API call. Please compress context or reduce message history."
        return 1
    fi
    
    local messages=$(build_messages_json)
    
    if [ -z "$messages" ]; then
        log_error "Failed to build messages JSON"
        return 1
    fi
    
    # Validate messages JSON before using it
    if ! echo "$messages" | jq empty 2>/dev/null; then
        log_error "Invalid messages JSON structure"
        log_error "Message count: ${#CONVERSATION_HISTORY[@]}"
        echo "$messages" > "$TEMP_DIR/failed_messages.json"
        log_error "Failed messages saved to: $TEMP_DIR/failed_messages.json"
        
        # Debug: show each message
        log_error "Individual messages:"
        for ((i=0; i<${#CONVERSATION_HISTORY[@]}; i++)); do
            echo "Message $i: ${CONVERSATION_HISTORY[$i]}" | head -c 200
            echo ""
        done
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
        } + (if ($tools | length) > 0 then {tools: $tools, tool_choice: "auto"} else {} end)' 2>&1)
    
    local jq_exit_code=$?
    
    if [ $jq_exit_code -ne 0 ] || [ -z "$payload" ]; then
        log_error "Failed to build request payload (exit code: $jq_exit_code)"
        echo "$payload" > "$TEMP_DIR/failed_payload.txt"
        log_error "Payload output saved to: $TEMP_DIR/failed_payload.txt"
        
        # Also save messages for reference
        echo "$messages" > "$TEMP_DIR/messages_before_payload.json"
        log_error "Messages saved to: $TEMP_DIR/messages_before_payload.json"
        return 1
    fi
    
    # Validate payload is valid JSON
    if ! echo "$payload" | jq empty 2>/dev/null; then
        log_error "Invalid payload JSON structure"
        echo "$payload" > "$TEMP_DIR/invalid_payload.json"
        log_error "Invalid payload saved to: $TEMP_DIR/invalid_payload.json"
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

# Get system information for context
get_system_info() {
    local info="=== System Environment Information ===\n"
    
    # Operating System
    info+="OS: $(uname -s)\n"
    info+="OS Version: $(uname -r)\n"
    
    # Architecture
    info+="Architecture: $(uname -m)\n"
    
    # Shell
    info+="Shell: ${SHELL}\n"
    
    # User
    info+="User: $(whoami)\n"
    info+="Home Directory: ${HOME}\n"
    
    # Current Working Directory
    info+="Current Working Directory: $(pwd)\n"
    
    # Date and Time
    info+="Date: $(date '+%Y-%m-%d %H:%M:%S %Z')\n"
    
    info+="=== End System Information ===\n"
    info+="Please use this information as context for executing commands and understanding the environment.\n\n"
    info+="=== IMPORTANT: Command Execution Best Practices ===\n"
    info+="When using shell_executor or any command execution tools:\n"
    info+="1. ⚠️ AVOID commands that produce massive output or run indefinitely - they can overflow the context window\n"
    info+="2. ✅ ALWAYS use incremental, targeted queries instead of bulk operations\n"
    info+="3. 📊 For large outputs, use these strategies:\n"
    info+="   • Limit lines: pipe to 'head -n N' or 'tail -n N' (e.g., 'ls -la | head -n 50')\n"
    info+="   • Count instead of display: use 'wc -l', 'wc -c', or 'find ... | wc -l'\n"
    info+="   • Filter results: use 'grep' to show only relevant lines\n"
    info+="   • Read sections: use 'sed -n START,ENDp' for specific parts of large files\n"
    info+="   • Summarize: use 'du -sh' instead of 'ls -lR', 'ps aux | grep' instead of full 'ps aux'\n"
    info+="4. 🎯 For file operations:\n"
    info+="   • Check size first: 'wc -l filename' before reading\n"
    info+="   • Read in chunks: if file is large, read specific line ranges\n"
    info+="   • Use targeted tools: 'grep', 'awk', 'sed' to extract what you need\n"
    info+="5. 🔄 For long-running tasks:\n"
    info+="   • Add timeouts or run in background if needed\n"
    info+="   • Check status incrementally rather than waiting for completion\n"
    info+="Remember: Think before executing. Ask yourself 'Will this overflow my context?' If yes, find a smarter way."
    
    echo -e "$info"
}

# Get current task status for system message
get_task_status_message() {
    local task_file="${TEMP_DIR}/tasks.json"
    
    # Check if tasks file exists
    if [ ! -f "$task_file" ]; then
        return 0
    fi
    
    # Read tasks
    local tasks=$(cat "$task_file" 2>/dev/null | jq -r '.tasks // []' 2>/dev/null)
    
    if [ -z "$tasks" ] || [ "$tasks" = "[]" ] || [ "$tasks" = "null" ]; then
        return 0
    fi
    
    local task_count=$(echo "$tasks" | jq 'length' 2>/dev/null)
    
    if [ -z "$task_count" ] || [ "$task_count" -eq 0 ]; then
        return 0
    fi
    
    # Group tasks by status
    local pending=$(echo "$tasks" | jq '[.[] | select(.status == "pending")] | length')
    local in_progress=$(echo "$tasks" | jq '[.[] | select(.status == "in_progress")] | length')
    local completed=$(echo "$tasks" | jq '[.[] | select(.status == "completed")] | length')
    local blocked=$(echo "$tasks" | jq '[.[] | select(.status == "blocked")] | length')
    
    # Build task status message with progress context
    local message="=== Task Execution Status ===\n"
    message+="Progress: $completed/$task_count completed"
    
    if [ $pending -gt 0 ]; then
        message+=" | $pending pending"
    fi
    if [ $in_progress -gt 0 ]; then
        message+=" | $in_progress in progress"
    fi
    if [ $blocked -gt 0 ]; then
        message+=" | $blocked blocked"
    fi
    message+="\n\n"
    
    # List tasks grouped by status
    if [ $in_progress -gt 0 ]; then
        message+="🔄 Currently Working On:\n"
        while read -r task; do
            local id=$(echo "$task" | jq -r '.id')
            local title=$(echo "$task" | jq -r '.title')
            local priority=$(echo "$task" | jq -r '.priority // 3')
            local notes=$(echo "$task" | jq -r '.notes // ""')
            
            message+="  → $title (P$priority)\n"
            if [ ! -z "$notes" ] && [ "$notes" != "null" ] && [ "$notes" != "" ]; then
                message+="    Notes: $notes\n"
            fi
        done < <(echo "$tasks" | jq -c '.[] | select(.status == "in_progress")' 2>/dev/null)
        message+="\n"
    fi
    
    if [ $pending -gt 0 ]; then
        message+="📋 Remaining Tasks:\n"
        while read -r task; do
            local id=$(echo "$task" | jq -r '.id')
            local title=$(echo "$task" | jq -r '.title')
            local priority=$(echo "$task" | jq -r '.priority // 3')
            
            message+="  • $title (P$priority)\n"
        done < <(echo "$tasks" | jq -c '.[] | select(.status == "pending")' 2>/dev/null)
        message+="\n"
    fi
    
    if [ $blocked -gt 0 ]; then
        message+="⚠️  Blocked Tasks:\n"
        while read -r task; do
            local title=$(echo "$task" | jq -r '.title')
            local notes=$(echo "$task" | jq -r '.notes // ""')
            
            message+="  ⊗ $title\n"
            if [ ! -z "$notes" ] && [ "$notes" != "null" ] && [ "$notes" != "" ]; then
                message+="    Reason: $notes\n"
            fi
        done < <(echo "$tasks" | jq -c '.[] | select(.status == "blocked")' 2>/dev/null)
        message+="\n"
    fi
    
    if [ $completed -gt 0 ]; then
        message+="✓ Completed:\n"
        while read -r task; do
            local title=$(echo "$task" | jq -r '.title')
            message+="  ✓ $title\n"
        done < <(echo "$tasks" | jq -c '.[] | select(.status == "completed")' 2>/dev/null)
        message+="\n"
    fi
    
    message+="=== End Task Status ===\n"
    message+="Focus on executing the current task. Only add new tasks if you discover essential steps that were not in the original plan."
    
    echo -e "$message"
}

# Inject task status as system message before API call
inject_task_status() {
    local status_message=$(get_task_status_message)
    
    if [ ! -z "$status_message" ]; then
        # Add system message with task status
        # This will be included in the next API call
        add_message "system" "$status_message"
        log_info "Task status injected into conversation"
    fi
}

# Process a single iteration
process_iteration() {
    CURRENT_ITERATION=$((CURRENT_ITERATION + 1))
    
    if [ $CURRENT_ITERATION -gt $MAX_ITERATIONS ]; then
        log_warn "Maximum iterations ($MAX_ITERATIONS) reached"
        return 1
    fi
    
    log_info "Iteration $CURRENT_ITERATION/$MAX_ITERATIONS"
    
    # Check and compress context if needed (before adding more messages)
    local was_compressed=false
    if [ $CURRENT_CONTEXT_TOKENS -ge $COMPRESSION_THRESHOLD ]; then
        if ! compress_conversation_history; then
            log_error "Failed to compress context within acceptable limits"
            return 1
        fi
        was_compressed=true
    fi
    
    # Inject task status before API call (skip if we just compressed)
    if [ "$was_compressed" = false ]; then
        inject_task_status
    else
        log_info "Skipping task status injection after compression to avoid re-inflating context"
    fi
    
    # Call OpenAI API with thinking animation
    local response_file="$TEMP_DIR/api_response_$$_$CURRENT_ITERATION.tmp"
    local status_file="$TEMP_DIR/api_status_$$_$CURRENT_ITERATION.tmp"
    
    # Start API call in background
    (
        response=$(call_openai_api)
        api_status=$?
        echo "$response" > "$response_file"
        echo "$api_status" > "$status_file"
    ) &
    local api_pid=$!
    
    # Show thinking animation while API call is in progress
    show_thinking_animation $api_pid
    
    # Wait for API call to complete
    wait $api_pid
    
    # Read results
    local response=$(cat "$response_file" 2>/dev/null)
    local api_status=$(cat "$status_file" 2>/dev/null)
    
    # Cleanup temp files
    rm -f "$response_file" "$status_file"
    
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
    
    # Extract and display token usage
    extract_and_display_usage "$response"
    
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
                
                # Check if AI is asking for confirmation (as a fallback when no destructive command was attempted yet)
                local asking_confirmation=false
                if [ "$NEEDS_USER_INPUT" = false ] && [ "$INTERACTIVE_MODE" = false ]; then
                    # Check if the content contains question marks and confirmation-related keywords
                    if echo "$content" | grep -q '?' && echo "$content" | grep -qiE '确认|删除.*吗|可以.*吗|是否|要不要|需要.*确认|请.*告诉我'; then
                        asking_confirmation=true
                        log_info "AI appears to be asking for confirmation"
                    fi
                fi
                
                # In interactive mode, or if tool indicated user input needed, or if AI is asking for confirmation
                if [ "$INTERACTIVE_MODE" = true ] || [ "$NEEDS_USER_INPUT" = true ] || [ "$asking_confirmation" = true ]; then
                    echo ""
                    echo -e "${YELLOW}[USER INPUT]${NC} Please enter your response (or 'exit' to quit):"
                    read -r user_input
                    
                    # Reset the flag
                    NEEDS_USER_INPUT=false
                    
                    if [ "$user_input" = "exit" ] || [ "$user_input" = "quit" ]; then
                        log_info "User requested exit"
                        USER_REQUESTED_EXIT=true
                        return 0
                    fi
                    
                    if [ ! -z "$user_input" ]; then
                        log_info "User: $user_input"
                        
                        # Reset iteration counter for new user input
                        CURRENT_ITERATION=0
                        
                        # Check if user is confirming (use simple pattern matching)
                        if echo "$user_input" | grep -qiE '^(yes|y|ok|sure|confirm|确认|确定|是|是的|对|好|可以|删除|删|同意|执行|继续|proceed)'; then
                            log_success "User confirmed the operation"
                            USER_JUST_CONFIRMED=true
                            # Add a system message to instruct AI
                            add_message "system" "IMPORTANT: User has explicitly confirmed the destructive operation. You are now authorized to retry the previously blocked command with the 'user_confirmed: true' parameter. This is the ONLY time you should use this parameter."
                        fi
                        
                        add_message "user" "$user_input"
                        return 2  # Continue iteration with user's response
                    fi
                fi
            fi
            return 0
            ;;
            
        "tool_calls")
            # Reset the flags at the start of new tool calls iteration
            NEEDS_USER_INPUT=false
            USER_JUST_CONFIRMED=false
            
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
                # Note: arguments is usually a JSON string, not an object
                local tool_args=$(echo "$tool_call" | jq -r '.function.arguments // "{}"' 2>/dev/null)
                
                # If tool_args is empty or null, use empty object
                if [ -z "$tool_args" ] || [ "$tool_args" = "null" ]; then
                    tool_args="{}"
                fi
                
                if [ -z "$call_id" ] || [ -z "$tool_name" ]; then
                    log_error "Invalid tool call format at index $i"
                    continue
                fi
                
                # Execute tool (it will display its own header with parameters)
                local tool_result=$(execute_tool "$tool_name" "$tool_args")
                local tool_status=$?
                
                if [ $tool_status -ne 0 ]; then
                    log_warn "Tool execution failed with status $tool_status"
                fi
                
                # Check if tool result indicates user input is needed
                local cancelled=$(echo "$tool_result" | jq -r '.cancelled // false' 2>/dev/null)
                local reason=$(echo "$tool_result" | jq -r '.reason // ""' 2>/dev/null)
                
                if [ "$cancelled" = "true" ] && [ "$reason" = "destructive_command_not_confirmed" ]; then
                    NEEDS_USER_INPUT=true
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
    
    # Add system information as context at the beginning
    local system_info=$(get_system_info)
    add_message "system" "$system_info"
    log_info "System information injected into conversation"
    
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

# Interactive conversation mode
run_interactive() {
    local initial_query="$1"
    
    INTERACTIVE_MODE=true
    
    log_info "Starting Interactive Mode"
    log_info "Type 'exit' or 'quit' to end the session"
    
    # Add system information as context at the beginning
    local system_info=$(get_system_info)
    add_message "system" "$system_info"
    log_info "System information injected into conversation"
    
    # Process initial query if provided
    if [ ! -z "$initial_query" ]; then
        # Reset iteration counter for new user query
        CURRENT_ITERATION=0
        
        add_message "user" "$initial_query"
        log_info "Query: $initial_query"
        
        # Run iteration loop
        while true; do
            process_iteration
            local status=$?
            
            if [ $status -eq 0 ]; then
                # Task completed or user exited
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
        
        # If user requested exit during initial query processing, don't continue to prompt loop
        if [ "$USER_REQUESTED_EXIT" = true ]; then
            log_success "Interactive session ended"
            return
        fi
    fi
    
    # Continue with interactive prompt loop (only if no initial query, or initial query didn't exit)
    if [ -z "$initial_query" ] || [ "$USER_REQUESTED_EXIT" = false ]; then
        # No initial query, start with prompt
        while true; do
            echo -e "${YELLOW}[USER INPUT]${NC} Please enter your query (or 'exit' to quit):"
            read -r user_input
            
            if [ "$user_input" = "exit" ] || [ "$user_input" = "quit" ]; then
                log_info "User requested exit"
                break
            fi
            
            if [ -z "$user_input" ]; then
                log_warn "Empty input, please enter a query"
                continue
            fi
            
            # Reset iteration counter for new user query
            CURRENT_ITERATION=0
            
            add_message "user" "$user_input"
            log_info "Query: $user_input"
            
            # Run iteration loop for this query
            while true; do
                process_iteration
                local status=$?
                
                if [ $status -eq 0 ]; then
                    # Task completed, back to user input
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
            
            # Check if user requested exit during the iteration
            if [ "$USER_REQUESTED_EXIT" = true ]; then
                break
            fi
        done
    fi
    
    log_success "Interactive session ended"
}

################################################################################
# CLI Interface
################################################################################

show_help() {
    cat << EOF
Killer.sh - A Perfect Shell-Based AI Agent

Usage: $0 [OPTIONS] <command|query>

Commands:
    <query>                      Run the agent with a query (one-time execution)
    - <query>                    Start interactive mode with initial query
    -                            Start interactive mode without initial query
    <prompt-name> <query>        Run with a specific prompt template (one-time)
    <prompt-name> - [query]      Run with prompt template in interactive mode
    list-prompts                 List available prompts
    list-tools                   List available tools
    setup                        Interactive configuration setup
    help                         Show this help message

Interactive Mode:
    In interactive mode, the agent will wait for your responses after each reply.
    This is useful for multi-turn conversations and confirming destructive operations.
    Type 'exit' or 'quit' at any prompt to end the session.

Examples:
    $0 "list files in current directory"          # One-time execution
    $0 - "delete old log files"                    # Interactive mode with query
    $0 -                                           # Start interactive session
    $0 satire "你是谁"                              # One-time with prompt
    $0 satire - "你是谁"                            # Interactive with prompt

Options:
    --model <model>              Set GLM model (default: glm-4.6)
    --max-iterations <n>         Set maximum iterations (default: 50)
    --api-url <url>              Set custom API URL (default: https://open.bigmodel.cn/api/coding/paas/v4)
    --max-context <n>            Set maximum context tokens (default: 16000)
    --compression-threshold <n>  Set compression threshold (default: 12000)
    --tool-timeout <n>           Set tool execution timeout in seconds (default: 180)
    --min-messages <n>           Set minimum messages to keep (default: 10)
    --setup                      Run interactive configuration setup

Environment Variables:
    GLM_CODING_API_KEY          GLM Coding API key (required)
    GLM_CODING_MODEL            Default model to use
    GLM_CODING_API_BASE         Custom API URL
    MAX_ITERATIONS              Maximum iteration count
    MAX_CONTEXT_TOKENS          Maximum context size (default: 204800)
    COMPRESSION_THRESHOLD       Token count to trigger compression (default: 184320)
    TOOL_TIMEOUT                Tool execution timeout in seconds (default: 180)
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
            --max-context)
                MAX_CONTEXT_TOKENS="$2"
                shift 2
                ;;
            --compression-threshold)
                COMPRESSION_THRESHOLD="$2"
                shift 2
                ;;
            --tool-timeout)
                TOOL_TIMEOUT="$2"
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
            -)
                # Interactive mode
                check_dependencies
                check_api_key
                init_dirs
                init_tools
                
                if [ ! -z "$2" ]; then
                    # Interactive mode with initial query: killer - "query"
                    run_interactive "$2"
                else
                    # Interactive mode without initial query: killer -
                    run_interactive ""
                fi
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
                    
                    check_dependencies
                    check_api_key
                    init_tools
                    
                    local prompt_content=$(load_prompt "$1")
                    if [ $? -ne 0 ]; then
                        exit 1
                    fi
                    
                    # Add system message with prompt
                    add_message "system" "$prompt_content"
                    
                    # Check if second argument is "-" for interactive mode
                    if [ "$2" = "-" ]; then
                        # Interactive mode with prompt: killer.sh <prompt-name> - [initial-query]
                        if [ ! -z "$3" ]; then
                            run_interactive "$3"
                        else
                            run_interactive ""
                        fi
                        exit 0
                    else
                        # Use as prompt command: killer.sh <prompt-name> <query>
                        run_agent "$2"
                        exit 0
                    fi
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

