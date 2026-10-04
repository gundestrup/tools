#!/usr/bin/ruby
#!c:\ruby\bin\ruby.exe

#Åben filen
# ARGF
#if ARGF.filename.empty?
#  puts "You need to pass the filename in the script"
#  puts "like ./subtitles.rb myMovie.mp4"
#  puts "Exiting"

#end

puts "filename incl extension"
filename = ARGF.filename
puts filename

puts "short name no extension"
name = filename.chop.chop.chop.chop
puts name

#MP4Box -info ~/Desktop/"filnavne"
systeminfo = "MP4Box -info"+" '"+filename.to_s+"'"

puts system systeminfo

# select the track to rip (the number)
puts "Select track to rip"

track = STDIN.gets.chomp

#system "MP4Box -raw trackXX "ARGF.filename" "
systemrip = "MP4Box -raw "+track.to_s+" '"+filename.to_s+"'"

puts system systemrip

#outputtet file are filename_trackX.idx/sub
# must rename to 

#Convert
#system "vobsub2srt "Der Untergang (2004)” (fjern extension) - 4 bogstaver""
systemsrt = "vobsub2srt "+"'"+name+"_track"+track+"'"
puts system systemsrt

# Get language code
puts "Please input the language code, like dan, eng"
language = STDIN.gets.chomp

#rename created files to language code
# like "Der Untergang (2004).dan.srt" from "Der Untergang (2004)_track4.srt"
ext = ".srt"
srtrename = "mv "+"'"+name+"_track"+track+ext+"'"+" "+"'"+name+"."+language+ext+"'"
puts system srtrename

# like "Der Untergang (2004).dan.idx" from "Der Untergang (2004)_track4.idx"
ext = ".idx"
idxrename = "mv "+"'"+name+"_track"+track+ext+"'"+" "+"'"+name+"."+language+ext+"'"
puts system idxrename

# like "Der Untergang (2004).dan.sub" from "Der Untergang (2004)_track4.sub"
ext = ".sub"
subrename = "mv "+"'"+name+"_track"+track+ext+"'"+" "+"'"+name+"."+language+ext+"'"
puts system subrename
#Færdig