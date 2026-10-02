# -*- coding: utf-8 -*-
import json, urllib.request, sqlite3
def get(u):
    return json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent":"okhttp"}), timeout=60).read().decode("utf-8","ignore"))
dirs = get("http://127.0.0.1:9999/api/fqsearch/directory/7638535873541180440")
items = ((dirs.get("data") or {}).get("item_data_list")) or []
db = sqlite3.connect("/volume2/docker/books/xiaoshuo_data/xiaoshuo.db")
cur = db.cursor()
n = 0
for i, it in enumerate(items):
    cur.execute("UPDATE chapters SET src_id=? WHERE book_id=28 AND idx=?", (it["item_id"], i))
    n += cur.rowcount
db.commit()
print("src_id 修复行数:", n)
db.close()

