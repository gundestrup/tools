
## Insppiration
https://github.com/sBaydin/ZoteroCiteLinker

# Mendeley
## Api
https://dev.mendeley.com/methods/  

### Option 1: Use the Mendeley REST API
The most direct way to get a list of your library documents and their associated system UUIDs is through the Mendeley API Docs.  
Authenticate your account on the Mendeley Developer Portal.  
Make a GET request to the /documents or /search/documents endpoint.  
Parse the JSON response. The server-assigned UUIDs are mapped as the id string under each document object.

### Option 2: Mendeley Desktop SQLite Database  
If you use Mendeley Desktop, the application stores all local library data, including UUIDs, in a local SQLite file.  
Navigate to your local Mendeley Reference Manager application support directory.  
Locate the database file located in
```~/Library/Application Support/Mendeley Desktop/www.mendeley.com/<uuid>/search-index.sqlite.```
Open this .sqlite file using a database browser to query the Documents table and extract the UUIDs natively

## Other sources of info
https://github.com/orgs/Mendeley/repositories  
https://github.com/Mendeley/mendeley-api-ruby-example/blob/master/README.md  

## register api
https://dev.mendeley.com/myapps.html  

## npm lib
https://www.npmjs.com/package/@mendeley/api  

## pytong ilib
https://mendeley-python.readthedocs.io/en/latest/

# Field codes
## Mendeley
```xml
<w:tag w:val="MENDELEY_CITATION_v3_eyJjaXRhdGlvbklEIjoiTUVOREVMRVlfQ0lUQVRJT05fNjMzYjU3MmItMDY1OS00MmMyLWJlY2QtMWVmNjBmY2NlYzBjIiwicHJvcGVydGllcyI6eyJub3RlSW5kZXgiOjB9LCJpc0VkaXRlZCI6ZmFsc2UsIm1hbnVhbE92ZXJyaWRlIjp7ImlzTWFudWFsbHlPdmVycmlkZGVuIjpmYWxzZSwiY2l0ZXByb2NUZXh0IjoiWzFdIiwibWFudWFsT3ZlcnJpZGVUZXh0IjoiIn0sImNpdGF0aW9uSXRlbXMiOlt7ImlkIjoiZGQ0NzI2NmMtZmEyZi0zODFmLTkxZmYtMWFkM2Y2Y2ExMDdlIiwiaXRlbURhdGEiOnsidHlwZSI6ImFydGljbGUtam91cm5hbCIsImlkIjoiZGQ0NzI2NmMtZmEyZi0zODFmLTkxZmYtMWFkM2Y2Y2ExMDdlIiwidGl0bGUiOiJbT3Bpb2lkcyBjYW4gbW9kdWxhdGUgdGhlIGltbXVuZSBzeXN0ZW1dLiIsImF1dGhvciI6W3siZmFtaWx5IjoiR3VuZGVzdHJ1cCIsImdpdmVuIjoiU3ZlbmQiLCJwYXJzZS1uYW1lcyI6ZmFsc2UsImRyb3BwaW5nLXBhcnRpY2xlIjoiIiwibm9uLWRyb3BwaW5nLXBhcnRpY2xlIjoiIn0seyJmYW1pbHkiOiJTasO4Z3JlbiIsImdpdmVuIjoiUGVyIiwicGFyc2UtbmFtZXMiOmZhbHNlLCJkcm9wcGluZy1wYXJ0aWNsZSI6IiIsIm5vbi1kcm9wcGluZy1wYXJ0aWNsZSI6IiJ9XSwiY29udGFpbmVyLXRpdGxlIjoiVWdlc2tyaWZ0IGZvciBsYWVnZXIiLCJjb250YWluZXItdGl0bGUtc2hvcnQiOiJVZ2Vza3IuIExhZWdlciIsIklTU04iOiIxNjAzLTY4MjQiLCJQTUlEIjoiMjUzNDczMzQiLCJpc3N1ZWQiOnsiZGF0ZS1wYXJ0cyI6W1syMDE0LDEsMjddXX0sInBhZ2UiOiJWMDgxMzA1MTYiLCJhYnN0cmFjdCI6Ik9waW9pZHMgY2FuIG1vZHVsYXRlIGFuZCBzdXBwcmVzcyB0aGUgaW1tdW5lIHN5c3RlbSB0aHJvdWdoIGNlbnRyYWwgbWVkaWF0ZWQgbWVjaGFuaXNtcy4gTW9ycGhpbmUgaW5jcmVhc2VzIHJlcGxpY2F0aW9uIGFuZCBzcHJlYWQgb2YgSElWLTEuIEV2aWRlbmNlIHN1Z2dlc3RzIHRoYXQgbW9ycGhpbmUgY2FuIGFsc28gZW5oYW5jZSBncm93dGggYW5kIHNwcmVhZCBvZiBzb21lIGNhbmNlciBkaWFnbm9zZXMgbGlrZSBicmVhc3QtLCBwcm9zdGF0ZS0gYW5kIG5vbi1zbWFsbCBjZWxsIGx1bmcgY2FuY2VyLiBUaGUgbWVjaGFuaXNtcyBiZWhpbmQgdGhlIGVmZmVjdHMgb2YgbW9ycGhpbmUgYXJlIG1haW5seSBtZWRpYXRlZCBieSBpbmhpYml0aW5nIGFwb3B0b3NpcyBvZiBjYW5jZXIgY2VsbHMgYW5kIGJ5IHN0aW11bGF0aW9uIG9mIGFuZ2lvZ2VuZXNpcy4gU29tZSBvdGhlciBvcGlvaWQgYWdvbmlzdHMgc2VlbSB0byBiZSBkZXBsZXRlZCBmcm9tIHRoZXNlIGVmZmVjdHMuIFByb3NwZWN0aXZlIHN0dWRpZXMgYXJlIG5lZWRlZCB0byBjbGFyaWZ5IHRoZSBpbW11bm9zdXBwcmVzc2l2ZSBlZmZlY3RzIG9mIG9waW9pZHMgaW4gY2FuY2VyIHBhaW4gbWFuYWdlbWVudC4iLCJpc3N1ZSI6IjVBIiwidm9sdW1lIjoiMTc2In0sImlzVGVtcG9yYXJ5IjpmYWxzZSwic3VwcHJlc3MtYXV0aG9yIjpmYWxzZSwiY29tcG9zaXRlIjpmYWxzZSwiYXV0aG9yLW9ubHkiOmZhbHNlfV19"/><w:id w:val="-1336915730"/><w:placeholder><w:docPart w:val="DefaultPlaceholder_-1854013440"/></w:placeholder></w:sdtPr><w:sdtContent><w:r w:rsidRPr="00F65D0C"><w:rPr><w:rFonts w:eastAsia="Times New Roman" w:cs="Arial"/></w:rPr><w:t>[1]</w:t></w:r></w:sdtContent></w:sdt>
```

bibliografi
```xml
<w:tag w:val="MENDELEY_BIBLIOGRAPHY"/><w:id w:val="-1005505753"/><w:placeholder><w:docPart w:val="DefaultPlaceholder_-1854013440"/></w:placeholder></w:sdtPr><w:sdtContent>
```
## Zotero
```xml
<w:instrText xml:space="preserve"> ADDIN ZOTERO_ITEM CSL_CITATION {"citationID":"pf9hQhOA","properties":{"unsorted":false,"formattedCitation":"[1]","plainCitation":"[1]","noteIndex":0},"citationItems":[{"id":2,"uris":["http://zotero.org/users/1002683/items/GCDARE22"],"itemData":{"id":2,"type":"article-journal","abstract":"Opioids can modulate and suppress the immune system through central mediated mechanisms. Morphine increases replication and spread of HIV-1. Evidence suggests  that morphine can also enhance growth and spread of some cancer diagnoses like  breast-, prostate- and non-small cell lung cancer. The mechanisms behind the  effects of morphine are mainly mediated by inhibiting apoptosis of cancer cells  and by stimulation of angiogenesis. Some other opioid agonists seem to be  depleted from these effects. Prospective studies are needed to clarify the  immunosuppressive effects of opioids in cancer pain management.","container-title":"Ugeskrift for laeger","ISSN":"1603-6824 0041-5782","issue":"5A","journalAbbreviation":"Ugeskr Laeger","language":"dan","page":"V08130516","PMID":"25347334","publisher-place":"Denmark","title":"[Opioids can modulate the immune system].","volume":"176","author":[{"family":"Gundestrup","given":"Svend"},{"family":"Sjøgren","given":"Per"}],"issued":{"date-parts":[["2014",1,27]]}}}],"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"} </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r>
```

  bibliografi
  ```xml
ADDIN ZOTERO_BIBL {"uncited":[],"omitted":[],"custom":[]} CSL_BIBLIOGRAPHY </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/>
```
