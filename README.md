# tools

[![SonarCloud](https://sonarcloud.io/api/project_badges/measure?project=gundestrup_tools&metric=alert_status)](https://sonarcloud.io/dashboard?id=gundestrup_tools)
[![CodeFactor](https://www.codefactor.io/repository/github/gundestrup/tools/badge)](https://www.codefactor.io/repository/github/gundestrup/tools)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gundestrup/tools)

Tools / scripts that are helpful

## CloneCD convert
Create files to proper iso files  
See script [CloneCD batch converter script](CloneCD/clonecd_batch_help.rb)  
See [Help Me file](CloneCD/README.clonecd_batch_help.md)  
Converts files with format  
* MODE1/2352
* MODE2/2352
Using
 - .ccd
 - .img
 - .cue
to isofiles.  

It will search current dir and subdir, and convert them using parallel processing.  

Uses bchunk installed via brew

## website scraper to generate xml for RSS
Originally used to scrape contents from ERC to generate an RSS feed on a website with links to the ERC site.  
 - [script file](erc_scraper/erc_course.rb)  
 - [script read me file](erc_scraper/README.ercScraper.md)  
 - [script upload result file to server](erc_scraper/run_erc_scraper.sh)