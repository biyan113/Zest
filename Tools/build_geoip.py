#!/usr/bin/env python3
"""
把 DB-IP Lite（CC BY 4.0，https://db-ip.com）的 CSV 转换为 Zest 使用的紧凑二进制库。

用法：python3 -I Tools/build_geoip.py dbip-country-lite-YYYY-MM.csv.gz dbip-asn-lite-YYYY-MM.csv.gz Resources/Data/geoip.deflate
      输出文件名以 .deflate 结尾时写入 raw deflate 压缩数据（应用读取的格式），否则写入未压缩的二进制。

文件格式（小端）：
  magic  "ZGEO" | version u16 | 数据月份 7 字节 ASCII（如 2026-10）| 保留 1 字节
  国家码表：count u16，随后 count × 2 字节 ASCII（索引 0 = 未知）
  组织名表：count u32，随后 count 个 (u16 长度 + UTF-8)（索引 0 = 未知）
  4 个区间表（IPv4 国家、IPv4 组织、IPv6 国家、IPv6 组织），每个：
     count u32，starts[count]（IPv4 为 u32，IPv6 取前 64 位 u64），values[count]
     （国家表 value 为 u8 国家索引；组织表 value 为 u32：低 24 位组织索引，ASN 另存于 asn 数组 u32）
区间连续覆盖：起点之间的空隙以“未知”区间填充，查询时取最后一个 start ≤ 地址 的区间。
"""
import csv, gzip, ipaddress, struct, sys, zlib

def rows(path):
    with gzip.open(path, 'rt', encoding='utf-8', newline='') as f:
        yield from csv.reader(f)

def key(ip):
    a = ipaddress.ip_address(ip)
    return (4, int(a)) if a.version == 4 else (6, int(a) >> 64)

def build(ranges, unknown):
    """ranges: [(start, end, value)] 已排序；返回合并、填充空隙后的 (starts, values)。"""
    starts, values = [], []
    cursor = 0
    for s, e, v in ranges:
        if s > cursor:
            if not values or values[-1] != unknown:
                starts.append(cursor); values.append(unknown)
        if s < cursor:  # 截断后（IPv6 /64）可能重叠：取后者覆盖
            s = cursor
            if starts and starts[-1] == s:
                starts.pop(); values.pop()
        if values and values[-1] == v and starts:
            pass
        else:
            starts.append(s); values.append(v)
        cursor = max(cursor, e + 1)
    if not starts or starts[0] != 0:
        starts.insert(0, 0); values.insert(0, unknown)
    return starts, values

def main(country_path, asn_path, out_path):
    month = country_path.split('lite-')[-1][:7]
    countries = ['??']
    cidx = {}
    v4c, v6c = [], []
    for start, end, cc in rows(country_path):
        if cc in ('ZZ', ''): continue
        if cc not in cidx:
            cidx[cc] = len(countries); countries.append(cc)
        fam, s = key(start); _, e = key(end)
        (v4c if fam == 4 else v6c).append((s, e, cidx[cc]))
    names = ['']
    nidx = {}
    v4a, v6a = [], []
    for start, end, asn, org in rows(asn_path):
        org = org.strip()[:80]
        k = (int(asn), org)
        if k not in nidx:
            nidx[k] = len(names); names.append(k)
        fam, s = key(start); _, e = key(end)
        (v4a if fam == 4 else v6a).append((s, e, nidx[k]))
    for lst in (v4c, v6c, v4a, v6a): lst.sort()

    out = bytearray()
    out += b'ZGEO' + struct.pack('<H', 1) + month.encode('ascii').ljust(7)[:7] + b'\0'
    out += struct.pack('<H', len(countries))
    for c in countries: out += c.encode('ascii')
    out += struct.pack('<I', len(names))
    for n in names:
        if n == '':
            out += struct.pack('<IH', 0, 0)
        else:
            b = n[1].encode('utf-8')
            out += struct.pack('<IH', n[0], len(b)) + b
    for lst, wide, fmt in ((v4c, False, 'B'), (v4a, False, 'I'), (v6c, True, 'B'), (v6a, True, 'I')):
        starts, values = build(lst, 0)
        out += struct.pack('<I', len(starts))
        out += struct.pack('<%d%s' % (len(starts), 'Q' if wide else 'I'), *starts)
        out += struct.pack('<%d%s' % (len(values), fmt), *values)
        print(('v6' if wide else 'v4'), 'country' if fmt == 'B' else 'asn', len(starts), 'ranges', file=sys.stderr)
    data = bytes(out)
    if out_path.endswith('.deflate'):
        c = zlib.compressobj(9, zlib.DEFLATED, -15)
        data = c.compress(data) + c.flush()
    open(out_path, 'wb').write(data)
    print(len(countries) - 1, 'countries', len(names) - 1, 'orgs', len(out), 'bytes ->', len(data), file=sys.stderr)

if __name__ == '__main__':
    main(*sys.argv[1:4])
