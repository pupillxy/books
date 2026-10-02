# -*- coding: utf-8 -*-
import json, urllib.request
def get(u):
    return json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent":"okhttp"}), timeout=60).read().decode("utf-8","ignore"))
raw = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:9999/api/fqapp/fetch",
    data=json.dumps({"path": "/reading/bookapi/bookmall/tab/v", "query": open("/tmp/feed_payload_query.txt").read().strip()}).encode(),
    headers={"Content-Type": "application/json"}), timeout=90).read().decode("utf-8", "ignore")
d = json.loads(raw)
tab = (d.get("data") or {}).get("tab_item", [{}])[0]
books = []
for c in tab.get("cell_data") or []:
    for ic in (c.get("cell_data") or []):
        books += (ic.get("book_data") or [])
b0 = books[0]
fid = b0["book_id"]
print("书:", b0["book_name"], "| book_id:", fid)
dirs = get("http://127.0.0.1:9999/api/fqsearch/directory/" + fid)
items = ((dirs.get("data") or {}).get("item_data_list")) or []
print("目录章节数:", len(items), "| 第1章:", items[0].get("title") if items else "-")
cid = items[0]["item_id"]
ch = get("http://127.0.0.1:9999/api/fqnovel/chapter/%s/%s" % (fid, cid))
cd = ch.get("data") or {}
txt = cd.get("txtContent") or ""
print("第1章正文:", ch.get("code"), "|", len(txt), "字 |", txt[:60])
# 再测最新一章（常被限制的）
cid2 = items[-1]["item_id"]
ch2 = get("http://127.0.0.1:9999/api/fqnovel/chapter/%s/%s" % (fid, cid2))
cd2 = ch2.get("data") or {}
txt2 = cd2.get("txtContent") or ""
print("最新章正文:", ch2.get("code"), "|", len(txt2), "字 |", txt2[:60])

