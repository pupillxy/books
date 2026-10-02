# -*- coding: utf-8 -*-
"""探针：App 搜索字段 + bookmall 其他 tab"""
import json, re, io, urllib.request

BASE = "http://127.0.0.1:9999"
def post(u, obj, timeout=90):
    req = urllib.request.Request(u, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode('utf-8', 'ignore'))

print("=== 1) App 搜索字段 ===")
d = post(BASE + "/api/fqsearch/books", {"query": "万相之主", "count": 2})
b = ((d.get('data') or {}).get('books') or [{}])[0]
print(json.dumps(b, ensure_ascii=False)[:600])

print()
print("=== 2) bookmall tab_index=1/6（小说/漫画 tab）===")
biz = open("/tmp/feed_payload_query.txt", encoding='utf-8').read().strip()
for idx, name in [(1, "小说"), (6, "漫画")]:
    biz2 = re.sub(r'tab_index=-?\d+', 'tab_index=%d' % idx, biz)
    try:
        raw = post(BASE + "/api/fqapp/fetch", {"path": "/reading/bookapi/bookmall/tab/v", "query": biz2})
        data = raw.get('data') or {}
        for t in (data.get('tab_item') or [])[:9]:
            if t.get('tab_index') != idx:
                continue
            cells = t.get('cell_data') or []
            print("[%s] %s: cells=%d" % (t.get('tab_index'), t.get('title'), len(cells)))
            for c in cells[:3]:
                inner = c.get('cell_data') or []
                n = 0
                sample = None
                for ic in inner:
                    for b in (ic.get('book_data') or []):
                        n += 1
                        if not sample:
                            sample = (b.get('book_name'), b.get('category'), b.get('rank_score') or b.get('read_cnt_text') or b.get('sub_info'))
                print("   模块 %r: 书 %d 本 %s" % (c.get('cell_name'), n, sample))
    except Exception as e:
        print("[%d] 失败: %r" % (idx, e))
