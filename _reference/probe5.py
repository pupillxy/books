# -*- coding: utf-8 -*-
import json, urllib.request
for u in ["/api/fqsearch/books?query=%E5%89%91%E6%9D%A5&count=2",
          "/api/fqsearch/books?query=%E5%89%91%E6%9D%A5&count=2&tabType=1",
          "/api/fqsearch/books?query=%E5%89%91%E6%9D%A5&count=2&tabType=1&q_type=0"]:
    try:
        req = urllib.request.Request("http://127.0.0.1:9999" + u, headers={"User-Agent": "okhttp"})
        raw = urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "ignore")
        print(u[-40:], "->", raw[:260])
    except Exception as e:
        print(u[-40:], "EXC", repr(e)[:100])

