#!/system/bin/sh
echo "== su 10490 id (app context?) =="
su 10490 -c 'id' 2>&1
echo "== try connect 3080 as app uid via su =="
su 10490 -c 'curl -s --max-time 4 -o /dev/null -w "appctx=%{http_code}\n" http://127.0.0.1:3080/' 2>&1
echo "== current shell context =="
id
