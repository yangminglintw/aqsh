#!/bin/bash
# Standalone Wrapper Script Template
# Generic 3-step wrapper: env setup → pre-script → main script

# === Configuration ===
# Environment setup (optional - use absolute paths, leave empty to skip)
ENV_SOURCE_SCRIPT="/path/to/env/env-setup.sh"   # Script to source (sets env vars)
PRE_SCRIPT="/path/to/pre/pre-script.sh"         # Pre-execution script (optional)

# Main script configuration
SCRIPT_DIR="/path/to/script/directory"    # Directory to cd into for main script
SCRIPT_NAME="your-script.sh"              # Main script filename

# === Main Execution ===
echo "=== Wrapper Script Started ==="
echo "Parameters: PARAM1=$PARAM1, PARAM2=$PARAM2, PARAM3=$PARAM3"

# --- Step 1: Source Environment Script (absolute path) ---
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

# --- Step 2: Pre-execution Script (absolute path, optional) ---
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

# --- Step 3: Main Script Execution ---
echo "--- Main Script Execution ---"
cd "$SCRIPT_DIR" || { echo "ERROR: Cannot cd to $SCRIPT_DIR"; exit 1; }
echo "Changed to script directory: $(pwd)"
echo "Executing: $SCRIPT_NAME"

set +e
./"$SCRIPT_NAME" "$PARAM1" "$PARAM2" "$PARAM3"
EXIT_CODE=$?
set -e

echo "=== Script finished with exit code: $EXIT_CODE ==="
exit $EXIT_CODE
