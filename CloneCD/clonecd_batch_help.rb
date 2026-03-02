#!/usr/bin/env ruby

require 'optparse'
require 'etc'
require 'open3'
require 'fileutils'
require 'thread'
require 'time'
require 'logger'

# ------------------------------------------------------------
# LOGGING SETUP
# ------------------------------------------------------------
def setup_logger(log_path)
  logger = Logger.new(log_path)
  logger.level = Logger::INFO
  logger.formatter = proc do |severity, datetime, progname, msg|
    "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
  end
  logger
end

def log_and_print(logger, message, level: :info)
  puts message
  case level
  when :info then logger.info(message)
  when :warn then logger.warn(message)
  when :error then logger.error(message)
  end
end

# ------------------------------------------------------------
# CCD PARSER
# ------------------------------------------------------------
def parse_ccd(ccd_path)
  ccd = File.read(ccd_path)
  tracks = []
  current = nil

  ccd.each_line do |line|
    if line =~ /\[TRACK\s+(\d+)\]/i
      current = { number: $1.to_i }
      tracks << current
    elsif line =~ /MODE\s*=\s*(\d+)/i
      next unless current
      current[:mode] = $1.to_i
    elsif line =~ /INDEX\s*1\s*=\s*(\d+)/i
      next unless current
      current[:lba] = $1.to_i
    end
  end

  # Validate track data completeness - keep tracks with lba, even if mode is 0 (audio)
  tracks.select! { |t| !t[:lba].nil? }
  tracks
rescue => e
  warn "Error parsing CCD file #{ccd_path}: #{e.message}"
  []
end


# ------------------------------------------------------------
# CD TYPE CLASSIFIER
# ------------------------------------------------------------
def classify_cd_type(tracks)
  return :empty if tracks.empty?
  
  has_data = tracks.any? { |t| t[:mode] == 1 || t[:mode] == 2 }
  has_audio = tracks.any? { |t| t[:mode].nil? || t[:mode] == 0 || !t[:mode] || t[:mode] > 2 }
  
  if has_data && has_audio
    :mixed_mode
  elsif has_data
    :pure_data
  elsif has_audio
    :pure_audio
  else
    :unknown
  end
end

# ------------------------------------------------------------
# CUE VALIDATOR
# ------------------------------------------------------------
def cue_needs_regeneration?(cue_path, ccd_tracks, img_basename)
  return true unless cue_path && File.exist?(cue_path)

  cue = File.read(cue_path)

  # Filnavn skal matche
  return true unless cue.include?(img_basename)

  # Antal tracks skal matche
  cue_tracks = cue.scan(/TRACK\s+(\d+)/i).flatten.map(&:to_i)
  return true if cue_tracks.size != ccd_tracks.size

  # MODE skal matche
  cue_modes = cue.scan(/TRACK\s+\d+\s+(MODE\d\/2352|AUDIO)/i).flatten
  return true if cue_modes.size != ccd_tracks.size

  # INDEX skal matche
  cue_indexes = cue.scan(/INDEX\s+1\s+(\d+):(\d+):(\d+)/)
  return true if cue_indexes.size != ccd_tracks.size

  false
rescue => e
  warn "Error validating CUE file #{cue_path}: #{e.message}"
  true
end

# ------------------------------------------------------------
# CUE PARSER (for .img files without .ccd)
# ------------------------------------------------------------
def parse_cue(cue_path)
  return [] unless File.exist?(cue_path)
  
  cue = File.read(cue_path)
  tracks = []
  track_num = 0
  
  cue.each_line do |line|
    if line =~ /TRACK\s+(\d+)\s+(MODE\d\/2352|AUDIO)/i
      track_num = $1.to_i
      mode_str = $2.upcase
      
      mode = case mode_str
      when "MODE1/2352" then 1
      when "MODE2/2352" then 2
      else 0  # AUDIO
      end
      
      tracks << { number: track_num, mode: mode, lba: 0 }
    elsif line =~ /INDEX\s+01\s+(\d+):(\d+):(\d+)/i && track_num > 0
      mm, ss, ff = $1.to_i, $2.to_i, $3.to_i
      lba = (mm * 60 * 75) + (ss * 75) + ff
      tracks.last[:lba] = lba if tracks.any?
    end
  end
  
  tracks
rescue => e
  warn "Error parsing CUE file #{cue_path}: #{e.message}"
  []
end

# ------------------------------------------------------------
# CUE GENERATOR
# ------------------------------------------------------------
def generate_cue_from_ccd(ccd_path)
  dir  = File.dirname(ccd_path)
  base = File.basename(ccd_path, ".ccd")

  img_path = Dir.glob(File.join(dir, "#{base}.img"), File::FNM_CASEFOLD).first
  return nil unless img_path

  tracks = parse_ccd(ccd_path)
  return nil if tracks.empty?

  # Konverter LBA → mm:ss:ff
  tracks.each do |t|
    lba = t[:lba] || 0
    mm = lba / (60 * 75)
    ss = (lba / 75) % 60
    ff = lba % 75
    t[:index] = format("%02d:%02d:%02d", mm, ss, ff)

    t[:mode_str] =
      case t[:mode]
      when 1 then "MODE1/2352"
      when 2 then "MODE2/2352"
      else        "AUDIO"
      end
  end

  cue_path = File.join(dir, "#{base}.cue")

  File.open(cue_path, "w") do |f|
    f.puts %(FILE "#{File.basename(img_path)}" BINARY)

    tracks.each do |t|
      f.puts %(  TRACK #{format("%02d", t[:number])} #{t[:mode_str]})
      f.puts %(    INDEX 01 #{t[:index]})
    end
  end

  cue_path
end

# ------------------------------------------------------------
# OPTION PARSING
# ------------------------------------------------------------
options = { workers: nil, dry_run: false, verbose: false }

parser = OptionParser.new do |opts|
  opts.banner = <<~BANNER
    CloneCD (.ccd/.img/.sub/.cue) batch converter
    Intelligently converts CloneCD images based on content type.

    Usage:
      clonecd_batch.rb INPUT_DIR [options]

    Behavior:
      - Scans INPUT_DIR for CloneCD sets (.img/.ccd/.sub/.cue)
      - Validates .cue files against .ccd metadata
      - Regenerates .cue if missing or incorrect
      - Classifies CDs by type and converts accordingly:
        • Pure data CDs (MODE1/MODE2) → Converted to .iso
        • Pure audio CDs → Skipped (use .img+.cue as-is)
        • Mixed-mode CDs (data+audio) → Skipped (preserves audio tracks)
      - Output .iso placed in same directory as source files
      - Processes in parallel (default: CPU cores - 1)
      - Interactive mode: choose to convert all or current directory only

    Requires:
      bchunk installed and available in PATH
  BANNER

  opts.on("-wN", "--workers=N", Integer, "Number of parallel workers") { |v| options[:workers] = v }
  opts.on("-d", "--dry-run", "Show what would be converted without actually converting") { options[:dry_run] = true }
  opts.on("-v", "--verbose", "Enable verbose output") { options[:verbose] = true }
  opts.on("-h", "--help", "Show this help message") { puts opts; exit }
end

parser.parse!

input_dir = ARGV[0] or abort("ERROR: INPUT_DIR required")
input_dir = File.expand_path(input_dir)

abort("ERROR: Input directory not found") unless Dir.exist?(input_dir)

# Check if bchunk is available
system("which bchunk > /dev/null 2>&1") or abort("ERROR: bchunk not found in PATH")

worker_count = options[:workers] || [Etc.nprocessors - 1, 1].max

puts "Input    : #{input_dir}"
puts "Workers  : #{worker_count}"
puts "Dry-run  : #{options[:dry_run]}" if options[:dry_run]
puts "Verbose  : #{options[:verbose]}" if options[:verbose]
puts

start_time = Time.now

# Setup logging
log_file = File.join(input_dir, "clonecd_batch.log")
logger = setup_logger(log_file)

logger.info("="*60)
logger.info("CloneCD Batch Converter - Session Started")
logger.info("="*60)
logger.info("Input directory: #{input_dir}")
logger.info("Worker count: #{worker_count}")
logger.info("Dry-run: #{options[:dry_run]}")
logger.info("Verbose: #{options[:verbose]}")
logger.info("")

# ------------------------------------------------------------
# JOB DISCOVERY
# ------------------------------------------------------------
all_candidates = []
logger.info("Starting file discovery...")

Dir.glob(File.join(input_dir, "**/*.img")).sort.each do |img_path|
  base = File.basename(img_path, ".img")
  dir  = File.dirname(img_path)

  cue_path = Dir.glob(File.join(dir, "#{base}.cue"), File::FNM_CASEFOLD).first
  ccd_path = Dir.glob(File.join(dir, "#{base}.ccd"), File::FNM_CASEFOLD).first

  tracks = []
  cd_type = :unknown

  # Try .ccd first (most accurate)
  if ccd_path
    tracks = parse_ccd(ccd_path)
    img_basename = File.basename(img_path)

    # Classify CD type
    cd_type = classify_cd_type(tracks)
    
    if cue_needs_regeneration?(cue_path, tracks, img_basename)
      unless options[:dry_run]
        FileUtils.mv(cue_path, cue_path + ".org") if cue_path && File.exist?(cue_path)
        cue_path = generate_cue_from_ccd(ccd_path)
      end
      puts "  [Regenerated .cue from .ccd: #{base}]" if options[:verbose]
    end
  # Fallback to .cue if no .ccd
  elsif cue_path
    tracks = parse_cue(cue_path)
    cd_type = classify_cd_type(tracks)
    puts "  [Using .cue without .ccd: #{base}]" if options[:verbose]
  else
    puts "  [Skipping #{base}: no .ccd or .cue found]" if options[:verbose]
    next
  end
  
  all_candidates << {
    base: base,
    img: img_path,
    cue: cue_path,
    dir: dir,
    cd_type: cd_type,
    tracks: tracks
  }
  
  logger.info("Discovered: #{base} (#{cd_type})")
end

logger.info("")
logger.info("Discovery complete: #{all_candidates.size} images found")

# Early exit if nothing found
if all_candidates.empty?
  msg = "No CloneCD images found in #{input_dir}"
  log_and_print(logger, msg)
  logger.info("Session ended - no files to process")
  exit
end

# Display found files grouped by type
puts "\n=== DISCOVERED CLONECD IMAGES ==="
puts

by_type = all_candidates.group_by { |c| c[:cd_type] }

[:pure_data, :mixed_mode, :pure_audio, :unknown].each do |type|
  next unless by_type[type]
  
  label = case type
  when :pure_data then "Pure Data CDs (will convert to .iso)"
  when :mixed_mode then "Mixed-Mode CDs (data+audio, skip conversion)"
  when :pure_audio then "Pure Audio CDs (skip conversion)"
  when :unknown then "Unknown/Empty CDs (skip)"
  end
  
  puts "#{label}: #{by_type[type].size}"
  logger.info("#{label}: #{by_type[type].size}")
  
  by_type[type].sort_by { |c| c[:img] }.each do |candidate|
    rel_path = candidate[:img].sub(input_dir + "/", "")
    puts "  #{rel_path}"
    logger.info("  - #{rel_path}")
  end
  puts
end

logger.info("")

# Check if we have an interactive terminal
unless STDIN.tty?
  puts "\nERROR: No interactive terminal detected."
  puts "This script requires interactive input and must be run from a terminal."
  puts "If running via SSH, ensure you allocate a TTY (ssh -t)."
  logger.error("No TTY available - cannot run interactively")
  logger.info("Session aborted - no interactive terminal")
  exit 1
end

# Ask user for scope with validation
scope_choice = nil
loop do
  puts "Convert:"
  puts "  [a] All files (recursive, including subdirectories)"
  puts "  [c] Current directory only (non-recursive)"
  puts "  [q] Quit"
  print "\nChoice [a/c/q]: "
  
  begin
    scope_choice = STDIN.gets.chomp.downcase
  rescue Errno::EPERM, Errno::EBADF, IOError => e
    puts "\nERROR: Cannot read from stdin (#{e.message})"
    puts "This script requires interactive input."
    logger.error("Cannot read from stdin: #{e.message}")
    logger.info("Session aborted - no stdin available")
    exit 1
  end
  
  if scope_choice == 'q'
    puts "Aborted by user."
    logger.info("Session aborted by user")
    exit
  elsif ['a', 'c'].include?(scope_choice)
    logger.info("User selected: #{scope_choice == 'a' ? 'All files' : 'Current directory only'}")
    break
  else
    puts "\nInvalid choice '#{scope_choice}'. Please enter 'a', 'c', or 'q'.\n\n"
  end
end

# Filter based on scope choice
filtered_candidates = case scope_choice
when 'c'
  all_candidates.select { |c| File.dirname(c[:img]) == input_dir }
else
  all_candidates
end

# Count existing ISOs in filtered candidates
existing_isos = filtered_candidates.select do |c|
  c[:cd_type] == :pure_data && File.exist?(File.join(c[:dir], "#{c[:base]}.iso"))
end

# Ask about force reconversion if existing ISOs found
force_reconvert = false
if existing_isos.any?
  puts "\n=== EXISTING .ISO FILES FOUND ==="
  puts "#{existing_isos.size} pure data CD(s) already have .iso files:"
  puts
  existing_isos.sort_by { |c| c[:img] }.each do |candidate|
    rel_path = candidate[:img].sub(input_dir + "/", "")
    iso_size = File.size(File.join(candidate[:dir], "#{candidate[:base]}.iso"))
    puts "  #{rel_path} (#{(iso_size / 1024.0 / 1024.0).round(1)} MB)"
  end
  puts
  
  loop do
    puts "What would you like to do?"
    puts "  [s] Skip existing (only convert new files)"
    puts "  [r] Reconvert all (overwrite existing .iso files)"
    puts "  [q] Quit"
    print "\nChoice [s/r/q]: "
    
    begin
      force_choice = STDIN.gets.chomp.downcase
    rescue Errno::EPERM, Errno::EBADF, IOError => e
      puts "\nERROR: Cannot read from stdin (#{e.message})"
      puts "This script requires interactive input."
      logger.error("Cannot read from stdin: #{e.message}")
      logger.info("Session aborted - no stdin available")
      exit 1
    end
    
    if force_choice == 'q'
      puts "Aborted by user."
      logger.info("Session aborted by user")
      exit
    elsif force_choice == 's'
      force_reconvert = false
      logger.info("User chose to skip existing ISOs")
      break
    elsif force_choice == 'r'
      force_reconvert = true
      logger.info("User chose to reconvert existing ISOs")
      break
    else
      puts "\nInvalid choice '#{force_choice}'. Please enter 's', 'r', or 'q'.\n"
    end
  end
end

# Build job list from filtered candidates
jobs = []
skipped_audio = []
skipped_mixed = []

filtered_candidates.each do |candidate|
  case candidate[:cd_type]
  when :pure_audio
    skipped_audio << candidate
    next
  when :mixed_mode
    skipped_mixed << candidate
    next
  when :pure_data
    iso_path = File.join(candidate[:dir], "#{candidate[:base]}.iso")
    
    # Skip if ISO exists unless user chose to reconvert
    if File.exist?(iso_path) && !force_reconvert
      puts "  [Skipping #{candidate[:base]}: .iso already exists]" if options[:verbose]
      next
    end
    
    jobs << {
      base: candidate[:base],
      img: candidate[:img],
      cue: candidate[:cue],
      iso: iso_path,
      dir: candidate[:dir],
      size: File.size(candidate[:img])
    }
  else
    next
  end
end

total = jobs.size
total_size = jobs.sum { |j| j[:size] }

puts "\n=== CONVERSION SUMMARY ==="
puts "Will convert: #{total} pure data CD(s) (#{(total_size / 1024.0 / 1024.0).round(1)} MB)"
puts "Skipped: #{skipped_audio.size} audio, #{skipped_mixed.size} mixed-mode"
puts

logger.info("")
logger.info("Conversion queue: #{total} files (#{(total_size / 1024.0 / 1024.0).round(1)} MB)")
logger.info("Skipped: #{skipped_audio.size} audio, #{skipped_mixed.size} mixed-mode")
jobs.each do |job|
  logger.info("  Queued: #{job[:base]}")
end
logger.info("")

if total.zero?
  puts "No files to convert."
  logger.info("No files to convert - session ended")
  exit
end

if options[:dry_run]
  puts "DRY-RUN MODE: No files will be converted.\n"
  logger.info("DRY-RUN MODE - no actual conversion performed")
  jobs.each do |job|
    puts "  Would convert: #{job[:base]}"
    logger.info("  Would convert: #{job[:base]}")
  end
  logger.info("Dry-run complete - session ended")
  exit
end

logger.info("Starting conversion process...")

# ------------------------------------------------------------
# WORKER POOL
# ------------------------------------------------------------
queue = Queue.new
jobs.each { |j| queue << j }

completed = 0
failed = 0
mutex = Mutex.new

workers = worker_count.times.map do
  Thread.new do
    loop do
      job = queue.pop(true) rescue break

      base = job[:base]
      img  = job[:img]
      cue  = job[:cue]
      iso_target = job[:iso]
      output_base = File.join(job[:dir], job[:base])

      cmd = ["bchunk", "-w", img, cue, output_base]
      stdout, stderr, status = Open3.capture3(*cmd)

      mutex.synchronize do
        if status.success?
          # bchunk adds track numbers (01, 02, etc.) to the output base
          # Find only bchunk-generated files (with numeric suffixes like 01, 02)
          # Exclude the target ISO if it already exists
          generated_files = Dir.glob("#{output_base}[0-9][0-9].iso").sort
          
          if generated_files.any?
            # Rename first track to target name (removes the track number suffix)
            FileUtils.mv(generated_files.first, iso_target)
            
            completed += 1
            percent = ((completed.to_f / total) * 100).round(1)
            output_info = File.basename(iso_target)
            output_info += " (+#{generated_files.size - 1} tracks)" if generated_files.size > 1
            puts "[#{completed}/#{total}] #{base} ✔ (#{percent}%) → #{output_info}"
            
            iso_size = File.size(iso_target)
            logger.info("COMPLETED: #{base} → #{output_info} (#{(iso_size / 1024.0 / 1024.0).round(1)} MB)")
            
            if options[:verbose]
              puts "    Output size: #{(iso_size / 1024.0 / 1024.0).round(1)} MB"
            end
          else
            failed += 1
            puts "#{base} ✖ ERROR: No ISO files generated"
            logger.error("FAILED: #{base} - No ISO files generated")
          end
        else
          failed += 1
          puts "#{base} ✖ ERROR"
          puts stderr unless stderr.empty?
          logger.error("FAILED: #{base} - bchunk error")
          logger.error("  stderr: #{stderr}") unless stderr.empty?
        end
      end
    end
  end
end

workers.each(&:join)

end_time = Time.now
elapsed = end_time - start_time

puts "\n=== CONVERSION COMPLETE ==="
puts "Converted: #{completed} of #{total} images successfully"
puts "Failed: #{failed}" if failed > 0
puts "Time elapsed: #{elapsed.round(1)}s"

if completed > 0
  avg_time = elapsed / completed
  puts "Average time per image: #{avg_time.round(1)}s"
end

logger.info("")
logger.info("="*60)
logger.info("CONVERSION SESSION COMPLETE")
logger.info("="*60)
logger.info("Total queued: #{total}")
logger.info("Successfully converted: #{completed}")
logger.info("Failed: #{failed}") if failed > 0
logger.info("Time elapsed: #{elapsed.round(1)}s")
logger.info("Average time per image: #{avg_time.round(1)}s") if completed > 0

if completed == total && failed == 0
  logger.info("")
  logger.info("✓ ALL CONVERSIONS COMPLETED SUCCESSFULLY")
  logger.info("")
elsif failed > 0
  logger.warn("")
  logger.warn("⚠ SOME CONVERSIONS FAILED - Review errors above")
  logger.warn("")
else
  logger.warn("")
  logger.warn("⚠ SESSION INCOMPLETE - #{total - completed} files not processed")
  logger.warn("Run script again and choose 'Reconvert all' to retry")
  logger.warn("")
end

# List skipped files
if skipped_audio.any? || skipped_mixed.any?
  logger.info("")
  logger.info("="*60)
  logger.info("SKIPPED FILES (NOT CONVERTED)")
  logger.info("="*60)
  
  if skipped_audio.any?
    logger.info("")
    logger.info("Pure Audio CDs (#{skipped_audio.size}):")
    logger.info("These are already in optimal format (.img + .cue)")
    skipped_audio.sort_by { |c| c[:img] }.each do |candidate|
      rel_path = candidate[:img].sub(input_dir + "/", "")
      logger.info("  - #{rel_path}")
    end
  end
  
  if skipped_mixed.any?
    logger.info("")
    logger.info("Mixed-Mode CDs (#{skipped_mixed.size}):")
    logger.info("These contain both data and audio tracks - preserved in original format")
    skipped_mixed.sort_by { |c| c[:img] }.each do |candidate|
      rel_path = candidate[:img].sub(input_dir + "/", "")
      logger.info("  - #{rel_path}")
    end
  end
end

logger.info("")
logger.info("Log file: #{log_file}")
logger.close

# Display skipped files summary to console
if skipped_audio.any? || skipped_mixed.any?
  puts "\n=== SKIPPED FILES (NOT CONVERTED) ==="
  
  if skipped_audio.any?
    puts "\nPure Audio CDs (#{skipped_audio.size}):"
    puts "These are already in optimal format (.img + .cue)"
    skipped_audio.sort_by { |c| c[:img] }.each do |candidate|
      rel_path = candidate[:img].sub(input_dir + "/", "")
      puts "  #{rel_path}"
    end
  end
  
  if skipped_mixed.any?
    puts "\nMixed-Mode CDs (#{skipped_mixed.size}):"
    puts "These contain both data and audio tracks - preserved in original format"
    skipped_mixed.sort_by { |c| c[:img] }.each do |candidate|
      rel_path = candidate[:img].sub(input_dir + "/", "")
      puts "  #{rel_path}"
    end
  end
end

puts "\nLog file: #{log_file}"
