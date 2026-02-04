#!/bin/bash
# Wrapper Script Template for aqsh
# This script executes another script and handles logs/results correctly

# === Configuration ===
SCRIPT_DIR="/path/to/script/directory"    # Directory to cd into
SCRIPT_NAME="your-script.sh"               # Script filename

# === Main Execution ===
echo "=== Wrapper Script Started ==="
echo "Task ID: $AQSH_TASK_ID"
echo "Working directory: $SCRIPT_DIR"
echo "Script: $SCRIPT_NAME"
echo "Parameters: PARAM1=$PARAM1, PARAM2=$PARAM2, PARAM3=$PARAM3"

# Change to script directory (for legacy scripts that need specific pwd)
cd "$SCRIPT_DIR" || { echo "ERROR: Cannot cd to $SCRIPT_DIR"; exit 1; }
echo "Changed to directory: $(pwd)"

# Execute sub-script with positional arguments
# stdout/stderr automatically goes to aqsh logs
set +e
./"$SCRIPT_NAME" "$PARAM1" "$PARAM2" "$PARAM3"
EXIT_CODE=$?
set -e

echo "=== Script finished with exit code: $EXIT_CODE ==="

# Write result data (optional - for structured output)
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

# Return correct exit code to aqsh
# exit 0 = task completed, exit non-zero = task failed (may retry)
exit $EXIT_CODE
