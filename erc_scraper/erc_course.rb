#!/usr/bin/env ruby
# frozen_string_literal: true

require 'mechanize'
require 'nokogiri'
require 'rss'
require 'date'

class ERCCourseScraper
  BASE_URL = 'https://www.erc.edu'
  DENMARK_COUNTRY_ID = '59'
  OUTPUT_FILE = 'erc_courses.xml'
  
  def initialize
    @agent = Mechanize.new
    @agent.user_agent_alias = 'Mac Safari'
  end
  
  def scrape_and_generate_rss
    puts "Fetching ERC courses for Denmark..."
    courses = fetch_courses
    
    if courses.empty?
      puts "Warning: No courses found"
      return
    end
    
    puts "Found #{courses.length} courses"
    generate_rss(courses)
  end
  
  private
  
  def fetch_courses
    page = @agent.get("#{BASE_URL}/index.php/agenda/en")
    form = page.forms[1]
    
    unless form
      puts "Error: Could not find course search form"
      return []
    end
    
    country_field = form.field_with(name: 'countryID')
    unless country_field
      puts "Error: Could not find country field"
      return []
    end
    
    country_field.value = DENMARK_COUNTRY_ID
    result_page = @agent.submit(form)
    
    parse_course_list(result_page)
  rescue Mechanize::Error, Net::HTTPError => e
    puts "Error fetching courses: #{e.message}"
    []
  rescue StandardError => e
    puts "Unexpected error: #{e.message}"
    puts e.backtrace.first(5)
    []
  end
  
  def parse_course_list(page)
    doc = Nokogiri::HTML(page.body)
    
    # Find all course links
    course_ids = doc.css('a[href*="viewCourse/en/"]').map do |link|
      link['href'][/viewCourse\/en\/(\d+)/, 1]
    end.compact.uniq
    
    puts "Found #{course_ids.length} course IDs"
    
    # Fetch details for each course
    courses = []
    course_ids.each_with_index do |id, index|
      print "Fetching course #{index + 1}/#{course_ids.length}...\r"
      course = fetch_course_details(id)
      courses << course if course
      sleep 0.3 # Rate limiting to be polite
    end
    puts "\nFinished fetching course details"
    
    courses
  end
  
  def fetch_course_details(id)
    page = @agent.get("#{BASE_URL}/index.php/viewCourse/en/#{id}/")
    doc = Nokogiri::HTML(page.body)
    
    # Extract course information using XPath
    location = extract_field(doc, 'Location')
    organiser = extract_field(doc, 'Course organiser')
    type = extract_field(doc, 'Type')
    participants = extract_field(doc, 'Max. participants')
    dates = extract_dates(doc)
    
    # Validate required fields
    unless location && type && dates
      puts "Warning: Missing required fields for course #{id}"
      return nil
    end
    
    {
      title: "#{type}: #{location}",
      link: "#{BASE_URL}/index.php/viewCourse/en/#{id}/",
      description: build_description(location, dates, type, organiser, participants),
      date: parse_date(dates[:start])
    }
  rescue Mechanize::Error => e
    puts "Error fetching course #{id}: #{e.message}"
    nil
  rescue StandardError => e
    puts "Error parsing course #{id}: #{e.message}"
    nil
  end
  
  def extract_field(doc, label)
    # Find table cell containing the label, then get the next cell
    row = doc.xpath("//td[contains(text(), '#{label}:')]/following-sibling::td[1]")
    return nil if row.empty?
    
    # Clean up the text (remove extra whitespace, HTML tags)
    text = row.first.text.strip
    text.empty? ? nil : text
  end
  
  def extract_dates(doc)
    date_cell = doc.xpath("//td[contains(text(), 'Date:')]/following-sibling::td[1]")
    return nil if date_cell.empty?
    
    text = date_cell.first.text.strip
    # Match date range pattern: "DD.MM.YYYY - DD.MM.YYYY"
    if text =~ /(.+?)\s*-\s*(.+)/
      { start: $1.strip, end: $2.strip }
    else
      nil
    end
  end
  
  def build_description(location, dates, type, organiser, participants)
    parts = [
      "Sted: #{location}",
      "Start: #{dates[:start]}",
      "Slut: #{dates[:end]}",
      "Kursus type: #{type}"
    ]
    
    parts << "Kursus organisator: #{organiser}" if organiser
    parts << "Max deltagere: #{participants}" if participants
    
    parts.join('<br/>')
  end
  
  def parse_date(date_string)
    # Try to parse European date format (DD.MM.YYYY)
    Date.strptime(date_string, '%d.%m.%Y')
  rescue ArgumentError, TypeError
    # Fallback to current time if parsing fails
    Time.now
  end
  
  def generate_rss(courses)
    rss = RSS::Maker.make('2.0') do |maker|
      maker.channel.title = 'ERC kurser'
      maker.channel.link = BASE_URL
      maker.channel.description = 'ERC kurser i Danmark liste over aktuelle kurser'
      maker.channel.updated = Time.now.to_s
      maker.items.do_sort = true # Sort items by date
      
      courses.each do |course|
        maker.items.new_item do |item|
          item.title = course[:title]
          item.link = course[:link]
          item.description = course[:description]
          item.date = course[:date]
        end
      end
    end
    
    File.write(OUTPUT_FILE, rss.to_s)
    puts "RSS feed generated successfully: #{OUTPUT_FILE}"
    puts "Total items: #{courses.length}"
  rescue StandardError => e
    puts "Error generating RSS: #{e.message}"
    puts e.backtrace.first(5)
  end
end

# Run the scraper
if __FILE__ == $PROGRAM_NAME
  scraper = ERCCourseScraper.new
  scraper.scrape_and_generate_rss
end
