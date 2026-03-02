## CloneCD Batch Converter Script

**File:** [clonecd_batch_help.rb](clonecd_batch_help.rb)

A Ruby script that intelligently batch converts CloneCD image sets to ISO files with comprehensive logging and resume capability.

### Features

#### Smart CD Type Detection
- **Pure Data CDs**: Converts to `.iso` format (mountable)
- **Pure Audio CDs**: Skipped - already in optimal format (`.img` + `.cue`)
- **Mixed-Mode CDs**: Skipped - preserves both data and audio tracks in original format

#### Interactive Workflow
1. **Discovery Phase**: Scans directory for CloneCD images and classifies by type
2. **Scope Selection**: Choose to convert all files (recursive) or current directory only
3. **Existing ISO Handling**: If ISOs already exist, choose to skip or reconvert
4. **Progress Tracking**: Real-time conversion progress with percentage complete

#### File Handling
- **Input formats**: `.ccd`, `.img`, `.sub`, `.cue` files
- **Supported modes**: `MODE1/2352`, `MODE2/2352`
- **Output**: `.iso` files placed in same directory as source files
- **Preservation**: Never modifies original `.img`, `.sub`, or `.ccd` files

#### CUE File Management
- Analyzes `.cue` files against `.ccd` metadata
- If `.cue` is improperly defined:
  - Renames existing `.cue` to `.cue.org`
  - Generates proper `.cue` file from `.ccd` data
- If no `.ccd` exists, parses `.cue` file for track information

#### Performance
- **Parallel processing**: Uses multiple worker threads (default: CPU cores - 1)
- **Configurable workers**: Adjust with `-w` flag

#### Logging & Resume Capability
- **Log file**: `clonecd_batch.log` created in input directory
- **Comprehensive tracking**:
  - Session start/end with parameters
  - All discovered files and their types
  - User choices (scope, force reconvert)
  - Conversion queue and progress
  - Success/failure status for each file
  - Output file sizes
  - Final statistics and summary
  - List of skipped files (audio and mixed-mode)
- **Resume support**: Run script again to skip already-converted files

#### Statistics Summary
- Total files queued and converted
- Success/failure counts
- Time elapsed and average time per image
- Total size processed
- Detailed list of skipped files by category

### Requirements

- Ruby (tested with 3.x)
- `bchunk` - Install via Homebrew: `brew install bchunk`

### Usage

```bash
ruby clonecd_batch_help.rb INPUT_DIR [options]
```

#### Options

- `-wN`, `--workers=N` - Number of parallel workers (default: CPU cores - 1)
- `-d`, `--dry-run` - Show what would be converted without actually converting
- `-v`, `--verbose` - Enable verbose output
- `-h`, `--help` - Show help message

#### Examples

```bash
# Convert all CloneCD images in directory and subdirectories
ruby clonecd_batch_help.rb /path/to/images

# Convert with 4 parallel workers
ruby clonecd_batch_help.rb /path/to/images -w4

# Dry-run to see what would be converted
ruby clonecd_batch_help.rb /path/to/images --dry-run

# Verbose output for detailed progress
ruby clonecd_batch_help.rb /path/to/images --verbose
```

### Interactive Prompts

#### 1. Scope Selection
```
Convert:
  [a] All files (recursive, including subdirectories)
  [c] Current directory only (non-recursive)
  [q] Quit
```

#### 2. Existing ISO Handling (if applicable)
```
12 pure data CD(s) already have .iso files:
  game1/disc1.img (652.3 MB)
  game2/disc1.img (701.8 MB)
  ...

What would you like to do?
  [s] Skip existing (only convert new files)
  [r] Reconvert all (overwrite existing .iso files)
  [q] Quit
```

### Output Example

```
=== CONVERSION SESSION COMPLETE ===
Total queued: 15
Successfully converted: 15
Time elapsed: 467.3s
Average time per image: 31.2s

✓ ALL CONVERSIONS COMPLETED SUCCESSFULLY

=== SKIPPED FILES (NOT CONVERTED) ===

Pure Audio CDs (5):
These are already in optimal format (.img + .cue)
  Music/Album1.img
  Music/Album2.img

Mixed-Mode CDs (3):
These contain both data and audio tracks - preserved in original format
  Games/MixedGame1.img
  Games/MixedGame2.img

Log file: /path/to/images/clonecd_batch.log
```

### Behavior Details

- **Track number removal**: `bchunk` adds track numbers (01, 02) to output files; script renames first track to match original base name
- **Multiple data tracks**: If multiple data tracks exist, first is renamed to base name, others keep numbered suffixes
- **Error handling**: Failed conversions are logged with error details; script continues processing remaining files
- **Network drives**: Works on SMB/network mounted drives (tested on macOS)

### File Safety

The script is designed to be non-destructive:
- ✅ Never modifies `.img` files
- ✅ Never modifies `.sub` files  
- ✅ Never modifies `.ccd` files
- ⚠️ May rename `.cue` to `.cue.org` if regeneration is needed
- ✅ Only creates new `.iso` files (or overwrites if user chooses reconvert)

### Resume After Interruption

If conversion is interrupted (connection lost, script stopped, etc.):

1. Check `clonecd_batch.log` to see what completed
2. Run script again - it will:
   - Detect existing `.iso` files
   - Ask if you want to skip or reconvert
   - Continue from where it left off

## Mounting ISO Files

Once converted, ISO files can be mounted on various operating systems:

### macOS
**Built-in support** - Double-click the `.iso` file or use:
```bash
hdiutil mount image.iso
```

To unmount:
```bash
hdiutil unmount /Volumes/VolumeName
```

**Third-party tools:**
- [The Unarchiver](https://theunarchiver.com/) - Free, supports many formats
- [AnyToISO](https://www.crystalidea.com/anytoiso) - Converter and mounter

### Windows
**Built-in support** (Windows 8+) - Right-click `.iso` file → "Mount"

**Third-party tools:**
- [WinCDEmu](https://wincdemu.sysprogs.org/) - Free, open-source virtual drive
- [DAEMON Tools Lite](https://www.daemon-tools.cc/products/dtLite) - Free version available
- [Virtual CloneDrive](https://www.redfox.bz/virtual-clonedrive.html) - Free

### Linux
**Command-line mounting:**
```bash
# Create mount point
sudo mkdir -p /mnt/iso

# Mount ISO
sudo mount -o loop image.iso /mnt/iso

# Unmount
sudo umount /mnt/iso
```

**GUI tools:**
- [Furius ISO Mount](https://launchpad.net/furiusisomount) - Simple GUI for mounting ISOs
- [GMount ISO](https://sourceforge.net/projects/gmountiso/) - GNOME-based mounter
- **File managers**: Most modern Linux file managers (Nautilus, Dolphin, Thunar) can mount ISOs by right-clicking

## Understanding Mode 2 IMG Files

### What are CD Modes?

CD-ROM data can be stored in different sector formats:

- **Mode 1 (2048 bytes/sector)**: Standard data CD format with error correction
- **Mode 2 (2352 bytes/sector)**: Raw sector format used for:
  - Video CDs (VCD/SVCD)
  - PlayStation/Sega CD games
  - Mixed-mode CDs (data + audio)
  - CDs with subchannel data

### Why Mode 2 Matters

**Mode 2 sectors contain:**
- 2352 bytes of raw data per sector
- Additional error detection/correction (EDC/ECC)
- Subchannel data (P-W subchannels)
- Audio track information

**Standard ISO format:**
- Only supports 2048 bytes/sector (Mode 1)
- Loses subchannel data
- Cannot preserve audio tracks
- May lose copy protection information

### How This Script Handles Mode 2

#### Pure Data CDs (Mode 2/2352)
✅ **Converted to ISO**
- `bchunk` extracts the 2048-byte data portion
- Creates mountable ISO file
- Suitable for data-only CDs even if stored in Mode 2 format

#### Mixed-Mode CDs (Data + Audio)
❌ **NOT Converted - Preserved as IMG**
- **Why**: ISO format cannot store audio tracks
- **Original format**: `.img` + `.cue` preserves both data and audio
- **Subchannel data**: `.sub` file contains copy protection and CD-TEXT
- **Best practice**: Keep in CloneCD format for complete preservation

#### Pure Audio CDs
❌ **NOT Converted - Already Optimal**
- **Why**: Audio CDs don't use ISO filesystem
- **Format**: `.img` (or `.bin`) + `.cue` is the standard for audio
- **Playback**: Use media players that support CUE sheets (VLC, foobar2000, etc.)

### When to Keep IMG Format

Keep the original CloneCD `.img` + `.cue` + `.sub` format when:

1. **Mixed-mode CDs**: Games with audio soundtracks (e.g., PlayStation games)
2. **Copy-protected CDs**: Subchannel data needed for proper emulation
3. **Audio CDs**: Music albums, audio books
4. **Video CDs**: VCD/SVCD format discs
5. **Exact archival**: When you need bit-perfect preservation

### Tools for IMG/BIN+CUE Files

**Emulators that support IMG/CUE:**
- [RetroArch](https://www.retroarch.com/) - Multi-system emulator
- [ePSXe](https://www.epsxe.com/) - PlayStation emulator
- [Mednafen](https://mednafen.github.io/) - Multi-system emulator
- [PCSX2](https://pcsx2.net/) - PlayStation 2 emulator

**Media players for audio CUE sheets:**
- [VLC Media Player](https://www.videolan.org/vlc/) - Cross-platform
- [foobar2000](https://www.foobar2000.org/) - Windows (with CUESheet plugin)
- [Audacious](https://audacious-media-player.org/) - Linux

**Burning tools:**
- [ImgBurn](https://www.imgburn.com/) - Windows (can burn IMG/CUE to physical disc)
- [cdrdao](https://cdrdao.sourceforge.net/) - Linux command-line tool

### License

MIT
