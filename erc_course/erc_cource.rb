class ErcCourse
  
  require 'rubygems'
  require 'mechanize'
  require 'rss/maker'

  #RSS start
  version = "2.0" # ["0.9", "1.0", "2.0"]
  destination = "erc_courses.xml" # local file to write

    content = RSS::Maker.make(version) do |m|
    m.channel.title = "ERC kurser"
    m.channel.link = "http://www.resuscitation.dk"
    m.channel.description = "ERC kurser i Danmark liste over aktuelle kurser"
    m.items.do_sort = true # sort items by date


  def self.coursedetails(id)
    #Getting course information
        agent = Mechanize.new
        agent.user_agent_alias = 'Mac Safari'
        pagecourse = agent.get('https://www.erc.edu/index.php/viewCourse/en/'+id.to_s+'/')
        course = pagecourse.body

        location = Regexp.new(/Location\: <\/td>\s*<td>(.*)<\/td>/)
        location = location.match(course)

        courseorganiser = Regexp.new(/Course organiser\: <\/td>\s*<td>(.*)<br><form .*<\/td>/)
        courseorganiser = courseorganiser.match(course)

        type = Regexp.new(/Type\:<\/td>\s*<td>(.*)<\/td>/)
        type = type.match(course)

        participants = Regexp.new(/Max. participants\: <\/td>\s*<td>(.*)<\/td>/)
        participants = participants.match(course)

        date = Regexp.new(/Date\:<\/td>\s*<td .*>(.*) - (.*)<\/td>/)
        date = date.match(course)


        if location != nil
          #puts location[1] # Kursus sted
        end
        if courseorganiser != nil
          #puts courseorganiser[1] #Kursus organisator
        end
        if type != nil
          #puts type[1] #Kursus type
        end
        if participants != nil
          #puts participants[1] # Deltagere
        end
        if date != nil
          #puts date[1]  #Start
          #puts date[2]  #Slut
        end
        
        #creating variables for rss input
        @title = type[1]+': '+location[1]
        @link = 'https://www.erc.edu/index.php/viewCourse/en/'+id.to_s+'/'
        @description =  'Sted: '+location[1].to_s+'<br/>'+
                        'Start: '+date[1].to_s+'<br/>'+
                        'Slut: ' +date[2].to_s+'<br/>'+
                        'Kursus type: '+type[1].to_s+'<br/>'+        
                        'Kursus organisator: '+courseorganiser[1].to_s+'<br/>'+                  
                        'Max deltagere: '+participants[1].to_s+'<br/>'

  end

  agent = Mechanize.new
  agent.user_agent_alias = 'Mac Safari'  
  page = agent.get('https://www.erc.edu/index.php/agenda/en')

  form = page.forms[1]
  form.fields.find{|f| f.name == 'countryID'}.value = "59"

  page = agent.submit(form)
  website = page.body
  #Output complete site
  f = File.new("erc_course.html", "w+")
  f.puts website

  #Finding anything with "https://www.erc.edu/index.php/viewCourse/en"
  #regex = Regexp.new(/(viewCourse\/en\/\d\d\d\d\d)/)
  regex = Regexp.new(/viewCourse\/en\/(\d\d\d\d\d)/)
  matchdata = regex.match(website)

  while matchdata != nil
      #puts matchdata[1]
      coursedetails(matchdata[1])
      i = m.items.new_item
      i.title = @title
      i.link = @link
      i.description = @description
      i.date = Time.now      
      website = matchdata.post_match
      matchdata = regex.match(website)
      
  end

  end

  #Output processing, RSS feeds http://rubyrss.com/
  File.open(destination,"w") do |f|
  f.write(content)
  end

end