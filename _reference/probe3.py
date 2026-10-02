# -*- coding: utf-8 -*-
import json, re, urllib.request
BASE = "http://127.0.0.1:9999"
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "ignore")

raw = post(BASE + "/api/fqsearch/books?query=%E5%89%91%E6%9D%A5&count=2&tabType=1", {})
print("搜索(tabType=1)头600字:", raw[:600])
biz = open("/tmp/feed_payload_query.txt", encoding="utf-8").read().strip()
raw2 = post(BASE + "/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": biz})
d = json.loads(raw2)
tabs = (d.get("data") or {}).get("tab_item") or []
print("各tab的 tab_type/tab_index:", [(t.get("title"), t.get("tab_type"), t.get("tab_index")) for t in tabs])
for t in tabs:
    if t.get("title") in ("小说", "漫画"):
        biz2 = re.sub(r"tab_index=-?[0-9]+", "tab_index=%s" % t.get("tab_index"), biz)
        biz2 = re.sub(r"tab_type=-?[0-9]+", "tab_type=%s" % t.get("tab_type"), biz2)
        raw3 = post(BASE + "/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": biz2})
        d3 = json.loads(raw3)
        for tt in (d3.get("data") or {}).get("tab_item") or []:
            cells = tt.get("cell_data") or []
            n = sum(len(ic.get("book_data") or []) for c in cells for ic in (c.get("cell_data") or []))
            if n or cells:
                print("tab[%s]=%s: cells=%d 书=%d" % (tt.get("tab_index"), tt.get("title"), len(cells), n))
                for c in cells[:2]:
                    for ic in (c.get("cell_data") or []):
                        for b in (ic.get("book_data") or [])[:2]:
                            print("   -", b.get("book_name"), "|", b.get("category"), "|", b.get("rank_score") or b.get("sub_info"))

