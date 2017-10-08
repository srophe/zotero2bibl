# zotero2bibl
Accesses Zotero API to load Zotero library into eXistdb and keep the eXistdb version up to date with the Zotero library. 
Canonical data lives in Zotero. Data stored in eXist uses the zotero2tei.xqm to transform Zotero records into Syriaca.org compliant TEI records. 
To change the TEI output edit zotero2tei.xqm. 

## How to use:
1. Add folder to eXist, either in an existing application or as a standalone library.
2. Edit zotero-config.xml:
    a. Add your Zotero group id
    b. Add the path to the data directory where you want to store Zotero bibliographic records in eXist
    c. Add the URI pattern to base an incremental URI on. example: http://syriaca.org/bibl  
