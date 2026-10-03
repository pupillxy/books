# -*- coding: utf-8 -*-
import json, re, urllib.request
BASE = "http://127.0.0.1:9999"
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "ignore")
biz = open("/tmp/feed_payload_query.txt", encoding="utf-8").read().strip()
for off in ["2", "4"]:
    q = re.sub(r"offset=[0-9]+", "offset=" + off, biz)
    q = re.sub(r"page_entry_time=[0-9]+", "page_entry_time=0", q)
    d = json.loads(post(BASE + "/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": q}))
    data = d.get("data") or {}
    tabs = data.get("tab_item") or []
    t0 = tabs[0] if tabs else {}
    cells = t0.get("cell_data") or []
    print("=== offset=%s -> code=%s tab_index=%s cells=%d" % (off, d.get("code"), data.get("tab_index"), len(cells)))
    for c in cells:
        inner = c.get("cell_data") or []
        n = sum(len(ic.get("book_data") or []) for ic in inner)
        print("   模块 %r show=%s 内层=%d 书=%d next=%s" % (c.get("cell_name"), c.get("show_type"), len(inner), n, c.get("next_offset")))

