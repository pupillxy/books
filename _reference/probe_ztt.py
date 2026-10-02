# -*- coding: utf-8 -*-
import json, urllib.request
def get(u):
    return json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent":"okhttp"}), timeout=60).read().decode("utf-8","ignore"))
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(), headers={"Content-Type":"application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8","ignore"))
s = get("http://127.0.0.1:9999/api/fqsearch/books?query=%E5%B1%B1%E6%B4%9E%E5%8F%8C%E4%BF%AE%E5%90%8E%E6%88%91%E6%97%A0%E6%95%8C%E4%BA%86&count=3&tabType=1")
books = (s.get("data") or {}).get("books") or []
print("搜索命中:", len(books), [b.get("book_name") for b in books][:3])
if not books:
    raise SystemExit
fid = books[0]["book_id"]
bi = get("http://127.0.0.1:9999/api/fqnovel/book/" + fid).get("data") or {}
print("book:", bi.get("bookName"), "| vipBook:", bi.get("vipBook"), "| freeStatus:", bi.get("freeStatus"), "| saleStatus:", bi.get("saleStatus"))
dirs = get("http://127.0.0.1:9999/api/fqsearch/directory/" + fid)
items = ((dirs.get("data") or {}).get("item_data_list")) or []
print("目录:", len(items), "章")
if items:
    cid = items[0]["item_id"]
    ch = get("http://127.0.0.1:9999/api/fqnovel/chapter/%s/%s" % (fid, cid))
    cd = ch.get("data") or {}
    print("第1章:", ch.get("code"), str(ch.get("message"))[:50], "|", len(cd.get("txtContent") or ""), "字")

