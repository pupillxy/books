# -*- coding: utf-8 -*-
"""从 rank_urls.jsonl 提取各端点代表性请求的纯业务参数（剥设备字段），
保留原始 URL 编码，供 Go 侧模板嵌入与 NAS unidbg 回放。"""
import json
from urllib.parse import urlparse

# Java FQApiUtils.buildCommonApiParams 会注入的设备字段（调用方不得重复）
DEVICE_PARAMS = {
    'iid', 'device_id', 'ac', 'channel', 'aid', 'app_name', 'version_code',
    'version_name', 'device_platform', 'os', 'ssmix', 'device_type',
    'device_brand', 'language', 'os_api', 'os_version', 'manifest_version_code',
    'resolution', 'dpi', 'update_version_code', '_rticket', 'host_abi',
    'dragon_device_type', 'pv_player', 'compliance_status',
    'need_personal_recommend', 'player_so_load', 'is_android_pad_screen',
    'rom_version', 'cdid',
}

rows = [json.loads(l) for l in open('rank_urls.jsonl', encoding='utf-8')]


def kv_pairs(u):
    """原始 k=v 对（不解码，保留原编码），剥设备字段。"""
    pr = urlparse(u)
    out = []
    for kv in pr.query.split('&'):
        k, _, v = kv.partition('=')
        if k not in DEVICE_PARAMS:
            out.append((k, v))
    return out


def qdict(u):
    return dict(kv_pairs(u))


pick = {}
for d in rows:
    u = d['url']
    pr = urlparse(u)
    path = pr.path
    q = qdict(u)
    if 'bookmall/tab/v' in path:
        tt = q.get('tab_type', '')
        if tt == '-1' and 'tab-1' not in pick:
            pick['tab-1'] = u          # 推荐频道
        if tt == '25' and 'tab25' not in pick:
            pick['tab25'] = u          # 小说频道首屏
    elif 'bookmall/cell/change/v1' in path:
        if 'rankpage' not in pick and q.get('algo_type') == '100':
            pick['rankpage'] = u       # 完整榜单页（完本榜）
    elif 'bookmall/cell/change/v' in path:
        tt, algo = q.get('tab_type'), q.get('algo_type')
        if tt == '2' and algo == '100' and 'rankcard' not in pick:
            pick['rankcard'] = u       # 榜单卡子榜（完本榜）
        if tt == '25' and 'novelfeed' not in pick:
            pick['novelfeed'] = u      # 小说频道瀑布流分页
    elif 'search/tab/v' in path and 'search' not in pick:
        pick['search'] = u

out = {k: '&'.join(f'{k2}={v2}' for k2, v2 in kv_pairs(u)) for k, u in pick.items()}

with open('biz_queries.json', 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
for k, v in out.items():
    print(f'--- {k} ({len(v)} chars) ---')
    print(v[:300], '...')
