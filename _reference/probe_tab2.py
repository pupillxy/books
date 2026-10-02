# -*- coding: utf-8 -*-
import json, re, urllib.request
BASE = "http://127.0.0.1:9999"
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "ignore")
biz = open("/tmp/feed_payload_query.txt", encoding="utf-8").read().strip()
combos = [
    ("原样", []),
    ("idx1_type25", [("tab_index","1"),("tab_type","25")]),
    ("idx1_type25_req1", [("tab_index","1"),("tab_type","25"),("client_req_type","1")]),
    ("idx1_type25_last0", [("tab_index","1"),("tab_type","25"),("last_tab_index","0"),("last_tab_type","2")]),
    ("bottom25", [("bottom_tab_type","25"),("tab_index","1"),("tab_type","25")]),
    ("req_rank1", [("req_rank_category_id","1"),("tab_index","1"),("tab_type","25")]),
]
for name, subs in combos:
    q = biz
    for k, v in subs:
        q = re.sub(k + r"=[^&]*", k + "=" + v, q)
    try:
        d = json.loads(post(BASE + "/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": q}))
        data = d.get("data") or {}
        tabs = data.get("tab_item") or []
        first = tabs[0] if tabs else {}
        nb = sum(len(ic.get("book_data") or []) for c in (first.get("cell_data") or []) for ic in (c.get("cell_data") or []))
        print("%-18s -> tab_index=%s 首tab=%r cells=%d 书=%d" % (name, data.get("tab_index"), first.get("title"), len(first.get("cell_data") or []), nb))
    except Exception as e:
        print("%-18s -> EXC %r" % (name, e))

