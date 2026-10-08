#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
TEST_DATA_DIR="scripts/test/issue_156_data"
DB_NAME="iss156"

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

# 转义 SPARQL 语句，便于拼入 JSON 请求体
escape_sparql() {
    printf '%s' "$1" | python3 -c 'import sys,json; s=json.dumps(sys.stdin.read()); sys.stdout.write(s[1:-1])'
}

# 校验应答中的行数（expect_count）与 ?s 的取值集合（expect_subjects，逗号分隔，可为空）
check_rows() {
    local case_name="$1"
    local result="$2"
    local expect_count="$3"
    local expect_subjects="$4"
    local msg
    if msg=$(echo "$result" | EXPECT_COUNT="$expect_count" EXPECT_SUBJECTS="$expect_subjects" python3 -c '
import os, sys, json
expect_count = int(os.environ["EXPECT_COUNT"])
expect_subjects = sorted(s for s in os.environ["EXPECT_SUBJECTS"].split(",") if s)
d = json.load(sys.stdin)
assert d.get("StatusCode") == 0, "StatusCode=%s" % d.get("StatusCode")
rows = d.get("results", {}).get("bindings", [])
assert len(rows) == expect_count, "expected %d rows, got %d" % (expect_count, len(rows))
if expect_subjects:
    subjects = sorted(b["s"]["value"] for b in rows)
    assert subjects == expect_subjects, "expected %s, got %s" % (expect_subjects, subjects)
print("OK")
' 2>&1); then
        echo -e "  ${GREEN}PASS${NC}: $case_name"
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $case_name -- ${msg}"
        return 1
    fi
}

# 执行查询并校验
run_query_case() {
    local case_name="$1"
    local sparql="$2"
    local expect_count="$3"
    local expect_subjects="$4"
    local result
    result=$(call_api '{"operation":"query","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","sparql":"'"$(escape_sparql "$sparql")"'","format":"json"}')
    check_rows "$case_name" "$result" "$expect_count" "$expect_subjects"
}

# ===================== 服务检查 =====================
check_service() {
    echo -e "${YELLOW}检查 gStore 服务状态...${NC}"
    local response
    response=$(call_api '{"operation":"check"}')
    if echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${GREEN}服务已启动（端口 ${PORT}）${NC}"
        return 0
    fi
    echo -e "${RED}服务未启动，请先执行 ./bin/gserver -b${NC}"
    return 1
}

# ===================== 清理旧数据 =====================
cleanup_db() {
    call_api '{"operation":"unload","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}' > /dev/null 2>&1 || true
    call_api '{"operation":"drop","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","is_backup":"false"}' > /dev/null 2>&1 || true
    rm -rf dbhome/${DB_NAME}.db 2>/dev/null || true
}

# ===================== 主流程 =====================
main() {
    divider
    echo -e "${PURPLE}          gStore issue #156: xsd:boolean 词法形式等值测试${NC}"
    divider

    check_service || return 1
    cleanup_db

    # -------------------- 构建并加载测试数据 --------------------
    divider
    echo -e "${PURPLE}构建并加载测试数据${NC}"
    divider
    local result
    result=$(call_api '{"operation":"build","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","db_path":"'"${TEST_DATA_DIR}"'/data.nt"}')
    echo -e "${YELLOW}build 响应：${NC}$result"
    echo "$result" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d.get("StatusCode") == 0, "build failed: %s" % d.get("StatusMsg")
assert d.get("success_num") == 6, "expected 6 triples, got %s" % d.get("success_num")
print("OK")
'
    result=$(call_api '{"operation":"load","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}')
    echo -e "${YELLOW}load 响应：${NC}$result"

    local pass=0
    local fail=0

    # -------------------- 测试 1：issue 中的等值查询 --------------------
    divider
    echo -e "${PURPLE}测试 1：\"1\"^^xsd:boolean 与 \"true\"^^xsd:boolean 等值${NC}"
    divider
    run_query_case '= "true"^^xsd:boolean 返回两行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag> ?f . FILTER (?f = "true"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        2 "http://logic.local/one,http://logic.local/true" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case '!= "true"^^xsd:boolean 返回零行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag> ?f . FILTER (?f != "true"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        0 "" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case '= "1"^^xsd:boolean 返回两行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag> ?f . FILTER (?f = "1"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        2 "http://logic.local/one,http://logic.local/true" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case '!= "1"^^xsd:boolean 返回零行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag> ?f . FILTER (?f != "1"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        0 "" && pass=$((pass+1)) || fail=$((fail+1))

    # -------------------- 测试 2："0"/"false" 的对称用例 --------------------
    divider
    echo -e "${PURPLE}测试 2：\"0\"^^xsd:boolean 与 \"false\"^^xsd:boolean 等值${NC}"
    divider
    run_query_case '= "false"^^xsd:boolean 返回两行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag2> ?f . FILTER (?f = "false"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        2 "http://logic.local/false,http://logic.local/zero" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case '!= "false"^^xsd:boolean 返回零行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag2> ?f . FILTER (?f != "false"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        0 "" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case '= "0"^^xsd:boolean 返回两行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag2> ?f . FILTER (?f = "0"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        2 "http://logic.local/false,http://logic.local/zero" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case '!= "0"^^xsd:boolean 返回零行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag2> ?f . FILTER (?f != "0"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        0 "" && pass=$((pass+1)) || fail=$((fail+1))

    # -------------------- 测试 3：负例，true 与 false 不相等 --------------------
    divider
    echo -e "${PURPLE}测试 3：负例，true 与 false 不相等${NC}"
    divider
    run_query_case 'flag = "false"^^xsd:boolean 返回零行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag> ?f . FILTER (?f = "false"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        0 "" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case 'flag != "false"^^xsd:boolean 返回两行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag> ?f . FILTER (?f != "false"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        2 "http://logic.local/one,http://logic.local/true" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case 'flag2 = "true"^^xsd:boolean 返回零行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag2> ?f . FILTER (?f = "true"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        0 "" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case 'flag = "0"^^xsd:boolean 返回零行' \
        'SELECT ?s WHERE { ?s <http://logic.local/flag> ?f . FILTER (?f = "0"^^<http://www.w3.org/2001/XMLSchema#boolean>) }' \
        0 "" && pass=$((pass+1)) || fail=$((fail+1))

    # -------------------- 测试 4：普通字符串字面量不受影响 --------------------
    divider
    echo -e "${PURPLE}测试 4：普通字符串字面量 \"1\"/\"true\" 不受影响${NC}"
    divider
    run_query_case '普通字面量 = "true" 返回一行' \
        'SELECT ?s WHERE { ?s <http://logic.local/plain> ?f . FILTER (?f = "true") }' \
        1 "http://logic.local/plaintrue" && pass=$((pass+1)) || fail=$((fail+1))
    run_query_case '普通字面量 = "1" 返回一行' \
        'SELECT ?s WHERE { ?s <http://logic.local/plain> ?f . FILTER (?f = "1") }' \
        1 "http://logic.local/plainone" && pass=$((pass+1)) || fail=$((fail+1))

    # -------------------- 汇总 --------------------
    divider
    local total=$((pass+fail))
    echo -e "${GREEN}通过：${pass} / ${total}${NC}"
    if [ ${fail} -gt 0 ]; then
        echo -e "${RED}失败：${fail} / ${total}${NC}"
    fi
    divider

    cleanup_db
    echo -e "${GREEN}测试完成${NC}"
    return ${fail}
}

main "$@"
