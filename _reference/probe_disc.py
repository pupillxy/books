# -*- coding: utf-8 -*-
import json, urllib.request
def get(u):
    return json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent":"okhttp"}), timeout=60).read().decode("utf-8","ignore"))
# 对照组：之前成功过的书
dirs = get("http://127.0.0.1:9999/api/fqsearch/directory/7646327973087300670")
items = ((dirs.get("data") or {}).get("item_data_list")) or []
cid = items[0]["item_id"]
ch = get("http://127.0.0.1:9999/api/fqnovel/chapter/7646327973087300670/" + cid)
cd = ch.get("data") or {}
print("对照书第1章:", ch.get("code"), "|", len(cd.get("txtContent") or ""), "字 |", str(ch.get("message"))[:40])
# 实验组：镇天塔 第1章 再试一次（判断是否稳定复现）
dirs2 = get("http://127.0.0.1:9999/api/fqsearch/directory/7638535873541180440")
items2 = ((dirs2.get("data") or {}).get("item_data_list")) or []
ch2 = get("http://127.0.0.1:9999/api/fqnovel/chapter/7638535873541180440/" + items2[0]["item_id"])
print("镇天塔第1章:", ch2.get("code"), "|", str(ch2.get("message"))[:40])

