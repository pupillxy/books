# -*- coding: utf-8 -*-
import json, urllib.request
def get(u):
    return json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent":"okhttp"}), timeout=60).read().decode("utf-8","ignore"))
for fid in ["7638535873541180440"]:
    bi = get("http://127.0.0.1:9999/api/fqnovel/book/" + fid).get("data") or {}
    print("book:", bi.get("bookName"), "| vipBook:", bi.get("vipBook"), "| freeStatus:", bi.get("freeStatus"), "| saleStatus:", bi.get("saleStatus"), "| 新书标记:", bi.get("isNew"))
    dirs = get("http://127.0.0.1:9999/api/fqsearch/directory/" + fid)
    items = ((dirs.get("data") or {}).get("item_data_list")) or []
    print("目录:", len(items), "章")
    if items:
        for idx in (0, len(items)//2, len(items)-1):
            cid = items[idx]["item_id"]
            ch = get("http://127.0.0.1:9999/api/fqnovel/chapter/%s/%s" % (fid, cid))
            cd = ch.get("data") or {}
            print("  第%s章(%s): code=%s %s | %d 字" % (idx+1, items[idx].get("title", "")[:14], ch.get("code"), str(ch.get("message"))[:40], len(cd.get("txtContent") or "")))

