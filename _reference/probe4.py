# -*- coding: utf-8 -*-
import json, urllib.request
req = urllib.request.Request("http://127.0.0.1:9999/api/fqsearch/books?query=%E5%89%91%E6%9D%A5&count=2&tabType=1",
                             headers={"User-Agent": "okhttp"})
raw = urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "ignore")
d = json.loads(raw)
books = (d.get("data") or {}).get("books") or []
print("code:", d.get("code"), "books:", len(books))
if books:
    print(json.dumps(books[0], ensure_ascii=False)[:700])

