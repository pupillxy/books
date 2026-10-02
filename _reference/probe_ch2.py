# -*- coding: utf-8 -*-
import json, urllib.request
def get(u):
    return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent":"okhttp"}), timeout=60).read().decode("utf-8","ignore")
raw = get("http://127.0.0.1:9999/api/fqsearch/directory/7679083199242193982")
items = (json.loads(raw).get("data") or {}).get("item_data_list") or []
cid = items[0]["item_id"]
full = get("http://127.0.0.1:9999/api/fqnovel/chapter/7679083199242193982/" + cid)
print("完整响应:", full[:600])

