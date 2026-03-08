#!/usr/bin/env ruby

require "timeout"

BASE_YEAR   = 1981
BASE_VOLUME = 159

renames = []

Dir.glob("National Geographic*").each do |f|
  next if f =~ /Civil War/i

  unless f =~ /(\d{4})-(\d{2})/
    puts "SKIP: #{f}"
    next
  end

  year  = $1.to_i
  month = $2.to_i

  # calculate volume / issue
  volume = BASE_VOLUME + (year - BASE_YEAR) * 2 + (month > 6 ? 1 : 0)
  issue  = ((month - 1) % 6) + 1

  # detect region edition
  region = f[/ - (US|UK)(?=\s*\.)/]

  # detect extension
  ext =
    if f =~ /\.cover\.jpg$/i
      ".cover.jpg"
    elsif f =~ /\.metadata\.json$/i
      ".metadata.json"
    else
      ".pdf"
    end

  new_name = "National Geographic - #{year}-#{"%02d" % month} - vol #{volume} issue #{issue}"
  new_name += region if region
  new_name += ext

  new_name.gsub!(/\s+/, " ")

  puts "#{f} -> #{new_name}"

  renames << [f, new_name] unless f == new_name
end

puts "\nDry run complete."
puts "Press [R] to perform renaming, or press Enter to cancel (15‑second timeout)."

begin
  input = Timeout.timeout(15) { STDIN.gets&.strip }
rescue Timeout::Error
  input = nil
end

if input&.downcase == "r"
  puts "\nRenaming files..."
  renames.each do |old, new|
    File.rename(old, new)
    puts "#{old} -> #{new}"
  end
  puts "Done."
else
  puts "\nNo changes made."
end
