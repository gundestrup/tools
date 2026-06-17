
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
Navigate to your local Mendeley Reference Manager application support directory.Locate the database file located in ~/Library/Application Support/Mendeley Desktop/www.mendeley.com/<uuid>/search-index.sqlite.Open this .sqlite file using a database browser to query the Documents table and extract the UUIDs natively
