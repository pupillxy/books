# -*- coding: utf-8 -*-
import json, re, urllib.request
BASE = "http://127.0.0.1:9999"
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "ignore")

raw = post(BASE + "/api/fqsearch/books", {"query": "剑来", "count": 2})
print("搜索原始响应头500字:", raw[:500])
biz = open("/tmp/feed_payload_query.txt", encoding="utf-8").read().strip()
biz2 = re.sub(r"tab_index=-?[0-9]+", "tab_index=1", biz)
raw2 = post(BASE + "/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": biz2})
print("bookmall响应头300字:", raw2[:300])
d = json.loads(raw2)
data = d.get("data") or {}
tabs = data.get("tab_item") or []
print("tab数:", len(tabs), "| titles:", [t.get("title") for t in tabs][:9])
for t in tabs:
    if t.get("tab_index") == 1:
        cells = t.get("cell_data") or []
        print("小说 tab cells:", len(cells))
        for c in cells[:4]:
            inner = c.get("cell_data") or []
            n = sum(len(ic.get("book_data") or []) for ic in inner)
            print("  模块 %r show=%s 书=%d" % (c.get("cell_name"), c.get("show_type"), n))

