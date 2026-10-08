#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
TEST_DB="iss171"
TEST_DATA_DIR="scripts/test/issue_171_data"

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

# 用 python3 拼装 query 请求，避免 SPARQL 内引号的转义问题
query_db() {
    local sparql="$1"
    local payload
    payload=$(python3 -c '
import json,sys
print(json.dumps({
    "operation":"query","username":"root","password":"123456",
    "db_name":sys.argv[1],"sparql":sys.argv[2],"format":"json"}, ensure_ascii=False))
' "${TEST_DB}" "$sparql")
    call_api "$payload"
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

# ===================== 清理数据 =====================
# 服务端会把数据库列表记录在 dbhome/system.db，只删除目录不足以让服务器忘记该库，
# 因此同时调用 unload / drop 接口（库不存在时忽略报错）
cleanup_dbs() {
    call_api '{"operation":"unload","username":"root","password":"123456","db_name":"'"${TEST_DB}"'"}' > /dev/null
    call_api '{"operation":"drop","username":"root","password":"123456","db_name":"'"${TEST_DB}"'","is_backup":"0"}' > /dev/null
    rm -rf dbhome/${TEST_DB}.db 2>/dev/null || true
}

# ===================== 测试 1：issue 原查询，3 / 2 = 1.5 =====================
test_div_by_two_equals_decimal() {
    divider
    echo -e "${PURPLE}📌 测试 1：FILTER 中 ?n / 2^^xsd:integer = 1.5^^xsd:decimal${NC}"
    divider
    local result=$(query_db 'SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER ((?n / "2"^^<http://www.w3.org/2001/XMLSchema#integer>) = "1.5"^^<http://www.w3.org/2001/XMLSchema#decimal>) }')
    echo -e "${YELLOW}响应：${NC}$result"
    check_case "3/2 = 1.5 (only three)" "$result" "
import sys,json
d=json.load(sys.stdin)
assert d['StatusCode']==0, 'query failed'
b=d['results']['bindings']
assert len(b)==1, f'expected 1 row, got {len(b)}'
assert b[0]['s']['value']=='http://logic.local/three', f\"expected three, got {b[0]['s']['value']}\"
print('OK')
"
}

# ===================== 测试 2：除法结果本身为 xsd:decimal =====================
test_div_result_type() {
    divider
    echo -e "${PURPLE}📌 测试 2：投影 ?n / 2^^xsd:integer 的结果类型与数值${NC}"
    divider
    local result=$(query_db 'SELECT ?s (?n / "2"^^<http://www.w3.org/2001/XMLSchema#integer> AS ?q) WHERE { ?s <http://logic.local/n> ?n . }')
    echo -e "${YELLOW}响应：${NC}$result"
    check_case "3/2 -> 1.5^^xsd:decimal, 2/2 -> 1.0^^xsd:decimal" "$result" "
import sys,json
d=json.load(sys.stdin)
assert d['StatusCode']==0, 'query failed'
b=d['results']['bindings']
assert len(b)==2, f'expected 2 rows, got {len(b)}'
rows={r['s']['value']:r['q'] for r in b}
exp={'http://logic.local/three':1.5, 'http://logic.local/two':1.0}
for s,v in exp.items():
    assert s in rows, f'missing {s}'
    q=rows[s]
    assert q['datatype'].endswith('#decimal'), f\"{s}: expected xsd:decimal, got {q.get('datatype')}\"
    assert abs(float(q['value'])-v)<1e-6, f\"{s}: expected {v}, got {q['value']}\"
print('OK')
"
}

# ===================== 测试 3：负例，3 / 2 不等于 1 =====================
test_div_truncation_gone() {
    divider
    echo -e "${PURPLE}📌 测试 3（对照）：3/2 不应等于 1^^xsd:integer，仅 2/2 命中${NC}"
    divider
    local result=$(query_db 'SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER ((?n / "2"^^<http://www.w3.org/2001/XMLSchema#integer>) = "1"^^<http://www.w3.org/2001/XMLSchema#integer>) }')
    echo -e "${YELLOW}响应：${NC}$result"
    check_case "3/2 != 1, only two matches" "$result" "
import sys,json
d=json.load(sys.stdin)
assert d['StatusCode']==0, 'query failed'
b=d['results']['bindings']
assert len(b)==1, f'expected 1 row, got {len(b)}'
assert b[0]['s']['value']=='http://logic.local/two', f\"expected two, got {b[0]['s']['value']}\"
print('OK')
"
}

# ===================== 测试 4：负例，2 / 2 = 1.0 =====================
test_div_exact_decimal() {
    divider
    echo -e "${PURPLE}📌 测试 4（对照）：2/2 = 1.0^^xsd:decimal，3/2 不命中${NC}"
    divider
    local result=$(query_db 'SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER ((?n / "2"^^<http://www.w3.org/2001/XMLSchema#integer>) = "1.0"^^<http://www.w3.org/2001/XMLSchema#decimal>) }')
    echo -e "${YELLOW}响应：${NC}$result"
    check_case "2/2 = 1.0 (only two)" "$result" "
import sys,json
d=json.load(sys.stdin)
assert d['StatusCode']==0, 'query failed'
b=d['results']['bindings']
assert len(b)==1, f'expected 1 row, got {len(b)}'
assert b[0]['s']['value']=='http://logic.local/two', f\"expected two, got {b[0]['s']['value']}\"
print('OK')
"
}

# ===================== 测试 5：回归，decimal 除法不变 =====================
test_decimal_div_unchanged() {
    divider
    echo -e "${PURPLE}📌 测试 5（回归）：?n / 2^^xsd:decimal = 1.5^^xsd:decimal${NC}"
    divider
    local result=$(query_db 'SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER ((?n / "2"^^<http://www.w3.org/2001/XMLSchema#decimal>) = "1.5"^^<http://www.w3.org/2001/XMLSchema#decimal>) }')
    echo -e "${YELLOW}响应：${NC}$result"
    check_case "decimal division unchanged (only three)" "$result" "
import sys,json
d=json.load(sys.stdin)
assert d['StatusCode']==0, 'query failed'
b=d['results']['bindings']
assert len(b)==1, f'expected 1 row, got {len(b)}'
assert b[0]['s']['value']=='http://logic.local/three', f\"expected three, got {b[0]['s']['value']}\"
print('OK')
"
}

# ===================== 测试 6：回归，整数乘法不受影响 =====================
test_integer_mul_unchanged() {
    divider
    echo -e "${PURPLE}📌 测试 6（回归）：?n * 2^^xsd:integer 仍为 xsd:integer${NC}"
    divider
    local result=$(query_db 'SELECT ?s (?n * "2"^^<http://www.w3.org/2001/XMLSchema#integer> AS ?m) WHERE { ?s <http://logic.local/n> ?n . }')
    echo -e "${YELLOW}响应：${NC}$result"
    check_case "integer multiplication still xsd:integer" "$result" "
import sys,json
d=json.load(sys.stdin)
assert d['StatusCode']==0, 'query failed'
b=d['results']['bindings']
assert len(b)==2, f'expected 2 rows, got {len(b)}'
rows={r['s']['value']:r['m'] for r in b}
exp={'http://logic.local/three':6, 'http://logic.local/two':4}
for s,v in exp.items():
    assert s in rows, f'missing {s}'
    m=rows[s]
    assert m['datatype'].endswith('#integer'), f\"{s}: expected xsd:integer, got {m.get('datatype')}\"
    assert m['value']==str(v), f\"{s}: expected {v}, got {m['value']}\"
print('OK')
"
}

# ===================== 主流程 =====================
main() {
    divider
    echo -e "${PURPLE}          🚀 gStore issue #171 整数除法应返回 xsd:decimal${NC}"
    divider

    cleanup_dbs

    local build_result=$(call_api '{"operation":"build","username":"root","password":"123456","db_name":"'"${TEST_DB}"'","db_path":"'"${TEST_DATA_DIR}"'/nums.nt"}')
    echo -e "${YELLOW}build 响应：${NC}$build_result"
    if ! echo "$build_result" | grep -q '"StatusCode":0'; then
        echo -e "${RED}❌ 数据库构建失败，测试终止${NC}"
        cleanup_dbs
        return 1
    fi
    call_api '{"operation":"load","username":"root","password":"123456","db_name":"'"${TEST_DB}"'"}' > /dev/null

    local pass=0
    local fail=0

    test_div_by_two_equals_decimal && pass=$((pass+1)) || fail=$((fail+1))
    test_div_result_type          && pass=$((pass+1)) || fail=$((fail+1))
    test_div_truncation_gone      && pass=$((pass+1)) || fail=$((fail+1))
    test_div_exact_decimal        && pass=$((pass+1)) || fail=$((fail+1))
    test_decimal_div_unchanged    && pass=$((pass+1)) || fail=$((fail+1))
    test_integer_mul_unchanged    && pass=$((pass+1)) || fail=$((fail+1))

    divider
    echo -e "${GREEN}✅ 通过：${pass} / 6${NC}"
    if [ $fail -gt 0 ]; then
        echo -e "${RED}❌ 失败：${fail} / 6${NC}"
    fi
    divider

    cleanup_dbs
    return $fail
}

main "$@"
