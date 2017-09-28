select 
 remote || ':' || branch || '/' || substr(rev,1,5) || ifnull(',' || dep_repo,'') || substr(ifnull(':' || dep_rev,''),1,5) r
,remote || ':' || branch || '/' || rev             || ifnull(',' || dep_repo,'') || ifnull(':' || dep_rev,'')             combined
,substr(rev,1,5) srev
,branch branch
,remote remote
,rev rev
,dep_rev dep_rev
,dep_repo dep_repo
,count(*) 
from tbl 
where CND
group by rev,dep_rev order by date desc
limit LIM offset OFFSET;
