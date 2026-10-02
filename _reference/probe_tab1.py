# -*- coding: utf-8 -*-
import json, urllib.request
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "ignore")
raw = post("http://127.0.0.1:9999/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": open("/tmp/feed_payload_query.txt").read().strip()})
d = json.loads(raw)
tabs = (d.get("data") or {}).get("tab_item") or []
for t in tabs:
    if t.get("title") == "小说":
        print("== 小说 tab 全结构 ==")
        print("keys:", list(t.keys()))
        print("bookstore_id:", t.get("bookstore_id"), "| tab_type:", t.get("tab_type"), "| session_id:", str(t.get("session_id"))[:30])
        for i, c in enumerate(t.get("cell_data") or []):
            print("cell[%d]: show=%s name=%r alias=%r" % (i, c.get("show_type"), c.get("cell_name"), c.get("cell_alias")))
            for j, ic in enumerate(c.get("cell_data") or []):
                bds = ic.get("book_data") or []
                print("   inner[%d]: show=%s 书=%d" % (j, ic.get("show_type"), len(bds)))
                if bds:
                    b = bds[0]
                    print("      书:", b.get("book_name"), "|", b.get("author"), "|", b.get("rank_score") or b.get("sub_info"))

