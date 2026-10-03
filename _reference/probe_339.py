# -*- coding: utf-8 -*-
import json, urllib.request
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "ignore")
biz = open("/tmp/feed_payload_query.txt", encoding="utf-8").read().strip()
d = json.loads(post("http://127.0.0.1:9999/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": biz}))
tab = (d.get("data") or {}).get("tab_item", [{}])[0]
rec = tab.get("cell_data")[1]
inner = rec.get("cell_data")[0]
cc = inner.get("cell_data") or []
c0 = cc[0]
print("cell keys:", list(c0.keys()))
for k, v in c0.items():
    if v not in (None, "", [], {}):
        s = json.dumps(v, ensure_ascii=False)
        print(k, "=", s[:160])

