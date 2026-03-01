#!/usr/bin/env ruby

require 'optparse'
require 'etc'
require 'open3'
require 'fileutils'
require 'thread'

options = {
  output: nil,
  workers: nil
}

parser = OptionParser.new do |opts|
  opts.banner = <<~BANNER
    CloneCD (.ccd/.img/.sub/.cue) batch converter
    Converts MODE1/2352 and MODE2/2352 data tracks using bchunk.

    Usage:
      clonecd_batch.rb INPUT_DIR [options]

    Behavior:
      - Scans INPUT_DIR for matching .cue + .img files
      - Converts discs containing MODE1/2352 or MODE2/2352 data tracks
      - Skips files if ISO already exists
      - Output defaults to INPUT_DIR unless -o is specified
      - Processes in parallel (default: CPU cores - 1)

    Requires:
      bchunk installed and available in PATH

    Examples:
      clonecd_batch.rb ./images
      clonecd_batch.rb ./images -o ./iso_output
      clonecd_batch.rb ./images -o ./iso_output -w 4
  BANNER

  opts.on("-oDIR", "--output=DIR", "Output directory (default: INPUT_DIR)") do |v|
    options[:output] = v
  end

  opts.on("-wN", "--workers=N", Integer, "Number of parallel workers") do |v|
    options[:workers] = v
  end

  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end

parser.parse!

input_dir = ARGV[0] or abort("ERROR: INPUT_DIR required (use -h for help)")

input_dir  = File.expand_path(input_dir)
output_dir = File.expand_path(options[:output] || input_dir)

abort("ERROR: Input directory not found") unless Dir.exist?(input_dir)
FileUtils.mkdir_p(output_dir)

worker_count = options[:workers] || [Etc.nprocessors - 1, 1].max

puts "Input  : #{input_dir}"
puts "Output : #{output_dir}"
puts "Workers: #{worker_count}"
puts

jobs = []

Dir.glob(File.join(input_dir, "**/*.cue")).sort.each do |cue_path|
  base = File.basename(cue_path, ".cue")
  cue_dir = File.dirname(cue_path)

  img_path = Dir.glob(File.join(cue_dir, "#{base}.img"), File::FNM_CASEFOLD).first
  next unless img_path

  cue_content = File.read(cue_path)

  # Accept both MODE1/2352 and MODE2/2352
  next unless cue_content.match?(/MODE(1|2)\/2352/i)

  # Output skal ligge i samme mappe som cue/img
  iso_path = File.join(cue_dir, "#{base}.iso")
  next if File.exist?(iso_path)

  jobs << { base: base, img: img_path, cue: cue_path, iso: iso_path, dir: cue_dir }
end


total = jobs.size
puts "Found #{total} convertible images"
exit if total.zero?

queue = Queue.new
jobs.each { |j| queue << j }

completed = 0
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
          # Find første data-track (typisk 01) og rename til <base>.iso
          generated = Dir.glob("#{output_base}*.iso").sort.first
          if generated
            FileUtils.mv(generated, iso_target)
          end

          completed += 1
          percent = ((completed.to_f / total) * 100).round(1)
          puts "[#{completed}/#{total}] #{base} ✔ (#{percent}%) → #{File.basename(iso_target)}"
        else
          puts "#{base} ✖ ERROR"
          puts stderr
        end
      end
    end
  end
end

workers.each(&:join)

puts "\nDone."
