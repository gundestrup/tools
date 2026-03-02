# ERC Course Scraper - Upload Options

The script now supports multiple upload methods: **FTP**, **SFTP**, **SCP**, and **rsync**.

## Quick Start

### Using FTP (default)
```bash
./run_erc_scraper.sh
```

### Using SFTP
```bash
UPLOAD_METHOD=sftp ./run_erc_scraper.sh
```

### Using SCP
```bash
UPLOAD_METHOD=scp ./run_erc_scraper.sh
```

### Using rsync
```bash
UPLOAD_METHOD=rsync ./run_erc_scraper.sh
```

## Configuration

Edit the variables at the top of `run_erc_scraper.sh`:

```bash
# Choose upload method
UPLOAD_METHOD="ftp"  # Options: ftp, sftp, scp, rsync

# FTP settings
FTP_USER='your_username'
FTP_PASS='your_password'
FTP_HOST='ftp.example.com'
FTP_REMOTE_PATH='/'

# SSH settings (for sftp/scp/rsync)
SSH_USER='your_username'
SSH_HOST='ssh.example.com'
SSH_PORT='22'
SSH_REMOTE_PATH='/var/www/html'
SSH_KEY="$HOME/.ssh/id_rsa"
```

## Upload Methods Comparison

| Method | Security | Speed | Resume Support | Best For |
|--------|----------|-------|----------------|----------|
| **FTP** | ❌ Low | Fast | ✅ Yes | Legacy systems |
| **SFTP** | ✅ High | Medium | ✅ Yes | Secure file transfer |
| **SCP** | ✅ High | Fast | ❌ No | Quick secure copy |
| **rsync** | ✅ High | Very Fast | ✅ Yes | Incremental updates |

## Authentication Methods

### 1. Password Authentication (requires sshpass)

Install sshpass:
```bash
# Ubuntu/Debian
sudo apt-get install sshpass

# macOS (via Homebrew)
brew install hudochenkov/sshpass/sshpass

# CentOS/RHEL
sudo yum install sshpass
```

The script will automatically use password auth if `sshpass` is available.

### 2. SSH Key Authentication (recommended)

Generate SSH key pair:
```bash
ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
```

Copy public key to server:
```bash
ssh-copy-id -i ~/.ssh/id_rsa.pub user@hostname
```

Update the script to use your key:
```bash
SSH_KEY="$HOME/.ssh/id_rsa"
```

## Environment Variables

You can override settings via environment variables:

```bash
# Change upload method
export UPLOAD_METHOD=sftp

# Override SSH settings
export SSH_USER=myuser
export SSH_HOST=myserver.com
export SSH_PORT=2222
export SSH_REMOTE_PATH=/home/myuser/public_html
export SSH_KEY=/path/to/custom/key

# Run script
./run_erc_scraper.sh
```

## Security Best Practices

### ⚠️ Current Setup (Less Secure)
- Credentials hardcoded in script
- Visible in process list (`ps aux`)

### ✅ Recommended Setup

#### Option 1: Use SSH Keys (Best)
```bash
# Generate key
ssh-keygen -t ed25519 -C "erc-scraper"

# Copy to server
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server

# Update script
SSH_KEY="$HOME/.ssh/id_ed25519"
```

#### Option 2: Use Environment File
Create `.env` file (don't commit to version control):
```bash
FTP_USER=myuser
FTP_PASS=mypassword
FTP_HOST=ftp.example.com
```

Source it in script:
```bash
# Add to run_erc_scraper.sh
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi
```

#### Option 3: Use .netrc for FTP
Create `~/.netrc`:
```
machine ftp.example.com
login myuser
password mypassword
```

Set permissions:
```bash
chmod 600 ~/.netrc
```

## Troubleshooting

### SFTP: "Permission denied"
```bash
# Check SSH key permissions
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub

# Test connection
sftp -i ~/.ssh/id_rsa user@host
```

### SCP: "Host key verification failed"
```bash
# Add host to known_hosts
ssh-keyscan -H hostname >> ~/.ssh/known_hosts
```

### rsync: "command not found"
```bash
# Install rsync
sudo apt-get install rsync  # Ubuntu/Debian
sudo yum install rsync      # CentOS/RHEL
brew install rsync          # macOS
```

### FTP: "wput: command not found"
```bash
# Install wput
sudo apt-get install wput   # Ubuntu/Debian
brew install wput           # macOS
```

## Cron Job Examples

### Daily at 6 AM using SFTP
```bash
0 6 * * * cd /home/svend/erc_course && UPLOAD_METHOD=sftp ./run_erc_scraper.sh >> scraper.log 2>&1
```

### Every 12 hours using rsync
```bash
0 */12 * * * cd /home/svend/erc_course && UPLOAD_METHOD=rsync ./run_erc_scraper.sh >> scraper.log 2>&1
```

## Testing Upload Methods

Test each method manually:

```bash
# Test FTP
UPLOAD_METHOD=ftp ./run_erc_scraper.sh

# Test SFTP with password
UPLOAD_METHOD=sftp ./run_erc_scraper.sh

# Test SCP with SSH key
UPLOAD_METHOD=scp SSH_KEY=~/.ssh/id_rsa ./run_erc_scraper.sh

# Test rsync
UPLOAD_METHOD=rsync ./run_erc_scraper.sh
```

## Migration Guide

### From FTP to SFTP

1. **Set up SSH key on server**
2. **Test SFTP connection:**
   ```bash
   sftp user@hostname
   ```
3. **Update script:**
   ```bash
   UPLOAD_METHOD=sftp
   SSH_USER=your_user
   SSH_HOST=your_host
   SSH_REMOTE_PATH=/path/to/upload
   ```
4. **Test upload:**
   ```bash
   UPLOAD_METHOD=sftp ./run_erc_scraper.sh
   ```

### From FTP to rsync (fastest for repeated uploads)

1. **Install rsync on both client and server**
2. **Set up SSH key authentication**
3. **Update script:**
   ```bash
   UPLOAD_METHOD=rsync
   ```
4. **First run will upload full file, subsequent runs only transfer changes**

## Performance Tips

- **Use rsync** for repeated uploads (only transfers differences)
- **Use SCP** for one-time fast transfers
- **Use SFTP** for interactive file management
- **Avoid FTP** unless required by legacy systems

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Verify credentials and paths are correct
3. Test connection manually before running script
4. Check server logs for authentication issues
