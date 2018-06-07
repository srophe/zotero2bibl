xquery version "3.1";
(:
 : Modified by wsalesky for automation of workflow 
 : Used with get-zotero-data.xql
:)

(:
    Convert TEI/JSON exported from Zotero to Syriaca TEI bibl records. 
    This script makes the following CHANGES to TEI exported from Zotero: 
     - Adds a Syriaca.org URI as an idno and saves each biblStruct as an individual file.
     - Uses the Zotero ID (manually numbered tag) to add an idno with @type='zotero'
     - Changes the biblStruct/@corresp to an idno with @type='URI'
     - Changes tags starting with 'Subject: ' to <note type="tag">Subject: ...</note> 
     - Changes 1 or more space-separated numbers contained in idno[@type='callNumber'] to WorldCat URIs 
     - Separates multiple ISBN numbers into multiple idno[@type='ISBN'] elements
     - Changes URLs into refs. If a note begins with 'Vol: http' or 'URL: http' these are also converted into 
        refs, with the volume number as the ref text node.
     - Changes biblScope units for volumes and pages to Syriaca norms. (These could be changed but if so 
        should be done across all bibl records.
     - Changes respStmts with resp='translator' to editor[@role='translator']
:)
module namespace zotero2tei="http://syriaca.org/zotero2tei";
import module namespace http="http://expath.org/ns/http-client";
declare default element namespace "http://www.tei-c.org/ns/1.0";
declare namespace tei = "http://www.tei-c.org/ns/1.0";
declare namespace functx = "http://www.functx.com";

(: Access zotero-api configuration file :) 
declare variable $zotero2tei:zotero-api := 'https://api.zotero.org';
declare variable $zotero2tei:zotero-config := doc('zotero-config.xml');

(:~ 
 : Simple typeswitch to transform specific Zotero elements into to Syriaca.org TEI elements
 : @param $node 
:)
declare function zotero2tei:tei2tei($nodes as node()*) as item()* {
    for $node in $nodes
    return 
        typeswitch($node)
            case text() return $node
            case comment() return ()
            case element(persName) return 
                if($node[parent::resp[.='translator']]) then 
                  element editor {attribute role {'translator'},$node/node()}  
                else zotero2tei:tei2tei($node/node())
            case element(note) return
                let $vol-regex := '^\s*[Vv][Oo][Ll]\.*\s*(\d+)\s*:\s*http.*'
                let $url-regex := '^\s*[Uu][Rr][Ll]*\s*:\s*http.*' 
                let $link-text := if (matches($node, $vol-regex)) then replace($node,$vol-regex,'Vol. $1') else ()
                let $link := replace($node,'^[A-Za-z:\d\s\.]*(http.*).*?$','$1')
                return 
                    if($node/@type = 'url' or matches($node,$vol-regex) or matches($node,$url-regex)) then 
                        element ref {attribute target {$link}, $link-text}
                    else zotero2tei:tei2tei($node/node())                     
            case element(title) return 
                if(not($node/@type='short')) then 
                    zotero2tei:tei2tei($node/node())
                else ()
            case element(biblScope) return 
                if($node[@unit='volume']) then 
                    element {xs:QName(name($node))} {
                        $node/@*[name() != 'unit'], attribute {xs:QName('unit')} {'vol'}, 
                        $node/node()}
                else if($node[@unit='page']) then
                    element {xs:QName(name($node))} {
                        $node/@*[name() != 'unit'], attribute {xs:QName('unit')} {'pp'}, 
                        $node/node()}     
                else element {xs:QName(name($node))} {$node/@*,  zotero2tei:tei2tei($node/node())}
            case element(*) return element {xs:QName(name($node))} {$node/@*,  zotero2tei:tei2tei($node/node())}    
            default return zotero2tei:tei2tei($node/node())
};

(:~
 : Build new TEI record form TEI
 : @param $rec TEI record from Zotero
 : @param $local-id local record id 
:)
declare function zotero2tei:build-new-record($rec as item()*, $local-id as xs:string) {
(: Titles from zotero record:)
let $titles-all := $rec//title[not(@type='short')]
(: Local ID and URI :)
let $local-uri := <idno type='URI'>{$local-id}</idno>        
(:    Uses the Zotero ID (manually numbered tag) to add an idno with @type='zotero':)
let $zotero-idno := <idno type='URI'>{$rec/note[@type='tags']/note[@type='tag' and matches(.,'^\d+$')]/text()}</idno>
(:    Changes the biblStruct/@corresp to an idno with @type='URI':)
let $zotero-idno-uri := <idno type='URI'>{string($rec/@corresp)}</idno>    
(:    Grabs URI in tags prefixed by 'Subject: '. :)
let $subject-uri := $rec/note[@type='tags']/note[@type='tag' and matches(.,'^\s*Subject:\s*')]
(:    Changes 1 or more space-separated numbers contained in idno[@type='callNumber'] to WorldCat URIs :)
let $callNumber-idnos := 
        for $num in $rec/idno[@type='callNumber']
        return
            if (matches($num/text(),'^([\d]\s*)+$')) then
                for $split-num in tokenize($num/text(), ' ')
                return <idno type='URI'>{concat('http://www.worldcat.org/oclc/',$split-num)}</idno>
            else $num
let $issn-idnos := $rec/idno[@type='ISSN']
(:    Separates multiple ISBN numbers into multiple idno[@type='ISBN'] elements :)
let $isbns := tokenize(normalize-space($rec/idno[@type='ISBN']/text()),'\s')
let $isbn-idnos := 
        for $isbn in $isbns
        return <idno type='ISBN'>{$isbn}</idno>        
let $all-idnos := ($local-uri,$zotero-idno,$zotero-idno-uri,$callNumber-idnos,$issn-idnos,$isbn-idnos)
(:    Reconstructs record using transformed data. :)
let $tei-analytic :=
        if ($rec/analytic) then
            <analytic>{
                $rec/analytic/(author|editor),
                zotero2tei:tei2tei($rec/analytic/respStmt),
                $rec/analytic/title,
                $all-idnos[.!=''],
                $rec/analytic/descendant::note
            }</analytic>
        else()
let $tei-monogr :=
        if ($rec/monogr) then
            <monogr>{
                $rec/monogr/(author|editor),
                zotero2tei:tei2tei($rec/monogr/respStmt),
                $rec/monogr/title[not(@type='short')],
                if ($tei-analytic) then () else ($all-idnos[.!=''],zotero2tei:tei2tei($rec/monogr/descendant::note)),
                element imprint {$rec/monogr/imprint/*[not(name()='biblScope') and not(name()='note')]},
                zotero2tei:tei2tei($rec/monogr/imprint/biblScope)
            }</monogr>
        else()
let $tei-series :=
        if ($rec/series) then
            <series>{
                $rec/series/(author|editor),
                $rec/series/title[not(@type='short')],
                zotero2tei:tei2tei($rec/series/biblScope)
            }</series>
        else()
return     
    <TEI xmlns="http://www.tei-c.org/ns/1.0">
        <teiHeader>
            <fileDesc>
                <titleStmt>
                    {($titles-all,
                    $zotero2tei:zotero-config//*:sponsor,
                    $zotero2tei:zotero-config//*:funder,
                    $zotero2tei:zotero-config//*:principal,
                    $zotero2tei:zotero-config//*:editor,
                    $zotero2tei:zotero-config//*:respStmt)}
                </titleStmt>
                <publicationStmt>
                    <authority>{$zotero2tei:zotero-config//*:sponsor/text()}</authority>
                    <idno type="URI">{$local-id}/tei</idno>
                    <availability>
                        <licence target="http://creativecommons.org/licenses/by/3.0/">
                            <p>Distributed under a Creative Commons Attribution 3.0 Unported License.</p>
                        </licence>
                    </availability>
                    <date>{current-date()}</date>
                </publicationStmt>
                <sourceDesc>
                    <p>Born digital.</p>
                </sourceDesc>
            </fileDesc>
            <revisionDesc>
                <change who="http://syriaca.org/documentation/editors.xml#autogenerated" when="{current-date()}">CREATED: This bibl record was autogenerated from a Zotero record.</change>
            </revisionDesc>
        </teiHeader>
        <text>
            <body>
                <biblStruct>
                    {$tei-analytic}
                    {$tei-monogr}
                    {$tei-series}
                    {$subject-uri[.!='']}
                </biblStruct>
            </body>
        </text>
    </TEI>
};

(:~
 : Build new TEI record from JSON
 : @param $rec JSON record from Zotero
 : @param $local-id local record id 
 : NOTE needs to be completed. 
 : Sample JSON from Zotero at json-example.json
:)
declare function zotero2tei:build-new-record-json($rec as item()*, $local-id as xs:string) {
let $ids :=  tokenize($rec?links?alternate?href,'/')[last()]
let $local-id := if($ids != '') then concat($zotero2tei:zotero-config//*:base-uri/text(),'/',$ids) else $local-id
let $itemType := $rec?data?itemType
let $recordType := 	
    if($itemType = 'book' and $rec?data?series[. != '']) then 'monograph'
    else if($itemType = ('journalArticle','bookSection','magazineArticle','newspaperArticle','conferencePaper') or $rec?data?series != '') then 'analytic' 
    else 'monograph' 
(: Main titles from zotero record:)
let $analytic-title := for $t in $rec?data?title
                       return 
                            element { xs:QName("title") } {
                             if($recordType = 'analytic') then attribute level { "a" }
                             else if($recordType = 'monograph') then attribute level { "m" } 
                             else (), $t}
let $series-titles :=  (for $series in $rec?data?series[. != ''] 
                        return 
                            element { xs:QName("title") } {
                            if($recordType = 'monograph') then attribute level { "s" }
                            else (), $series},
                        for $series in $rec?data?seriesTitle[. != ''] 
                        return 
                            element { xs:QName("title") } {
                            if($recordType = 'monograph') then attribute level { "s" }
                            else (), $series})
let $journal-titles :=  for $journal in $rec?data?publicationTitle[. != '']
                        return <title level="j">{$journal}</title>                        
let $titles-all := ($analytic-title,$series-titles,$journal-titles)
(: Local ID and URI :)
let $local-uri := <idno type="URI">{$local-id}</idno>   
(:    Uses the Zotero ID (manually numbered tag) to add an idno with @type='zotero':)
let $zotero-idno := <idno type="URI">{$rec?links?alternate?href}</idno>  
(:  Equals the biblStruct/@corresp URI to idno with @type='URI' :)
let $zotero-idno-uri := <idno type="URI">{replace($rec?links?self?href,'api.zotero.org','www.zotero.org')}</idno>
(:  Grabs URI in tags prefixed by 'Subject: '. :)
let $subject-uri := $rec?data?tags?*?tag[matches(.,'^\s*Subject:\s*')]
(:  Not sure here if extra is always the worldcat-ID and if so, if or how more than one ID are structured, however: converted to worldcat-URI :)
let $worldcat-uri := 
                    (
                    for $oclc in $rec?data?extra[matches(.,'^OCLC:\s*')]
                    return <idno type="URI">{concat("http://www.worldcat.org/oclc/",normalize-space(substring-after($oclc,'OCLC: ')))}</idno>,
                    for $num in $rec?data?extra[matches(.,'^([\d]\s*)')]
                    return <idno type="URI">{"http://www.worldcat.org/oclc/" || $num}</idno>)                       
let $refs := for $ref in $rec?data?url[. != '']
             return <ref target="{$ref}"/>                
let $all-idnos := ($local-uri,$zotero-idno,$zotero-idno-uri,$worldcat-uri,$refs)

(: organizing creators by type and name :)
let $creator := for $creators in $rec?data?creators?*
                return element {$creators?creatorType} {element forename {$creators?firstName}, element surname{$creators?lastName}}
(: creating imprint, any additional data required here? :)
let $imprint := if (empty($rec?data?place) and empty($rec?data?publisher) and empty($rec?data?date)) then () else (<imprint>{
                    if ($rec?data?place) then (<pubPlace>{$rec?data?place}</pubPlace>) else (),
                    if ($rec?data?publisher) then (<publisher>{$rec?data?publisher}</publisher>) else (),
                    if ($rec?data?date) then (<date>{$rec?data?date}</date>) else ()
                }</imprint>)
(: Transforming tags to relation... if no subject or ms s present, still shows <listRelations\>, I have to fix that :)
let $list-relations := if (empty($rec?data?tags)) then () else (<listRelation>{
                        for $tag in $rec?data?tags?*?tag
                            return if (matches($tag,'^\s*(MS|Subject|Part|Section|Book):\s*')) then (
                                element relation {
                                    attribute active {$local-uri},
                                    if (matches($tag,'^\s*(Subject|Part|Section|Book):\s*')) then (
                                        let $type := replace($tag,'^\s*(.+?):\s*.*','$1')
                                        return
                                        (attribute ref {"dc:subject"},
                                        if (string-length($type)) then 
                                            attribute type {lower-case($type)}
                                            else(),
                                        element desc {substring-after($tag,concat($type,": "))}
                                    )) else (),
                                    if (matches($tag,'^\s*MS:\s*')) then (
                                        attribute ref{"dcterms:references"},
                                        element desc {
                                            element bibl {substring-after($tag,"MS: ")}
                                        }
                                    ) else ()
                                }
                            ) else ()
                    }</listRelation>)
(: Not sure if that is sufficient for an analytic check? following the TEI-guideline and the other script @github... :)
let $tei-analytic := if($recordType = 'analytic') then
                         <analytic>{
                             $creator,
                             $analytic-title,
                             $all-idnos
                         }</analytic>
                         else ()
let $tei-monogr := if ($recordType = "analytic" or $recordType = "monograph") then
                    <monogr>{
                        if($recordType = "analytic") then ()
                        else $creator,
                        if($recordType = "monograph") then $analytic-title
                        else ($series-titles,$journal-titles),
                        if ($tei-analytic) then () else ($all-idnos),
                        if ($imprint) then ($imprint) else (),
                        for $p in $rec?data?pages[. != '']
                        return <biblScope unit="pp">{$p}</biblScope>,
                        for $vol in $rec?data?volume[. != '']
                        return <biblScope unit="vol">{$vol}</biblScope>
                    }</monogr> else ()
(: I haven't found an example file with series information to find the JSON equivalence to the tei structure, so have to continue on that :)
let $tei-series := if($series-titles and $recordType = "monograph") then 
                        <series>{$series-titles}</series>
                    else()                        
let $citedRange := for $p in $rec?data?tags?*?tag[matches(.,'^\s*PP:\s*')]
                   return <citedRange unit="page" xmlns="http://www.tei-c.org/ns/1.0">{substring-after($p,'PP: ')}</citedRange>
let $abstract :=   for $a in $rec?data?abstractNote[. != ""]
                   return <note type="abstract" xmlns="http://www.tei-c.org/ns/1.0">{$a}</note>
let $getNotes := <citedRange>Hey, this one has kids!</citedRange>(:
                if($rec?meta?numChildren[. gt 0]) then
                    let $url := concat($zotero2tei:zotero-api,'/groups/',$zotero2tei:zotero-config//*:groupid/text(),'/items/',tokenize($local-id,'/')[last()],'/children') 
                    let $children := http:send-request(<http:request http-version="1.1" href="{xs:anyURI($url)}" method="get"/>)
                    return 
                        if($children[1]/@status = '200') then 
                                    let $notes := parse-json(util:binary-to-string($children[2]))
                                    for $n in $notes?*
                                    return 
                                        if($n?data?note[matches(.,'^<p>PP:')]) then 
                                            <citedRange unit="page">{replace(substring-after($n?data?note[matches(.,'^<p>PP:')],'PP: '),'<[^>]*>','')}</citedRange>
                                        else ()
                             else()
                else ():)
return     
    <TEI xmlns="http://www.tei-c.org/ns/1.0">
        <teiHeader>
            <fileDesc>
                <titleStmt>{(
                    $titles-all,
                    $zotero2tei:zotero-config//*:sponsor,
                    $zotero2tei:zotero-config//*:funder,
                    $zotero2tei:zotero-config//*:principal,
                    $zotero2tei:zotero-config//*:editor,
                    (: Editors :)
                    for $e in $rec?meta?createdByUser
                    let $uri := $e?links?*?href
                    let $name := if($e?name[. != '']) then $e?name else $e?username
                    return
                        <editor role="creator" ref="{$uri}">{$name}</editor>,
                    for $e in $rec?meta?lastModifiedByUser
                    let $uri := $e?links?*?href
                    let $name := if($e?name[. != '']) then $e?name else $e?username
                    return
                        <editor role="creator" ref="{$uri}">{$name}</editor>,
                    for $e in $rec?data?tags?*?tag[starts-with(.,'Assigned:')]
                    let $assigned := substring-after($e, 'Assigned: ')
                    where $assigned != $rec?meta?createdByUser?username
                    return
                        <editor role="creator" ref="https://www.zotero.org/{$assigned}">{$assigned}</editor>,
                    (: respStmt :)
                    for $e in $rec?meta?createdByUser
                    let $uri := $e?links?*?href
                    let $name := if($e?name[. != '']) then $e?name else $e?username
                    return
                        <respStmt><resp>Record added to Zotero by</resp><name ref="{$uri}">{$name}</name></respStmt>,
                    for $e in $rec?meta?lastModifiedByUser
                    let $uri := $e?links?*?href
                    let $name := if($e?name[. != '']) then $e?name else $e?username
                    return
                        <respStmt><resp>Record edited in Zotero by</resp><name ref="{$uri}">{$name}</name></respStmt>,
                    for $e in $rec?data?tags?*?tag[starts-with(.,'Assigned:')]
                    let $assigned := substring-after($e, 'Assigned: ')
                    where $assigned != $rec?meta?createdByUser?username
                    return 
                        <respStmt><resp>Primary editing by</resp><name ref="https://www.zotero.org/{$assigned}">{$assigned}</name></respStmt>
                    )}</titleStmt>
                <publicationStmt>
                    <authority>{$zotero2tei:zotero-config//*:sponsor/text()}</authority>
                    <idno type="URI">{$local-id}/tei</idno>
                    {$zotero2tei:zotero-config//*:availability}
                    <date>{current-date()}</date>
                </publicationStmt>
                <sourceDesc>
                    <p>Born digital.</p>
                </sourceDesc>
            </fileDesc>
            <revisionDesc>
                <change who="http://syriaca.org/documentation/editors.xml#autogenerated" when="{current-date()}">CREATED: This bibl record was autogenerated from a Zotero record.</change>
            </revisionDesc>
        </teiHeader>
        <text>
            <body>
                <biblStruct>
                  {$tei-analytic}
                  {$tei-monogr}
                  {$tei-series}
                  {$abstract}
                  {$citedRange}
                  {$getNotes}
                </biblStruct>
                {$list-relations}
            </body>
        </text>
    </TEI>
};

declare function zotero2tei:build-new-record($rec as item()*, $local-id as xs:string?, $format as xs:string?){
    if($format = 'json') then
        zotero2tei:build-new-record-json($rec, $local-id)
    else zotero2tei:build-new-record($rec, $local-id)
};
