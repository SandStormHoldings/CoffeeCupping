#!/usr/bin/env coffee
l = console.log
sqlite = require 'sqlite3'
fs = require 'fs'
async = require 'async'
stripAnsi = require 'strip-ansi'
Convert = require 'ansi-to-html'
config = require 'config'
convert = new Convert();
args = require('args-parser') process.argv

red = require('./colors.js').red
yellow = require('./colors.js').yellow
orange = require('./colors.js').orange
grey = require('./colors.js').grey
green = require('./colors.js').green


revsqry = fs.readFileSync 'revs.sql'
db = new sqlite.Database config.get 'db_filename'
revs=[] ; urevs=[] ; qry="" ; table = null ; tags = {}; dates = {}
html = '--html' in process.argv

# bicycle ahead warning
class Table
        constructor: (args) ->
                @head = args.head
                @data = []
                @colwidths = args.colwidths
                @aligns = args.aligns
                @defwidth = 10
                # if html then @defwidth = 15

                @defalign = 'left'
                @_row_width=0
        push: (row) ->
                @data.push row
        _draw_hr: () ->
                rt= new Array(@_row_width+1).join('-')+"\n"
        _draw_row: (row) ->
                rt="|"
                cnt=0
                for el in row
                        #l 'drawing ',el,el.toString()
                        cw = if @colwidths[cnt] then @colwidths[cnt] else @defwidth
                        align = if @aligns[cnt] then @aligns[cnt] else @defalign
                        ts = if el==null then '--' else el.toString()
                        sa = stripAnsi(ts)
                        sal = sa.length
                        # if sal > cw and not notrim
                        if sal > cw
                            ts=sa.slice(0,cw-2)+'..'
                            #l 'sliced ',el.toString(),' to ',ts
                        #l 'df = ',cw,'-',sal
                        df =  if cw - sal >=0 then cw - sal else 0
                        #l 'instantiating array '+(df+1)
                        pad = new Array(df+1).join(' ')
                        #l 'pad until ',cw,' is ',pad,' due to stripAnsi length ',sal,' pad="',pad,'"'
                        rt+= if align=='left' then ts + pad else pad+ts
                        rt+="|"
                        cnt+=1
                if not @_row_width then @_row_width=rt.length
                rt+"\n"
        toString: () ->
                #l 'table.toString for a table with ',@head.length,' headers and ',@data.length,' rows of data'
                rt=""
                for h in @head
                        rt+=@_draw_row h
                rt+=@_draw_hr()
                for row in @data
                        rt+=@_draw_row row
                rt+=@_draw_hr()                        
                rt
l 'args',args
        
globaltotals = args.global_totals
repofilter = args.repo
branchfilter = if args.branch then args.branch else ''
spl = (parseInt(li) for li in args.limit.toString().split('/'))
jobfilter = args.job
notrim = args.notrim
revlimit=spl[0]
revoffset=spl[1]
if not revlimit then revlimit=7
if not revoffset then revoffset=0

#console.log notrim ; process.exit()
#console.log "limit",revlimit,"offset",revoffset ; process.exit()

globalcnd='1=1'
if repofilter then globalcnd+=" and remote='"+repofilter+"'"
brspl = ["'"+br+"'" for br in branchfilter.split(",")]
if (branchfilter.indexOf '/') != -1
        globalcnd+=" and job || '/' || branch in ("+brspl+")"
else if branchfilter then globalcnd+=" and branch in ("+brspl+")"
if jobfilter then globalcnd+=" and job='"+jobfilter+"'"

tagsqry = "select repo,rev,tags from tags where repo='REPO' and rev in (REVS)"
obtain_tags = (cb) ->
        #tagsqryf = tagsqry.toString().replace('
        myrevs = ["'"+u.rev+"'" for u in urevs]
        #l 'revs',myrevs
        tq = tagsqry.toString().replace('REPO',repofilter).replace('REVS',(myrevs).join(","))
        l 'query',tq
        db.each tq,
                (err,row) ->
                        #l 'row',row
                        tags[row.rev]=row.tags.split(",")
                        #l 'mytags',row.rev,mytags[row.rev]
        #l repofilter
        cb()

obtain_dates = (cb) ->
        # l revs;
        myrevs = ["'"+u.rev+"'" for u in urevs]
        dates_q = "select max(date) as last_date, rev from tbl where rev in (REVS) group by rev".toString().replace('REVS', (myrevs).join(","))
        #l '--',dates_q; process.exit()
        db.each dates_q,
                (err,row) ->
                        # dates[row.rev] = row.last_date {'date': }
                        dates[row.rev] = {'date': row.last_date.split('T')[0], 'time':row.last_date.split('T')[1]}

        cb()


obtain_revs = (cb) ->
        #l '-- obtaining revisions'
        revsqr = revsqry.toString().replace('CND',globalcnd).replace('LIM',revlimit).replace('OFFSET',revoffset)
        #l revsqr ; process.exit()
        db.each revsqr.toString()
                ,(err,row) ->
                        if err then throw err
                        revs.push row
                ,(err,cntx) ->
                        if err then throw err                        

                        urevs = revs
                        urevs = urevs.slice(0,revlimit)
                        cw = [tnmaxlen].concat ((if notrim then 15 else 7) for u in urevs).concat [10]
        
                        head = ['revisions'].concat( (u.srev for u in urevs)).concat ['tot']
                        head2 = ['d.repos'].concat(u.dep_repo for u in urevs)
                        head3 = ['d.revs'].concat((u.dep_rev for u in urevs))
                        branches = ['branches'].concat( (u.branch for u in urevs))
                        table = new Table
                                head:  [head,head2,head3,branches]
                                aligns:['left'].concat( ('right' for u in urevs)).concat ['right'] 
                                colwidths: cw
                        cb()

tnmaxlen = 72
if html then tnmaxlen = 128

build_gen_qry = (group,countbuilds) ->
        if not urevs.length then throw "no urevs" 
        #l '-- building query, group:',group

        sums=[] ; stats=[]

        buildsqryhead="select tn \n"
        urevs.forEach (el) ->
                fn = 'r'+el.srev
                if countbuilds
                        sumstr = ",count(distinct "+fn+") as "+fn+" --sum\n"
                else
                        sumstr = ",sum(case when "+fn+"='PASSED' then 1 else 0 end) || ':' || sum(case when "+fn+"='FAILED' then 1 else 0 end) as "+fn+" -- sum\n"
                sums.push sumstr
                #l sumstr.trim()
        buildsqrymid="
        ,sum(pass) || ':' || sum(fail) pf\n

        from ( \n
        select \n
        test_class || '.' || test_name tn \n
        ,(case when test_status='PASSED' then 1 else 0 END) pass\n
        ,(case when test_status='FAILED' then 1 else 0 END) fail\n"
        urevs.forEach (el) ->
                #l el
                fn = "r"+el.srev
                cnd = el.r
                if countbuilds
                        cndstr =
                        ",case when remote || ':' || branch || '/' || substr(rev,1,5) || ifnull(',' || dep_repo,'') || substr(ifnull(':' || dep_rev,''),1,5) = '"+cnd+"' then job || '.' || build_number else null end "+fn+" -- cnd\n"
                else
                        cndstr =
                        ",case when remote || ':' || branch || '/' || substr(rev,1,5) || ifnull(',' || dep_repo,'') || substr(ifnull(':' || dep_rev,''),1,5) = '"+cnd+"' then test_status else null end "+fn+" -- cnd\n"
                stats.push cndstr
                #l cndstr.trim()

        addcnd=if not globaltotals then " and rev in (REVLIST)".replace('REVLIST',["'"+r.rev+"'" for r in urevs]) else ""
        buildsqrytail="from tbl
        where CND \n
        ) foo \n"
        buildsqrytail+=if group then "group by tn\n" else ""
        buildsqrytail+=" order by sum(fail) desc;"
        buildsqrytail=buildsqrytail.replace 'CND',(globalcnd+addcnd)
        qry = buildsqryhead+ sums.join("")+buildsqrymid+stats.join("")+buildsqrytail
        #l qry ; process.exit()
build_data_qry = (cb) ->
        build_gen_qry true
        cb()
build_tot_qry = (cb) ->
        build_gen_qry false
        cb()
build_buildcount_qry = (cb) ->
        build_gen_qry false,true
        cb()        
#auxiliary tool
parse_cell = (v) ->
        #return v
        [pass,fail] = (parseInt(n) for n in v.split(':'))
        tp =''
        if pass and not fail then tp=green v,true
        else if pass and fail then tp=orange v,true
        else if fail and not pass then tp=red v,true
        else if not pass and not fail then tp=grey v,true
        return tp
perform_data_qry = (cb) ->
        db.each qry
                ,(err,row) ->
                        if err then throw err
                        outr = []
                        for k,v of row
                                #l 'index',k,v #k.indexOf 'r'
                                if k.indexOf('r')==0 or k=='pf'
                                        pc = parse_cell v
                                        outr.push pc
                                else if k=='tn'
                                        if v.length>tnmaxlen and not notrim
                                                outr.push v.slice(0,tnmaxlen)+'..'
                                        else
                                                outr.push v
                                else
                                        outr.push v
                                        #process.stdout.write pc.toString()+"\n"
                        #l 'adding row to table, which is now ',table.data.length,'long'
                        table.push outr
                ,(err,cntx) ->
                        if err
                                l qry
                                throw err
                        #l cntx,'results'
                        cb()
perform_buildcount_qry = (cb) ->
        db.each qry
                ,(err,row) ->
                        tothdr = (v for k,v of row)
                        tothdr[0]='builds'
                        table.head.push tothdr
                ,(err,cntx) ->
                        #l cntx,'totals rows :P'
                        cb()
                                
perform_tot_qry = (cb) ->
        db.each qry
                ,(err,row) ->
                        tothdr = (parse_cell(v) for k,v of row)
                        tothdr[0]='tests \\ totals'
                        table.head.push tothdr
                ,(err,cntx) ->
                        #l cntx,'totals rows :P'
                        cb()
                                
display_results = (cb) ->
        ttp1 = ['qa-approved']
        ttp = [(if rev.rev and rev.rev in tags and /-approved/.test(tags[rev.rev].join(",")) then 'Y' else '') for rev in urevs][0]
        dates_date = [dates[rev.rev].date for rev in urevs][0]
        dates_time = [dates[rev.rev].time for rev in urevs][0]
        #l ttp, 'length',ttp.length
        thead = ttp1.concat ttp
        table.head.push(thead)
        thead = ['last-build-date'].concat dates_date
        table.head.push(thead)
        thead = ['last-build-time'].concat dates_time
        table.head.push(thead)
        if html then process.stdout.write convert.toHtml("<pre>" + table.toString()+"</pre>\n")
        else process.stdout.write table.toString()+"\n"

        #l cntx,'-- rows'
series = [obtain_revs]
if config.get 'obtain_tags'
        series = series.concat [obtain_tags]
series = series.concat [ obtain_dates,
        build_data_qry,
        perform_data_qry,
        build_buildcount_qry,
        perform_buildcount_qry,
        build_tot_qry,
        perform_tot_qry,
        display_results]
#l series.length ; process.exit()
async.series series

