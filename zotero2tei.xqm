xquery version "3.0";
(:
 : Modified by wsalesky for automation of workflow 
 : Used with get-zotero-data.xql
:)

(:
    Convert TEI exported from Zotero to Syriaca TEI bibl records. 
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
     
(: KNOWN ISSUES
    - If a bibl record already exists with the same Zotero ID, it is not overwritten, 
        but subject tags are added to the existing record. 
    - Subject tags (which contain the URI of a record which should cite the bibl) are merely 
        kept as note[@type='tag']. They should be further processed with an additional script
        to add them to the appropriate record. See add-citation-from-zotero-subject.xql
    - This script may produce duplicate subject tags. :)
module namespace zotero2tei="http://syriaca.org/zotero2tei";

declare default element namespace "http://www.tei-c.org/ns/1.0";
declare namespace tei = "http://www.tei-c.org/ns/1.0";
declare namespace functx = "http://www.functx.com";

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
declare function zotero2tei:build-new-record($rec as item()*, $local-id) {
(: Titles from zotero record:)
let $titles-all := $rec//title[not(@type='short')]
(: Local ID and URI :)
let $local-uri := <idno type='URI'>{$local-id}</idno>        
(:    Uses the Zotero ID (manually numbered tag) to add an idno with @type='zotero':)
let $zotero-idno := <idno type='zotero'>{$rec/note[@type='tags']/note[@type='tag' and matches(.,'^\d+$')]/text()}</idno>
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
                    {$titles-all}
                    <sponsor>Syriaca.org: The Syriac Reference Portal</sponsor>
                    <funder>The National Endowment for the Humanities</funder>
                    <funder>The International Balzan Prize Foundation</funder>
                    <principal>David A. Michelson</principal>
                    <editor role="general" ref="http://syriaca.org/documentation/editors.xml#dmichelson">David A. Michelson</editor>
                    <editor role="general" ref="http://syriaca.org/documentation/editors.xml#ngibson">Nathan P. Gibson</editor>
                    <editor role="creator" ref="http://syriaca.org/documentation/editors.xml#ngibson">Nathan P. Gibson</editor>
                    <respStmt>
                        <resp>Bibliography curation and TEI record generation by</resp>
                        <name ref="http://syriaca.org/documentation/editors.xml#ngibson">Nathan P. Gibson</name>
                    </respStmt>
                </titleStmt>
                <publicationStmt>
                    <authority>Syriaca.org: The Syriac Reference Portal</authority>
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
declare function zotero2tei:build-new-record-json($rec, $local-id) {
(: Titles from zotero record:)
let $titles-all := for $t in $rec?data?title
                   return <title>{$t}</title>
(: Local ID and URI :)
let $local-uri := <idno type='URI'>{$local-id}</idno>        
(:    Uses the Zotero ID (manually numbered tag) to add an idno with @type='zotero':)
let $zotero-idno := <idno type='zotero'>{$rec?links?alternate?href}</idno>  
(:    Grabs URI in tags prefixed by 'Subject: '. :)
let $subject-uri := $rec?data?tags?*?tag[matches(.,'^\s*Subject:\s*')]
return     
    <TEI xmlns="http://www.tei-c.org/ns/1.0">
        <teiHeader>
            <fileDesc>
                <titleStmt>
                    {$titles-all}
                    <sponsor>Syriaca.org: The Syriac Reference Portal</sponsor>
                    <funder>The National Endowment for the Humanities</funder>
                    <funder>The International Balzan Prize Foundation</funder>
                    <principal>David A. Michelson</principal>
                    <editor role="general" ref="http://syriaca.org/documentation/editors.xml#dmichelson">David A. Michelson</editor>
                    <editor role="general" ref="http://syriaca.org/documentation/editors.xml#ngibson">Nathan P. Gibson</editor>
                    <editor role="creator" ref="http://syriaca.org/documentation/editors.xml#ngibson">Nathan P. Gibson</editor>
                    <respStmt>
                        <resp>Bibliography curation and TEI record generation by</resp>
                        <name ref="http://syriaca.org/documentation/editors.xml#ngibson">Nathan P. Gibson</name>
                    </respStmt>
                </titleStmt>
                <publicationStmt>
                    <authority>Syriaca.org: The Syriac Reference Portal</authority>
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
                  {'To be done'}
                </biblStruct>
            </body>
        </text>
    </TEI>
};

declare function zotero2tei:build-new-record($rec as item()*, $local-id as xs:string?, $format as xs:string?){
    if($format = 'json') then
        zotero2tei:build-new-record-json($rec, $local-id)
    else zotero2tei:build-new-record($rec, $local-id)
};