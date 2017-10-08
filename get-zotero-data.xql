xquery version "3.1";
(:~
 : XQuery Zotero integration
 : Queries Zotero API : https://api.zotero.org
 : Checks for updates since last modified version using Zotero Last-Modified-Version header
 : Checks for existing records in eXistdb at specifed data directory
 : Converts Zotero records to Syriaca.org TEI using zotero2tei.xqm
 : Adds new records to directory.
 :
 : To be done: 
 :      Submit to Perseids
 :      Better (any) rate limiting handling. Respond appropriatly to backoff responses: 
            Backoff: <seconds>  in header
            Retry-After: <seconds> in header
:)

import module namespace http="http://expath.org/ns/http-client";
import module namespace zotero2tei="http://syriaca.org/zotero2tei" at "zotero2tei.xqm";
declare namespace tei="http://www.tei-c.org/ns/1.0";
declare namespace output = "http://www.w3.org/2010/xslt-xquery-serialization";

declare variable $zotero-api := 'https://api.zotero.org';

(: Access zotero-api configuration file :) 
declare variable $zotero-config := doc('zotero-config.xml');
(: Zotero group id :)
declare variable $groupid := $zotero-config//groupid/text();
(: Zotero last modified version, to check for updates. :)
declare variable $last-modified-version := $zotero-config//last-modified-version/text();
(: Directory bibl data is stored in :)
declare variable $data-dir := $zotero-config//data-dir/text();
(: Local URI pattern for bibl records :)
declare variable $base-uri := $zotero-config//base-uri/text();

(:~
 : Check for updates since last modified version (stored in $zotero-config)
 : @param $groupid Zotero group id
 : @param $last-modified-version
:)
declare function local:get-zotero-group-items(){
if($last-modified-version != '' or request:get-parameter('action', '') != 'initiate') then 
    http:send-request(<http:request href="{xs:anyURI(concat($zotero-api,'/groups/',$groupid,'/items?format=tei'))}" method="get">
                         <http:header name="Connection" value="close"/>
                         <http:header name="If-Modified-Since-Version" value="{$last-modified-version}"/>
                       </http:request>)
else
    http:send-request(<http:request href="{xs:anyURI(concat($zotero-api,'/groups/',$groupid,'/items?format=tei'))}" method="get">
                         <http:header name="Connection" value="close"/>
                       </http:request>)                   
};

(:~
 : Page through Zotero results
 : @param $groupid
 : @param $last-modified-version
 : @param $total
 : @param $start
 : @param $perpage
:)
declare function local:get-next($total as xs:integer, $start as xs:integer, $perpage as xs:integer){
let $items := 
    http:send-request(<http:request href="{xs:anyURI(concat($zotero-api,'/groups/',$groupid,'/items?start=',$start,'&amp;format=tei'))}" method="get">
                         <http:header name="Connection" value="close"/>
                         <http:header name="If-Modified-Since-Version" value="{$last-modified-version}"/>
                       </http:request>)
let $headers := $items[1]
let $results := $items[2]
let $next := if(($start + $perpage) lt $total) then $start + $perpage else ()
return 
    if($headers/@status = '200') then
        (
        for $rec at $p in $results//tei:biblStruct
        let $rec-num := $start + $p
        return local:process-items($rec, $rec-num),
        if($next) then 
            local:get-next($total, $next, $perpage)
        else ())
    else  <message status="{$headers/@status}">{$headers/@message}</message>          
};

(:~
 : Check for new records (records not in the eXist database)
 : Convert records to Syriaca.org complient TEI records, using zotero2tei.xqm
 : Save records to the database. 
 : @param $record 
 : @param $index-number
     let $status := local:local-rec-status($record)
    where $status[@status = 'new']
:)
declare function local:process-items($record as node()?, $index-number as xs:integer){
    let $id := local:make-local-uri($record, $index-number)
    let $file-name := concat($index-number,'.xml')
    let $new-record := zotero2tei:build-new-record($record, $id)
    return 
        try {
            <response status="200">
                    <message>{xmldb:store($data-dir, xmldb:encode-uri($file-name), $new-record)}</message>
                </response>
        } catch *{
            <response status="fail">
                <message>Failed to add resource {$id}: {concat($err:code, ": ", $err:description)}</message>
            </response>
        } 
};

(:
 : Check for existing zotero record in eXistdb.
 : NOTE: Not currently used. Cannonical version assumed to live in Zotero, all data in eXist is replaced.  
 : @param $record 
:)
declare function local:local-rec-status($record as node()?){
    let $z-id := string($record/@corresp)
    let $match := collection($data-dir)//tei:idno[. = $z-id]
    return 
        if(collection($data-dir)//tei:idno[. = $z-id]) then 
            <response status="exists"><message>Record already in the eXist database.</message></response>
        else <response status="new"><message>Record does not exist in database.</message></response>
};

(:~
 : Get highest existing local id in the eXist database. Increment new record ids
 : @param $path to existing bibliographic data
 : @param $base-uri base uri defined in repo.xml, establishing pattern for bibl ids. example: http://syriaca.org/bibl 
:)
declare function local:make-local-uri($record as node()?, $index-number as xs:integer) {
    let $all-bibl-ids := 
            for $uri in collection($data-dir)/tei:TEI/tei:text/tei:body/tei:biblStruct/descendant::tei:idno[starts-with(.,$base-uri)]
            return number(replace(replace($uri,$base-uri,''),'/tei',''))
    let $max := max($all-bibl-ids)          
    return
        if($max) then concat($base-uri,'/', ($max + $index-number))
        else concat($base-uri,'/',$index-number)
};

(:~
 : Update stored last modified version in zotero-config.xml
:)
declare function local:update-version($version as xs:string?) {
    try {
            <response status="200">
                    <message>{for $v in $zotero-config//last-modified-version return update value $v with $version}</message>
                </response>
        } catch *{
            <response status="fail">
                <message>Failed to update last-modified-version: {concat($err:code, ": ", $err:description)}</message>
            </response>
        } 
};

(:~
 : Get zotero data. 
:)
declare function local:get-zotero(){
    let $items-info := local:get-zotero-group-items()[1]
    let $total := $items-info/http:header[@name='total-results']/@value
    let $version := $items-info/http:header[@name='last-modified-version']/@value
    let $perpage := 24
    let $pages := xs:integer($total div $perpage)
    let $start := 0
    return 
        if($items-info/@status = '200') then
          (local:get-next($total, $start, $perpage),
           local:update-version($version))
        else <message status="{$items-info/@status}">{$items-info/@message}</message>    
};

(: Helper function to recursively create a collection hierarchy. :)
declare function local:mkcol-recursive($collection, $components) {
    if (exists($components)) then
        let $newColl := concat($collection, "/", $components[1])
        return (
            xmldb:create-collection($collection, $components[1]),
            local:mkcol-recursive($newColl, subsequence($components, 2))
        )
    else ()
};

(: Helper function to recursively create a collection hierarchy. :)
declare function local:mkcol($collection, $path) {
    local:mkcol-recursive($collection, tokenize($path, "/"))
};

if(request:get-parameter('action', '') != '') then
    if(xmldb:collection-available($data-dir)) then
        local:get-zotero()
    else (local:mkcol("/db/apps", replace($data-dir,'/db/apps','')),local:get-zotero())
else 
    <div>
        <p><label>Group ID : </label> {$groupid}</p>
        <p><label>Last Modified Version (Zotero): </label> {$last-modified-version}</p>
        <p><label>Data Directory : </label> {$data-dir}</p>    
    </div>