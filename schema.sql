CREATE TABLE "tbl" ("date" TEXT, "job" TEXT, "build_number" TEXT, "built_on" TEXT, "rev" TEXT, "remote" TEXT, "branch" TEXT, "test_class" TEXT, "test_name" TEXT, "test_status" TEXT, "dep_repo" TEXT, "dep_rev" TEXT, "suite_name" TEXT);
create unique index unq on tbl(job,build_number,rev,test_name,suite_name);
