#!/bin/bash

################################################################################
# Task Planner Tool
# Manages task lists for complex multi-step operations
################################################################################

TOOL_NAME="task_planner"
TOOL_DESCRIPTION="Manage task lists for planning and tracking complex operations"

# Use temp directory for task storage
get_task_file() {
    local temp_dir="${TEMP_DIR:-/tmp/killer}"
    mkdir -p "$temp_dir"
    echo "$temp_dir/tasks.json"
}

get_definition() {
    cat << 'EOF'
{
    "type": "function",
    "function": {
        "name": "task_planner",
        "description": "Manage task lists for planning and tracking complex operations. IMPORTANT: For complex tasks (3+ steps), create a COMPLETE task plan at the start before execution. Then execute tasks one by one, updating their status. Only add new tasks if you discover essential steps missing from the original plan. Use this to break down complex tasks, track progress, and maintain focus. Supports batch operations only.",
        "parameters": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["list", "batch_add", "batch_update", "batch_delete"],
                    "description": "Action: list (show all tasks), batch_add (add multiple tasks), batch_update (update multiple tasks), batch_delete (delete multiple tasks)"
                },
                "tasks": {
                    "type": "array",
                    "description": "Array of tasks for batch operations. For batch_add: {title (required), status, notes, priority}. For batch_update: {task_id (required), title, status, notes, priority}. For batch_delete: {task_id (required)}",
                    "items": {
                        "type": "object",
                        "properties": {
                            "task_id": {
                                "type": "string",
                                "description": "Task ID (required for batch_update and batch_delete)"
                            },
                            "title": {
                                "type": "string",
                                "description": "Task title (required for batch_add, optional for batch_update)"
                            },
                            "status": {
                                "type": "string",
                                "enum": ["pending", "in_progress", "completed", "blocked"],
                                "description": "Task status (optional for batch_add/batch_update)"
                            },
                            "notes": {
                                "type": "string",
                                "description": "Task notes (optional for batch_add/batch_update)"
                            },
                            "priority": {
                                "type": "integer",
                                "description": "Task priority 1-5 (optional for batch_add/batch_update)"
                            }
                        }
                    }
                }
            },
            "required": ["action"]
        }
    }
}
EOF
}

# Initialize tasks file if not exists
init_tasks() {
    local task_file=$(get_task_file)
    if [ ! -f "$task_file" ]; then
        echo '{"tasks": []}' > "$task_file"
    fi
}

# List all tasks
list_tasks() {
    local task_file=$(get_task_file)
    init_tasks
    
    local tasks=$(cat "$task_file" | jq -r '.tasks')
    local count=$(echo "$tasks" | jq 'length')
    
    cat << EOF
{
    "success": true,
    "action": "list",
    "task_count": $count,
    "tasks": $tasks
}
EOF
}

# Batch add tasks
batch_add_tasks() {
    local tasks_json="$1"
    
    if [ -z "$tasks_json" ] || [ "$tasks_json" = "null" ]; then
        cat << EOF
{
    "success": false,
    "error": "Tasks array is required for batch_add"
}
EOF
        return 1
    fi
    
    local task_file=$(get_task_file)
    init_tasks
    
    local added_tasks="[]"
    local count=0
    local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Process each task in the array
    local task_count=$(echo "$tasks_json" | jq 'length' 2>/dev/null)
    
    for ((i=0; i<task_count; i++)); do
        local task=$(echo "$tasks_json" | jq ".[$i]" 2>/dev/null)
        local title=$(echo "$task" | jq -r '.title // empty')
        local status=$(echo "$task" | jq -r '.status // "pending"')
        local notes=$(echo "$task" | jq -r '.notes // ""')
        local priority=$(echo "$task" | jq -r '.priority // 3')
        
        if [ -z "$title" ]; then
            continue
        fi
        
        # Generate unique task ID
        local task_id="task_$(date +%s)_$$_$i"
        
        # Create new task object
        local new_task=$(jq -n \
            --arg id "$task_id" \
            --arg title "$title" \
            --arg status "$status" \
            --arg notes "$notes" \
            --arg created "$created_at" \
            --arg priority "$priority" \
            '{
                id: $id,
                title: $title,
                status: $status,
                notes: $notes,
                priority: ($priority | tonumber),
                created_at: $created,
                updated_at: $created
            }')
        
        # Add task to file
        local updated=$(cat "$task_file" | jq --argjson task "$new_task" '.tasks += [$task]')
        echo "$updated" > "$task_file"
        
        # Add to result array
        added_tasks=$(echo "$added_tasks" | jq --argjson task "$new_task" '. += [$task]')
        count=$((count + 1))
    done
    
    cat << EOF
{
    "success": true,
    "action": "batch_add",
    "added_count": $count,
    "tasks": $added_tasks
}
EOF
}

# Batch update tasks
batch_update_tasks() {
    local updates_json="$1"
    
    if [ -z "$updates_json" ] || [ "$updates_json" = "null" ]; then
        cat << EOF
{
    "success": false,
    "error": "Tasks array is required for batch_update"
}
EOF
        return 1
    fi
    
    local task_file=$(get_task_file)
    init_tasks
    
    local updated_tasks="[]"
    local count=0
    local updated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Process each update in the array
    local update_count=$(echo "$updates_json" | jq 'length' 2>/dev/null)
    
    for ((i=0; i<update_count; i++)); do
        local update=$(echo "$updates_json" | jq ".[$i]" 2>/dev/null)
        local task_id=$(echo "$update" | jq -r '.task_id // empty')
        
        if [ -z "$task_id" ]; then
            continue
        fi
        
        # Check if task exists
        local task_exists=$(cat "$task_file" | jq --arg id "$task_id" '.tasks | map(select(.id == $id)) | length')
        
        if [ "$task_exists" -eq 0 ]; then
            continue
        fi
        
        # Build update expression
        local title=$(echo "$update" | jq -r '.title // null')
        local status=$(echo "$update" | jq -r '.status // null')
        local notes=$(echo "$update" | jq -r '.notes // null')
        local priority=$(echo "$update" | jq -r '.priority // null')
        
        # Update task
        local current_file=$(cat "$task_file")
        local new_file=$(echo "$current_file" | jq --arg id "$task_id" \
            --arg title "$title" \
            --arg status "$status" \
            --arg notes "$notes" \
            --arg priority "$priority" \
            --arg updated "$updated_at" \
            '.tasks = [.tasks[] | if .id == $id then 
                . + {updated_at: $updated} +
                (if $title != "null" then {title: $title} else {} end) +
                (if $status != "null" then {status: $status} else {} end) +
                (if $notes != "null" then {notes: $notes} else {} end) +
                (if $priority != "null" then {priority: ($priority | tonumber)} else {} end)
            else . end]')
        
        echo "$new_file" > "$task_file"
        
        # Get updated task
        local updated_task=$(echo "$new_file" | jq --arg id "$task_id" '.tasks[] | select(.id == $id)')
        updated_tasks=$(echo "$updated_tasks" | jq --argjson task "$updated_task" '. += [$task]')
        count=$((count + 1))
    done
    
    cat << EOF
{
    "success": true,
    "action": "batch_update",
    "updated_count": $count,
    "tasks": $updated_tasks
}
EOF
}

# Batch delete tasks
batch_delete_tasks() {
    local ids_json="$1"
    
    if [ -z "$ids_json" ] || [ "$ids_json" = "null" ]; then
        cat << EOF
{
    "success": false,
    "error": "Tasks array is required for batch_delete"
}
EOF
        return 1
    fi
    
    local task_file=$(get_task_file)
    init_tasks
    
    local deleted_tasks="[]"
    local count=0
    
    # Process each ID in the array
    local id_count=$(echo "$ids_json" | jq 'length' 2>/dev/null)
    
    for ((i=0; i<id_count; i++)); do
        local task_obj=$(echo "$ids_json" | jq ".[$i]" 2>/dev/null)
        local task_id=$(echo "$task_obj" | jq -r '.task_id // empty')
        
        if [ -z "$task_id" ]; then
            continue
        fi
        
        # Get task before deletion
        local task=$(cat "$task_file" | jq --arg id "$task_id" '.tasks[] | select(.id == $id)')
        
        if [ -z "$task" ] || [ "$task" = "null" ]; then
            continue
        fi
        
        # Remove task
        local updated=$(cat "$task_file" | jq --arg id "$task_id" '.tasks = [.tasks[] | select(.id != $id)]')
        echo "$updated" > "$task_file"
        
        deleted_tasks=$(echo "$deleted_tasks" | jq --argjson task "$task" '. += [$task]')
        count=$((count + 1))
    done
    
    cat << EOF
{
    "success": true,
    "action": "batch_delete",
    "deleted_count": $count,
    "tasks": $deleted_tasks
}
EOF
}

execute() {
    local args="$1"
    local action=$(echo "$args" | jq -r '.action')
    
    case "$action" in
        list)
            list_tasks
            ;;
        batch_add)
            local tasks=$(echo "$args" | jq -c '.tasks')
            batch_add_tasks "$tasks"
            ;;
        batch_update)
            local tasks=$(echo "$args" | jq -c '.tasks')
            batch_update_tasks "$tasks"
            ;;
        batch_delete)
            local tasks=$(echo "$args" | jq -c '.tasks')
            batch_delete_tasks "$tasks"
            ;;
        *)
            cat << EOF
{
    "success": false,
    "error": "Invalid action: $action. Must be one of: list, batch_add, batch_update, batch_delete"
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

