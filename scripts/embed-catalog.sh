#!/bin/sh
# 把 catalog/*.json 合并校验后生成 Sources/ACMCore/Catalog/BuiltinCatalog.swift。
#
# 用 JSON 文件维护目录清单（便于编辑、便于用 python3 -m json.tool 校验），
# 编译进二进制（避免 SwiftPM 资源包在手工组装的 .app 里找不到自己的坑）。
set -e
cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob, json, sys

parts = []
for f in sorted(glob.glob('catalog/*.json')):
    with open(f, encoding='utf-8') as fh:
        data = json.load(fh)
    if data.get('schemaVersion') != 1:
        sys.exit('schemaVersion 不是 1: ' + f)
    for p in data.get('products', []):
        if '"""#' in json.dumps(p):
            sys.exit('产品 %s 含有不适合放进原始字符串的字符' % p.get('id'))
    parts.append((f, json.dumps(data, ensure_ascii=False, indent=2)))

lines = [
    '// 由 scripts/embed-catalog.sh 生成，请勿手工编辑。',
    '// 源文件：' + ', '.join(f for f, _ in parts),
    'enum BuiltinCatalogData {',
    '    static let jsonParts: [String] = [',
]
for _, text in parts:
    lines.append('        #"""')
    lines.append(text)
    lines.append('"""#,')
lines += ['    ]', '}', '']

with open('Sources/ACMCore/Catalog/BuiltinCatalog.swift', 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(lines))

total = sum(len(json.loads(t)['products']) for _, t in parts)
print('已嵌入 %d 个目录文件，共 %d 个产品' % (len(parts), total))
PY
