#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""备份对账脚本（只读）：把一个备份 JSON 摊开给人看。

为什么要从 PowerShell 换成 Python：
    PS 5.1 的 `ConvertFrom-Json` 底层是 JavaScriptSerializer，**有 2MB 上限** ——
    v4 的「全局备份」因为含历史净值，动辄 3~4MB，老脚本直接解析失败。
    Python 的 json 没有这个限制，而且这里本来就要按需裁剪输出。

用法：
    python tool/inspect_backup.py <备份.json>
    python tool/inspect_backup.py <备份.json> --txns 30      # 只列最近 30 笔流水
    python tool/inspect_backup.py <备份.json> --nav 021362   # 看某只基金的净值明细
    python tool/inspect_backup.py <备份.json> --out r.txt    # 报告另存（默认写 <json>.report.txt）

正文同时写一份 **UTF-8 报告文件**：Windows 控制台是 GBK，中文会花，
直接读报告文件更省事。只读，不会改动任何数据。
"""
import json
import sys
from collections import Counter
from datetime import datetime


def money(v):
    try:
        return f"{float(v):,.2f}"
    except (TypeError, ValueError):
        return str(v)


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if not args:
        print(__doc__)
        return 2
    path = args[0]

    show_txns, nav_code, out_path = 20, None, None
    rest = argv[1:]
    for i, a in enumerate(rest):
        if a == '--txns' and i + 1 < len(rest):
            show_txns = int(rest[i + 1])
        elif a == '--nav' and i + 1 < len(rest):
            nav_code = rest[i + 1]
        elif a == '--out' and i + 1 < len(rest):
            out_path = rest[i + 1]

    report_path = out_path or (path + '.report.txt')
    buf = []

    def emit(s=''):
        buf.append(s)
        print(s.encode('gbk', 'replace').decode('gbk'))

    with open(path, 'r', encoding='utf-8') as f:
        d = json.load(f)

    ts = d.get('exportedAt') or 0
    when = datetime.fromtimestamp(ts / 1000).strftime('%Y-%m-%d %H:%M:%S') if ts else '?'
    emit(f"文件      : {path}")
    emit(f"应用      : {d.get('app')}  版本: v{d.get('version')}  导出时间: {when}")

    for k in ('accounts', 'assets', 'txns', 'cashTxns', 'targets',
              'watchlist', 'dcaPlans'):
        emit(f"{k:<10}: {len(d.get(k) or [])}")
    emit(f"{'settings':<10}: {len(d.get('settings') or {})}")
    sec = d.get('securities') or []
    nav = d.get('navHistory') or []
    emit(f"{'securities':<10}: {len(sec)}   （金融基础数据）")
    emit(f"{'navHistory':<10}: {len(nav)}   （历史净值）")
    if not nav:
        emit("  提示：这份备份没有历史净值（v1~v3 老备份如此；恢复时不会动本地净值表）")

    emit("\n=== 账户 ===")
    for a in d.get('accounts') or []:
        emit(f"  [{a.get('id')}] {a.get('name')}  {a.get('note') or ''}")

    assets = d.get('assets') or []
    emit("\n=== 标的 ===")
    for a in assets:
        link = f"  联动 {a['link_code']}" if a.get('link_code') else ''
        cat = f"/{a['category']}" if a.get('category') else ''
        emit(f"  [{a.get('id')}] {a.get('code')} {a.get('name')}  ({a.get('kind')}{cat}){link}")

    wl = d.get('watchlist') or []
    codes = [w.get('code') for w in wl]
    emit("\n=== 关注列表 ===")
    for w in wl:
        emit(f"  {w.get('code')} {w.get('name') or ''}"
             f"  pinned={w.get('pinned')} order={w.get('sort_order')}")
    dup = [c for c, n in Counter(codes).items() if n > 1]
    emit(f"  重复代码检查: {'有重复 -> ' + ','.join(dup) if dup else '没有重复 [OK]'}")

    emit("\n=== 调仓目标 ===")
    for t in d.get('targets') or []:
        emit(f"  {t.get('key')}  {t.get('label') or ''}  {t.get('ratio')}")

    emit("\n=== 定投计划 ===")
    for p in d.get('dcaPlans') or []:
        emit(f"  asset={p.get('asset_id')} {p.get('amount')} {p.get('frequency')}"
             f"  next={p.get('next_date') or p.get('start_date') or ''}")

    txns = d.get('txns') or []
    if txns:
        emit(f"\n=== 交易流水（共 {len(txns)} 笔，列最近 {min(show_txns, len(txns))} 笔）===")
        for t in sorted(txns, key=lambda x: str(x.get('date')))[-show_txns:]:
            aid = t.get('asset_id')
            code = next((a.get('code') for a in assets if a.get('id') == aid), '?')
            emit(f"  {t.get('date')} {str(t.get('type')):<8} {code:<8}"
                 f" 金额={money(t.get('amount')):<14} 份额={t.get('shares')}"
                 f" 费={t.get('fee')} 备注={t.get('note') or ''}")

    if nav:
        emit("\n=== 历史净值 ===")
        by = {}
        for r in nav:
            b = by.setdefault(r.get('code'), [r.get('date') or '', r.get('date') or '', 0])
            b[0] = min(b[0], r.get('date') or '')
            b[1] = max(b[1], r.get('date') or '')
            b[2] += 1
        emit(f"  覆盖 {len(by)} 只，共 {len(nav)} 条")
        for c, (lo, hi, n) in sorted(by.items()):
            emit(f"    {c}  {n:>6} 条  {lo} ~ {hi}")
        if nav_code:
            rows = sorted([r for r in nav if r.get('code') == nav_code],
                          key=lambda r: r.get('date') or '')
            emit(f"\n  {nav_code} 明细（{len(rows)} 条，列最后 20 条）：")
            for r in rows[-20:]:
                emit(f"    {r.get('date')} nav={r.get('nav')} acc={r.get('acc_nav')}"
                     f" chg={r.get('change_pct')} {r.get('dividend') or ''}")

    if sec:
        emit("\n=== 金融基础数据 ===")
        kinds = Counter(s.get('kind') for s in sec)
        emit("  按类型: " + ', '.join(f"{k}={v}" for k, v in sorted(kinds.items())))

    st = d.get('settings') or {}
    emit("\n=== 关键设置 ===")
    for k in sorted(st):
        v = st[k]
        emit(f"  {k} = {('（%d 字符，略）' % len(v)) if len(str(v)) > 200 else v}")

    with open(report_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(buf) + '\n')
    print(f"\n[报告已写入] {report_path}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
