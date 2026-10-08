#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
TEST_DATA_DIR="scripts/test/issue_170_data"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ===================== 自动获取端口 =====================
PORT=$(grep -m 1 'port=' "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2 | xargs)
if [ -z "${PORT}" ]; then
    PORT=9000
fi
BASE_URL="http://127.0.0.1:${PORT}/api"

# ===================== 工具函数 =====================
call_api() {
    local data="$1"
    curl -s --noproxy '*' --max-time 30 -X POST \
        -H 'Content-Type: application/json' \
        -d "$data" "${BASE_URL}" 2>/dev/null || echo '{"StatusCode":-1}'
}

divider() {
    echo -e "${BLUE}=========================================================================${NC}"
}

# ===================== 单用例校验 =====================
check_case() {
    local case_name="$1"
    local result="$2"
    local python_check="$3"
    echo "$result" | python3 -c "$python_check" 2>/dev/null && {
        echo -e "  ${GREEN}PASS${NC}: $case_name"
        return 0
    } || {
        echo -e "  ${RED}FAIL${NC}: $case_name"
        return 1
    }
}

# ===================== 清理旧数据 =====================
cleanup_dbs() {
    for db in iss170_strs iss170_order iss170_nums iss170_typed iss170_datetime; do
        # 数据库在 system.db 中登记过，需先 drop 注销，否则重建会报 already built
        call_api '{"operation":"drop","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${db}"'","is_backup":"false"}' > /dev/null 2>&1 || true
        rm -rf dbhome/${db}.db 2>/dev/null || true
    done
}

# ===================== 建库并加载 =====================
build_db() {
    local db_name="$1"
    local nt_file="$2"
    local result=$(call_api '{"operation":"build","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${db_name}"'","db_path":"'"${nt_file}"'"}')
    check_case "${db_name} build" "$result" "
import sys,json
d=json.load(sys.stdin)
assert d.get('StatusCode')==0, f'build failed: {d}'
print('OK')
" || return 1
    call_api '{"operation":"load","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${db_name}"'"}' > /dev/null
    return 0
}

# ===================== 运行一条查询并做校验 =====================
query_case() {
    local db_name="$1"
    local case_name="$2"
    local sparql="$3"
    local python_check="$4"
    local result=$(call_api '{"operation":"query","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${db_name}"'","sparql":"'"${sparql}"'","format":"json"}')
    echo -e "${YELLOW}响应：${NC}$result"
    check_case "$case_name" "$result" "$python_check"
}

# ===================== 测试 1：普通字符串字面量的 MIN/MAX（issue 复现） =====================
test_plain_string() {
    divider
    echo -e "${PURPLE}📌 测试 1：MIN/MAX over plain string literals${NC}"
    divider
    build_db "iss170_strs" "${TEST_DATA_DIR}/strs.nt" || return 1

    query_case "iss170_strs" "MIN(?label) = \"apple\"" \
        'SELECT (MIN(?label) AS ?min) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
assert d.get('StatusCode')==0, f'query failed: {d}'
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert 'min' in b, 'min is unbound'
assert b['min'].get('value')=='apple', f'expected apple, got {b[\"min\"].get(\"value\")!r}'
assert b['min'].get('type')=='literal', f'expected literal, got {b[\"min\"].get(\"type\")}'
print('OK')
" || return 1

    query_case "iss170_strs" "MAX(?label) = \"banana\"" \
        'SELECT (MAX(?label) AS ?max) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
assert d.get('StatusCode')==0, f'query failed: {d}'
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert 'max' in b, 'max is unbound'
assert b['max'].get('value')=='banana', f'expected banana, got {b[\"max\"].get(\"value\")!r}'
assert b['max'].get('type')=='literal', f'expected literal, got {b[\"max\"].get(\"type\")}'
print('OK')
" || return 1

    query_case "iss170_strs" "MIN(DISTINCT ?label) = \"apple\"" \
        'SELECT (MIN(DISTINCT ?label) AS ?min) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('min',{}).get('value')=='apple', f'expected apple, got {b.get(\"min\")!r}'
print('OK')
" || return 1

    query_case "iss170_strs" "MAX(DISTINCT ?label) = \"banana\"" \
        'SELECT (MAX(DISTINCT ?label) AS ?max) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('max',{}).get('value')=='banana', f'expected banana, got {b.get(\"max\")!r}'
print('OK')
" || return 1

    return 0
}

# ===================== 测试 2：乱序字符串集合，MIN/MAX 按 ORDER BY 语义取值 =====================
test_string_order() {
    divider
    echo -e "${PURPLE}📌 测试 2：字符串 MIN/MAX 按 ORDER BY 排序取首/末元素${NC}"
    divider
    build_db "iss170_order" "${TEST_DATA_DIR}/strs_order.nt" || return 1

    query_case "iss170_order" "MIN over {banana, cherry, apple} = \"apple\"" \
        'SELECT (MIN(?label) AS ?min) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
v=bindings[0].get('min',{}).get('value')
assert v=='apple', f'expected apple, got {v!r}'
print('OK')
" || return 1

    query_case "iss170_order" "MAX over {banana, cherry, apple} = \"cherry\"" \
        'SELECT (MAX(?label) AS ?max) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
v=bindings[0].get('max',{}).get('value')
assert v=='cherry', f'expected cherry, got {v!r}'
print('OK')
" || return 1

    return 0
}

# ===================== 测试 3：数值 MIN/MAX 对照（不应回归） =====================
test_numeric() {
    divider
    echo -e "${PURPLE}📌 测试 3：数值 MIN/MAX 对照${NC}"
    divider
    build_db "iss170_nums" "${TEST_DATA_DIR}/nums.nt" || return 1

    query_case "iss170_nums" "MIN over integers = \"3\"^^xsd:integer" \
        'SELECT (MIN(?n) AS ?min) WHERE { ?s <http://logic.local/value> ?n . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('min',{}).get('value')=='3', f'expected 3, got {b.get(\"min\")!r}'
print('OK')
" || return 1

    query_case "iss170_nums" "MAX over integers = \"4\"^^xsd:integer" \
        'SELECT (MAX(?n) AS ?max) WHERE { ?s <http://logic.local/value> ?n . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('max',{}).get('value')=='4', f'expected 4, got {b.get(\"max\")!r}'
print('OK')
" || return 1

    return 0
}

# ===================== 测试 4：xsd:string 类型字面量的 MIN/MAX =====================
test_typed_string() {
    divider
    echo -e "${PURPLE}📌 测试 4：MIN/MAX over xsd:string literals${NC}"
    divider
    build_db "iss170_typed" "${TEST_DATA_DIR}/typed_strs.nt" || return 1

    query_case "iss170_typed" "MIN over xsd:string = \"apple\"" \
        'SELECT (MIN(?label) AS ?min) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('min',{}).get('value')=='apple', f'expected apple, got {b.get(\"min\")!r}'
print('OK')
" || return 1

    query_case "iss170_typed" "MAX over xsd:string = \"banana\"" \
        'SELECT (MAX(?label) AS ?max) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('max',{}).get('value')=='banana', f'expected banana, got {b.get(\"max\")!r}'
print('OK')
" || return 1

    return 0
}

# ===================== 测试 5：其它聚合与 dateTime 路径不应回归 =====================
# 注：MIN over xsd:dateTime 另有独立的哨兵初值问题（与 #170 无关），此处只覆盖 MAX。
test_others() {
    divider
    echo -e "${PURPLE}📌 测试 5：COUNT 与 xsd:dateTime MAX 不回归${NC}"
    divider

    query_case "iss170_strs" "COUNT(?label) over plain strings = 2" \
        'SELECT (COUNT(?label) AS ?cnt) WHERE { ?s <http://logic.local/label> ?label . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('cnt',{}).get('value')=='2', f'expected 2, got {b.get(\"cnt\")!r}'
print('OK')
" || return 1

    build_db "iss170_datetime" "${TEST_DATA_DIR}/datetimes.nt" || return 1

    query_case "iss170_datetime" "MAX over dateTime = 2024-06-01" \
        'SELECT (MAX(?t) AS ?max) WHERE { ?s <http://logic.local/time> ?t . }' "
import sys,json
d=json.load(sys.stdin)
bindings=d.get('results',{}).get('bindings',[])
assert len(bindings)==1, f'expected 1 row, got {len(bindings)}'
b=bindings[0]
assert b.get('max',{}).get('value')=='2024-06-01T00:00:00', f'expected 2024-06-01T00:00:00, got {b.get(\"max\")!r}'
print('OK')
" || return 1

    return 0
}

# ===================== 主流程 =====================
main() {
    divider
    echo -e "${PURPLE}          🚀 gStore issue #170 MIN/MAX over strings 测试${NC}"
    divider

    cleanup_dbs

    local pass=0
    local fail=0

    test_plain_string  && pass=$((pass+1)) || fail=$((fail+1))
    test_string_order  && pass=$((pass+1)) || fail=$((fail+1))
    test_numeric       && pass=$((pass+1)) || fail=$((fail+1))
    test_typed_string  && pass=$((pass+1)) || fail=$((fail+1))
    test_others        && pass=$((pass+1)) || fail=$((fail+1))

    divider
    echo -e "${GREEN}✅ 通过：${pass} / 5${NC}"
    if [ $fail -gt 0 ]; then
        echo -e "${RED}❌ 失败：${fail} / 5${NC}"
    fi
    divider

    cleanup_dbs
    return $fail
}

main "$@"
