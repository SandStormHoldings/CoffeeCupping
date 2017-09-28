#!/usr/bin/env coffee
util = require 'util'
http = require 'http'
async = require 'async'
config = require 'config'
fs = require 'fs'
path = require 'path'
sqlite = require 'sqlite3'
args = require('args-parser') process.argv
l = console.log
w = console.warn

jobname = args.job
user = config.get 'jenkins_user'
pass = config.get 'jenkins_pass'
homepage = config.get('jenkins_homepage')
if user and pass then homepage = util.format homepage, user, pass        

baseurl = homepage + config.get 'jenkins_apipath'

#l 'baseurl is',baseurl
db = new sqlite.Database config.get 'db_filename'

scmrepl = (e) -> e.replace(config.get('scm_baseurl'),'').replace('.git','')
buildscnt=10

header = ['date','job','build_number','built_on','rev','remote','branch','test_class','test_name','test_status','dep_repo','dep_rev','suite_name']
builtonre = /^[\w\-\_]+/i

dbInserts={}
writeDB = (dbInserts,jobName,sqls,outd) ->
        if not dbInserts[jobName]
                w 'initializing dbInserts',jobName #,dbInserts
                dbInserts[jobName]=[]
        dbInserts[jobName].push [sqls,outd]

insertCount=0

flushDBWorker = (jobName,stmt,dt) ->
        new Promise (resolve,reject) ->
                #l '-- dt.length',dt.length
                #stmt+="\n commit;"
                #w 'with',dt.length,'parameters for job',jobName
                #w 'STMT:',stmt #,'ARGS:',dt
                if dt.length
                        #l '-- dt.run on',dt.length
                        db.run stmt,dt ,(err) ->
                                stlen = stmt.split("\n").length
                                insertCount+=stlen
                                #w 'something returned by db.run',err
                                if err then reject err
                                #l '-- inserted',stlen,'statements,',dt.length,'args for',jobName
                                resolve()

flushDB = (dbInserts,job) ->
        w 'in flushDB',job
        if job then cycle = [job]
        else cycle=Object.keys(dbInserts)
        w 'cycle is',cycle
        #throw cycle

        for jobName in cycle
                w 'working job',jobName,'dbInserts',jobName,'is',(dbInserts[jobName] and dbInserts[jobName].length or 0),'items long.'
                stmt = "" #'begin;\n' #+[k[0] for k in dbInserts[jobName]].join(";\n")+"; commit ;"
                dt = []
                cnt=0
                if dbInserts[jobName]
                        for k in dbInserts[jobName]
                                cnt++
                                #l 'cycling through',jobName,k,'which is',dbInserts[jobName][k]
                                if stmt=="" then stmt+=k[0]
                                else stmt+="\n union all select "+["?" for k1 in k[1]].join(", ") #k[0]+";\n"
                                dt = dt.concat k[1]
                                #l 'cnt=',cnt
                                if cnt % 40 == 0
                                        #w 'cnt',cnt
                                        await flushDBWorker jobName,stmt,dt
                                        stmt="" #'begin;'
                                        dt = []

        await flushDBWorker jobName,stmt,dt
        w 'out of flushDB',job,'so far',insertCount,'insert statements'

request = (urlinfo, nocache) ->
        new Promise (resolve,reject) ->
            #throw Error("request "+urlinfo+" nocache="+nocache)
            [url,job] = urlinfo
            tries = 0
            receives = 0

            if not nocache
                if job
                        cachedir = path.join 'cache',job
                else
                        cachedir = 'cache'
                if not fs.existsSync cachedir
                        fs.mkdir cachedir, () ->
                                return request urlinfo,nocache
                urlr = url.replace homepage,''
                cachefn = path.join cachedir,encodeURIComponent(urlr)+'.json'
                if cachefn.length > 300 then throw cachefn+" : too long"

                rt =  fs.existsSync(cachefn)

            if not nocache and rt
                    fs.readFile cachefn,(err,data) ->
                            if err
                                    w "readFile error"
                                    throw err
                            #w 'returning cached version of',url
                            resolve data
                    return
            else
                    w 'hitting up',url
                    #if fs.existsSync cachefn then throw new Error('hitting up?')
                    r = http.get url, (res) ->
                        data = ''
                        res.on "data", (chunk) ->
                            if chunk then data+=chunk
                            receives++
                            if data.length % 100000 == 0 then console.warn 'received data on',url,'so far',data.length,receives,'receives.'


                        res.on "end", (chunk) ->
                            console.warn 'received END on',url,'IN TOTAL',data.length
                            if chunk then data += chunk
                            if not nocache
                                    fs.writeFileSync cachefn,data
                            resolve data

                    r.on 'error' , (err) ->
                        console.warn 'received error on',url
                        console.error "tries: ",tries,"; Could not connect to url: ",url
                        console.error 'error:',err
                        tries++
                        if tries < config.get('max_http_tries')
                                return request urlinfo,nocache
                        else
                                reject "retries limit ",tries," reached for ",url
                                #process.exit()


suitesWorker = (dbInserts,date,jobName,buildData,builton,rev,remote,branch,deprepo,deprev,toDB,suite) ->
        #l 'suitesWorker',buildData.number
        suite.cases.map (c) ->
                while c.name.indexOf(' ')!=-1
                        c.name=c.name.trim().replace ' ','_'
                outd = [date,jobName,buildData.number,builton,rev,remote,branch,c.className.trim(),c.name,c.status,deprepo,deprev,suite.name]
                out = outd.join " "
                dbg={}
                for col,index in header
                        #l 'assigning dbg[',col,'] with index ', index,' of ',outd[index] 
                        dbg[col]=outd[index]

                olen = out.split(" ").length
                if olen!=13
                        l dbg
                        throw new Error("bad output "+olen+" length of '"+out+"'")
                if toDB
                        sqls = 'insert or replace into tbl ('+header.join(",")+') values ('+['?' for k in outd]+")"
                        #l '--',sqls,outd
                        writeDB dbInserts,jobName,sqls,outd
                else
                        l out

testRepParser = (dbInserts,taskEndCB,testrepurl,date,jobName,buildData,builton,rev,remote,branch,deprepo,deprev,toDB,data) ->
        #l 'testRepParser',testrepurl,jobName,buildData.number
        if not data
                next null, {}
                throw Error('am here biatch')
                return
        try
            sdata = data.toString()
            data = JSON.parse data.toString()

        catch e
            data =
            suites: []
            passCount: 'N/A'
            failCount: ''

        if sdata.indexOf('>Not found<')!= -1
                #w "bad sdata ",jobName,"; ",buildData.number
        else if not data.suites and data.childReports
                #throw 'case 1'
                data.childReports.forEach (rep) ->
                        for suite in rep.result.suites
                                suitesWorker dbInserts,date,jobName,buildData,builton,rev,remote,branch,deprepo,deprev,toDB,suite

        else if not data.suites and data.totalCount>0
                w sdata.toString()
                throw 'data.suites is empty, came from '+testrepurl
        else if not data.suites and data.totalCount==0
                w 'data.suites is empty for',jobName
        else
                #throw 'case 2'
                for suite in data.suites
                        suitesWorker dbInserts,date,jobName,buildData,builton,rev,remote,branch,deprepo,deprev,toDB,suite
        #l 'taskEndCB',testrepurl
        taskEndCB()
                        
consoleTextParser = (dbInserts, taskEndCB, auth_bdurl,jobName,date,buildData,builton,rev,remote,branch,toDB,data) ->
        #l 'consoleTextParser',jobName,buildData.number
        subrevre = new RegExp '([a-z]{4,15}) revision ([a-f0-9]{7})','i'
        subrevres = subrevre.exec(data)
        if subrevres
                [deprepo,deprev] = [subrevres[1],subrevres[2]]
        else
                [deprepo,deprev] = [null,null]
        testrepurl = auth_bdurl + 'testReport/api/json'
        data = await request [testrepurl,jobName]
        testRepParser dbInserts,taskEndCB,testrepurl,date,jobName,buildData,builton,rev,remote,branch,deprepo,deprev,toDB,data        

bdProcess = (data,auth_bdurl,jobName,taskEndCB,buildData,toDB) ->
        #l 'we went to ',bdurl
        pdata = JSON.parse data
        date = new Date(pdata.timestamp).toISOString()
        #l date,pdata ; throw 'bye';
        builton = null
        #w 'tabula rasa builton'
        parcnt=0
        if not builton or not builton.length
                for act in pdata.actions
                        if act.parameters
                                for par in act.parameters
                                        parcnt++
                                        if par.name=='NODE'
                                                builton = builtonre.exec(par.value)[0]
                                                #w 'trying to extract from',par.value,' value',builtonre.exec(par.value),'=>',builton
                                                break
        #throw 'builton='+builton
        if not builton and not pdata.builtOn
                builton = null
        else if not builton and pdata.builtOn
                builton = builtonre.exec(pdata.builtOn)[0] #.split(' ')[0]
        if not builton and (pdata.builtOn or parcnt)
                w JSON.stringify(pdata)
                throw new Error("builtOn is empty from pdata")
                #throw "builton is empty on pdata "

                #         builton = pdata.actions[0].parameters[0].value
        #if not builton or not builton.length then throw 'builton empty'
        revisions = pdata.actions.filter( (e) -> typeof e.lastBuiltRevision=='object').map (c) -> c
        if not revisions.length
                #w 'no revisions for',jobName,bdurl
                #throw new Error('no revisions')
                taskEndCB()
                return
        #       l pdata.actions ; throw 'kbye'
        remotes = revisions[0].remoteUrls.map scmrepl
        remote = remotes.join ','
        #console.log 'trying to extract rev from ',revisions[0]
        if not revisions[0].lastBuiltRevision
                w 'no lastBuiltRevision',revisions
                taskEndCB()
                return
        rev = revisions[0].lastBuiltRevision.branch[0].SHA1
        branch = revisions[0].lastBuiltRevision.branch[0].name.replace('origin/','')
        consoleTexturl = auth_bdurl + 'consoleText'
        data = await request [consoleTexturl,jobName], args.noCache
        consoleTextParser dbInserts,taskEndCB,auth_bdurl,jobName,date,buildData,builton,rev,remote,branch,toDB,data                


getTestResults = (dbInserts,taskEndCB,buildData,jobName,toDB) ->
    #l 'getTestResult',jobName,toDB
    return (next) ->
        result = buildData.url.split('://')
        if user and pass
            auth_bdurl = result[0] + "://#{user}:#{pass}@" + result[1]
        else
            auth_bdurl =  buildData.url
        #l 'auth_bdurl',auth_bdurl
        bdurl =  auth_bdurl + 'api/json'
                                                                
        ret = await request [bdurl,jobName]
        bdProcess ret,auth_bdurl,jobName,taskEndCB,buildData,toDB
                
parseJob = (buildFilter,dbInserts,data,toDB) ->
        try
                pdata = JSON.parse data
                jname = pdata.name
                tasks = []
                if pdata.builds
                        tasks = pdata.builds.filter((b) -> not buildFilter or buildFilter==b.number).map (b) ->
                                task = (taskEndCB) ->
                                        getTestResults(dbInserts,taskEndCB,b,jname,toDB) (arg1,arg2) ->
                                                throw Error("should not be here")
                #w 'parallelizing',tasks.length,' tasks for job',jname
                async.parallel tasks, () ->
                                #w 'parallel.final',jname
                                if args.toDB then flushDB dbInserts,jname

        catch e
                w 'could not parse out test results',data.toString()
                w e
                throw e
parseJobCB = (data) -> parseJob args.build,dbInserts,data,args.toDB

parseHomepage = (dbInserts,data) ->
        jobs = JSON.parse(data).jobs
        w 'received',jobs.length,'jobs'
        jobs.forEach (job) ->
                u = util.format baseurl,job.name
                ret = await request [ u, job.name ], !args.forceCache
                parseJobCB ret

homepageInvoke = (args) ->
        goto = homepage+"/api/json"
        php = (data) -> parseHomepage dbInserts,data
        l 'about to go',goto,args.forceCache
        #await sleep 3000
        hpret = await request [goto,null], !args.forceCache
        php hpret

jobInvoke= (jobname,args) ->
        if args.header
                l header.join(' ')
        if not jobname then process.exit(1)
        u = util.format baseurl, jobname
        ret = await request [u,jobname] , !args.forceCache
        parseJobCB ret
        
# forceCache - use cache even for main screen and job queries
# noCache - do not use cache even for individual build queries
        
w 'args',args
if args.exit then process.exit()
if args.header
        l header.join(' ')
else if not jobname
        homepageInvoke args        
else
        jobInvoke jobname,args
