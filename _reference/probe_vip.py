# -*- coding: utf-8 -*-
import json, urllib.request
def get(u):
    return json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent":"okhttp"}), timeout=60).read().decode("utf-8","ignore"))
raw = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:9999/api/fqapp/fetch",
    data=json.dumps({"path": "/reading/bookapi/bookmall/tab/v", "query": open("/tmp/feed_payload_query.txt").read().strip()}).encode(),
    headers={"Content-Type": "application/json"}), timeout=90).read().decode("utf-8", "ignore")
d = json.loads(raw)
tab = (d.get("data") or {}).get("tab_item", [{}])[0]
cells = tab.get("cell_data") or []
books = []
for c in cells:
    for ic in (c.get("cell_data") or []):
        books += (ic.get("book_data") or [])
for b in books[:6]:
    bi = get("http://127.0.0.1:9999/api/fqnovel/book/" + b["book_id"]).get("data") or {}
    print(b.get("book_name"), "| vipBook:", bi.get("vipBook"), "| freeStatus:", bi.get("freeStatus"),
          "| saleStatus:", bi.get("saleStatus"), "| creationStatus:", bi.get("creationStatus"))

