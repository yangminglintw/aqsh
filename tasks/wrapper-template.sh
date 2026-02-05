#!/bin/bash
# Wrapper Script Template for aqsh
# This script handles environment setup and executes another script

# === Resolve script directory ===
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${WRAPPER_DIR}/.." && pwd)"

# === Configuration ===
# Environment setup (optional - absolute or relative to PROJECT_ROOT, leave empty to skip)
ENV_SOURCE_SCRIPT="${PROJECT_ROOT}/scripts/env-setup.sh"   # Script to source (sets env vars)
PRE_SCRIPT="${PROJECT_ROOT}/scripts/pre-script.sh"         # Pre-execution script (optional)

# Main script configuration
SCRIPT_DIR="${PROJECT_ROOT}/scripts"       # Directory to cd into for main script
SCRIPT_NAME="your-script.sh"              # Main script filename

# === Main Execution ===
echo "=== Wrapper Script Started ==="
echo "Task ID: $AQSH_TASK_ID"
echo "Parameters: PARAM1=$PARAM1, PARAM2=$PARAM2, PARAM3=$PARAM3"

# --- Step 1: Source Environment Script ---
if [ -n "$ENV_SOURCE_SCRIPT" ]; then
    echo "--- Environment Setup ---"
    if [ -f "$ENV_SOURCE_SCRIPT" ]; then
        echo "Sourcing: $ENV_SOURCE_SCRIPT"
        source "$ENV_SOURCE_SCRIPT"
    else
        echo "ERROR: Source script not found: $ENV_SOURCE_SCRIPT"
        exit 1
    fi
fi

# --- Step 2: Pre-execution Script (optional) ---
if [ -n "$PRE_SCRIPT" ]; then
    echo "--- Running Pre-script ---"
    if [ -f "$PRE_SCRIPT" ]; then
        echo "Executing: $PRE_SCRIPT"
        "$PRE_SCRIPT"
        PRE_EXIT=$?
        if [ $PRE_EXIT -ne 0 ]; then
            echo "ERROR: Pre-script failed with exit code: $PRE_EXIT"
            exit $PRE_EXIT
        fi
    else
        echo "ERROR: Pre-script not found: $PRE_SCRIPT"
        exit 1
    fi
fi

# --- Step 3: Main Script Execution (needs cd for legacy scripts) ---
echo "--- Main Script Execution ---"
cd "$SCRIPT_DIR" || { echo "ERROR: Cannot cd to $SCRIPT_DIR"; exit 1; }
echo "Changed to script directory: $(pwd)"
echo "Executing: $SCRIPT_NAME"

set +e
./"$SCRIPT_NAME" "$PARAM1" "$PARAM2" "$PARAM3"
EXIT_CODE=$?
set -e

echo "=== Script finished with exit code: $EXIT_CODE ==="

# --- Write Result ---
if [ $EXIT_CODE -eq 0 ]; then
    RESULT_STATUS="success"
else
    RESULT_STATUS="failed"
fi

cat > "$AQSH_RESULT_FILE" << EOF
{
  "status": "$RESULT_STATUS",
  "script": "$SCRIPT_DIR/$SCRIPT_NAME",
  "exit_code": $EXIT_CODE,
  "timestamp": "$(date -Iseconds)"
}
EOF

exit $EXIT_CODE
