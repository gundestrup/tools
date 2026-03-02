#!/bin/bash
set -euo pipefail

# Configuration
SCRIPT_DIR="/home/svend/erc_course"
OUTPUT_FILE="erc_courses.xml"

# Default upload method (set to empty string to always prompt)
# Options: ftp, sftp, scp, rsync, or leave empty to prompt
DEFAULT_UPLOAD_METHOD="ftp"

# Upload method: use environment variable, default, or prompt
UPLOAD_METHOD="${UPLOAD_METHOD:-}"

# FTP/SFTP credentials
FTP_USER='some_login_d'
FTP_PASS='come passrd'
FTP_HOST='ftp.url.login.net'
FTP_REMOTE_PATH='/'  # Remote directory path

# SFTP/SCP/SSH settings
SSH_USER="${SSH_USER:-$FTP_USER}"
SSH_HOST="${SSH_HOST:-$FTP_HOST}"
SSH_PORT="${SSH_PORT:-22}"
SSH_REMOTE_PATH="${SSH_REMOTE_PATH:-/var/www/html}"  # Adjust as needed
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"  # SSH key path

# Function to prompt for upload method
prompt_upload_method() {
    # Check if running interactively (not in cron)
    if [ -t 0 ]; then
        echo ""
        echo "Select upload method:"
        echo "  1) FTP (legacy, insecure)"
        echo "  2) SFTP (secure, recommended)"
        echo "  3) SCP (secure, fast)"
        echo "  4) rsync (secure, efficient for repeated uploads)"
        echo ""
        read -p "Enter choice [1-4]: " choice
        
        case "$choice" in
            1) UPLOAD_METHOD="ftp" ;;
            2) UPLOAD_METHOD="sftp" ;;
            3) UPLOAD_METHOD="scp" ;;
            4) UPLOAD_METHOD="rsync" ;;
            *)
                echo "Invalid choice. Using default: $DEFAULT_UPLOAD_METHOD"
                UPLOAD_METHOD="$DEFAULT_UPLOAD_METHOD"
                ;;
        esac
        
        echo "Using upload method: $UPLOAD_METHOD"
        echo ""
    else
        # Non-interactive (cron), use default
        UPLOAD_METHOD="$DEFAULT_UPLOAD_METHOD"
        echo "Non-interactive mode: using default upload method: $UPLOAD_METHOD"
    fi
}

# Determine upload method
if [ -z "$UPLOAD_METHOD" ]; then
    # No environment variable set
    if [ -n "$DEFAULT_UPLOAD_METHOD" ]; then
        # Default is set, check if interactive
        if [ -t 0 ]; then
            # Interactive: ask user
            prompt_upload_method
        else
            # Non-interactive (cron): use default
            UPLOAD_METHOD="$DEFAULT_UPLOAD_METHOD"
            echo "Using default upload method: $UPLOAD_METHOD"
        fi
    else
        # No default set, must prompt (or fail in cron)
        if [ -t 0 ]; then
            prompt_upload_method
        else
            echo "Error: No upload method specified and no default set"
            echo "Set DEFAULT_UPLOAD_METHOD in script or use UPLOAD_METHOD environment variable"
            exit 1
        fi
    fi
else
    echo "Using upload method from environment: $UPLOAD_METHOD"
fi

# Update code repository
echo "Updating repository..."
cd "$SCRIPT_DIR"
svn update || { echo "SVN update failed"; exit 1; }

# Run the scraper
echo "Running ERC course scraper..."
ruby erc_course.rb || { echo "Scraper failed"; exit 1; }

# Verify output file was created
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: $OUTPUT_FILE was not generated"
    exit 1
fi

# Upload function
upload_file() {
    case "$UPLOAD_METHOD" in
        ftp)
            echo "Uploading via FTP..."
            wput --disable-tls --binary --reupload --verbose "$OUTPUT_FILE" \
                "ftp://$FTP_USER:$FTP_PASS@$FTP_HOST$FTP_REMOTE_PATH" || return 1
            ;;
            
        sftp)
            echo "Uploading via SFTP..."
            # Option 1: Using password (requires sshpass)
            if command -v sshpass &> /dev/null && [ -n "$FTP_PASS" ]; then
                sshpass -p "$FTP_PASS" sftp -P "$SSH_PORT" -o StrictHostKeyChecking=no \
                    "$SSH_USER@$SSH_HOST" <<EOF
cd $SSH_REMOTE_PATH
put $OUTPUT_FILE
bye
EOF
            # Option 2: Using SSH key (recommended)
            elif [ -f "$SSH_KEY" ]; then
                sftp -P "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no \
                    "$SSH_USER@$SSH_HOST" <<EOF
cd $SSH_REMOTE_PATH
put $OUTPUT_FILE
bye
EOF
            else
                echo "Error: Neither sshpass nor SSH key found for SFTP"
                return 1
            fi
            ;;
            
        scp)
            echo "Uploading via SCP..."
            # Option 1: Using password (requires sshpass)
            if command -v sshpass &> /dev/null && [ -n "$FTP_PASS" ]; then
                sshpass -p "$FTP_PASS" scp -P "$SSH_PORT" -o StrictHostKeyChecking=no \
                    "$OUTPUT_FILE" "$SSH_USER@$SSH_HOST:$SSH_REMOTE_PATH/" || return 1
            # Option 2: Using SSH key (recommended)
            elif [ -f "$SSH_KEY" ]; then
                scp -P "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no \
                    "$OUTPUT_FILE" "$SSH_USER@$SSH_HOST:$SSH_REMOTE_PATH/" || return 1
            else
                echo "Error: Neither sshpass nor SSH key found for SCP"
                return 1
            fi
            ;;
            
        rsync)
            echo "Uploading via rsync over SSH..."
            # Option 1: Using password (requires sshpass)
            if command -v sshpass &> /dev/null && [ -n "$FTP_PASS" ]; then
                sshpass -p "$FTP_PASS" rsync -avz -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
                    "$OUTPUT_FILE" "$SSH_USER@$SSH_HOST:$SSH_REMOTE_PATH/" || return 1
            # Option 2: Using SSH key (recommended)
            elif [ -f "$SSH_KEY" ]; then
                rsync -avz -e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no" \
                    "$OUTPUT_FILE" "$SSH_USER@$SSH_HOST:$SSH_REMOTE_PATH/" || return 1
            else
                echo "Error: Neither sshpass nor SSH key found for rsync"
                return 1
            fi
            ;;
            
        *)
            echo "Error: Unknown upload method '$UPLOAD_METHOD'"
            echo "Valid options: ftp, sftp, scp, rsync"
            return 1
            ;;
    esac
}

# Perform upload
upload_file || {
    echo "Upload failed"
    exit 1
}

echo "RSS feed updated successfully via $UPLOAD_METHOD at $(date)"
