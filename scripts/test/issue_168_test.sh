#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
# issue #168: LANG() 对没有语言标签的字面量不返回空简单字面量 ""，导致惯用过滤
# LANG(?x) = "" 对 plain literal / xsd:string / 数值字面量全部失配
# （SPARQL 1.1 17.4.2.6 规定 LANG 无语言标签时返回 ""）
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
TEST_DATA_DIR="scripts/test/issue_168_data"
DB_NAME="iss168_test"

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

# 将 SPARQL 文本编码成 JSON 字符串
json_escape() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

# 执行 SPARQL 查询（format=json）
call_query() {
    local sparql="$1"
    local escaped=$(json_escape "$sparql")
    call_api '{"operation":"query","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","sparql":'"${escaped}"',"format":"json"}'
}

# 单用例校验：$4 期望返回行数，$5 期望返回的 ?s（逗号分隔，可为空）
PASS_NUM=0
FAIL_NUM=0
check_case() {
    local case_name="$1"
    local result="$2"
    local python_check="$3"
    local expect_num="$4"
    local expect_s="$5"
    local reason=""
    if reason=$(echo "$result" | python3 -c "$python_check" "$expect_num" "$expect_s" 2>&1); then
        echo -e "  ${GREEN}PASS${NC}: $case_name"
        PASS_NUM=$((PASS_NUM+1))
    else
        echo -e "  ${RED}FAIL${NC}: $case_name"
        echo -e "        ${YELLOW}原因：${NC}$(echo "$reason" | tail -n 1)"
        echo -e "        ${YELLOW}响应：${NC}$result"
        FAIL_NUM=$((FAIL_NUM+1))
    fi
}

# ===================== 断言代码 =====================
# 构建库的断言：StatusCode=0 且 success_num 与期望一致
CHECK_BUILD_PY=$(cat <<'PY'
import sys, json
d = json.load(sys.stdin)
assert d.get("StatusCode") == 0, "build failed: %s" % d
expect = int(sys.argv[1])
assert d.get("success_num", 0) == expect, "expect %d triples, got %s" % (expect, d.get("success_num"))
print("OK")
PY
)

# 加载库的断言
CHECK_LOAD_PY=$(cat <<'PY'
import sys, json
d = json.load(sys.stdin)
assert d.get("StatusCode") == 0, "load failed: %s" % d
print("OK")
PY
)

# 查询的断言：校验返回行数，并可选校验返回的主语集合
CHECK_QUERY_PY=$(cat <<'PY'
import sys, json
d = json.load(sys.stdin)
assert d.get("StatusCode") == 0, "query failed: %s" % d
bindings = d.get("results", {}).get("bindings", [])
expect_num = int(sys.argv[1])
assert len(bindings) == expect_num, "expect %d rows, got %d" % (expect_num, len(bindings))
expect_s = sys.argv[2]
if expect_s:
    def norm(v):
        v = str(v)
        return v[1:-1] if v.startswith("<") and v.endswith(">") else v
    subs = sorted(norm(b.get("s", {}).get("value", "")) for b in bindings)
    assert subs == sorted(expect_s.split(",")), "expect subjects %s, got %s" % (expect_s, subs)
print("OK")
PY
)

# ===================== 清理旧数据 =====================
cleanup_db() {
    call_api '{"operation":"unload","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}' > /dev/null 2>&1 || true
    call_api '{"operation":"drop","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","is_backup":"false"}' > /dev/null 2>&1 || true
    rm -rf "dbhome/${DB_NAME}.db" 2>/dev/null || true
}

# ===================== 测试 1：构建并加载测试库 =====================
test_build_and_load() {
    divider
    echo -e "${PURPLE}📌 测试 1：构建并加载测试库${NC}"
    divider

    local result=$(call_api '{"operation":"build","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","db_path":"'"${TEST_DATA_DIR}"'/issue_168.nt"}')
    check_case "构建测试库（5 条三元组）" "$result" "$CHECK_BUILD_PY" "5" ""
    [ "${FAIL_NUM}" -eq 0 ] || return 1

    result=$(call_api '{"operation":"load","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}')
    check_case "加载测试库" "$result" "$CHECK_LOAD_PY" "" ""
    [ "${FAIL_NUM}" -eq 0 ] || return 1

    return 0
}

# ===================== 测试 2：LANG() = "" 命中无语言标签的字面量 =====================
test_lang_empty() {
    divider
    echo -e "${PURPLE}📌 测试 2：LANG(?x) = \"\" 命中无语言标签的字面量（SPARQL 1.1 17.4.2.6）${NC}"
    divider

    check_case 'plain "abc"：LANG(?label) = "" 命中 1 行' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/plain> && LANG(?label) = "") }')" \
        "$CHECK_QUERY_PY" "1" "http://logic.local/plain"

    check_case '"abc"^^xsd:string：LANG(?label) = "" 命中 1 行' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/typed> && LANG(?label) = "") }')" \
        "$CHECK_QUERY_PY" "1" "http://logic.local/typed"

    check_case '空串 ""：LANG(?label) = "" 命中 1 行' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/empty> && LANG(?label) = "") }')" \
        "$CHECK_QUERY_PY" "1" "http://logic.local/empty"

    check_case '"1"^^xsd:integer：LANG(?n) = "" 命中 1 行' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/q> ?n . FILTER (LANG(?n) = "") }')" \
        "$CHECK_QUERY_PY" "1" "http://logic.local/a"
}

# ===================== 测试 3：带语言标签的字面量行为不变 =====================
test_lang_tagged() {
    divider
    echo -e "${PURPLE}📌 测试 3：带语言标签的字面量不受影响${NC}"
    divider

    check_case '对照 "abc"@en：LANG(?label) = "en" 命中 1 行' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/lang> && LANG(?label) = "en") }')" \
        "$CHECK_QUERY_PY" "1" "http://logic.local/lang"

    check_case '"abc"@en：LANG(?label) = "" 不命中' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/lang> && LANG(?label) = "") }')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case '"abc"@en：LANG(?label) != "en" 不命中' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/lang> && LANG(?label) != "en") }')" \
        "$CHECK_QUERY_PY" "0" ""
}

# ===================== 测试 4：反向探针与负例 =====================
test_negative() {
    divider
    echo -e "${PURPLE}📌 测试 4：反向探针 LANG(?x) != \"\" 与负例${NC}"
    divider

    check_case 'plain "abc"：LANG(?label) != "" 不命中（0 行）' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/plain> && LANG(?label) != "") }')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case 'plain "abc"：LANG(?label) = "en" 不命中' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/plain> && LANG(?label) = "en") }')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case '"abc"^^xsd:string：LANG(?label) != "" 不命中（0 行）' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?s = <http://logic.local/typed> && LANG(?label) != "") }')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case 'LANG(?label) = "" 命中全部 3 行无语言标签的字面量' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (LANG(?label) = "") } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "3" "http://logic.local/empty,http://logic.local/plain,http://logic.local/typed"

    check_case 'LANG(?s) = "" 对 IRI 参数仍是类型错误（0 行）' \
        "$(call_query 'SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (LANG(?s) = "") }')" \
        "$CHECK_QUERY_PY" "0" ""
}

# ===================== 主流程 =====================
main() {
    divider
    echo -e "${PURPLE}          🚀 gStore issue #168 LANG() 空语言标签测试${NC}"
    divider

    cleanup_db

    if test_build_and_load; then
        test_lang_empty
        test_lang_tagged
        test_negative
    else
        echo -e "${RED}❌ 构建/加载测试库失败，后续用例跳过${NC}"
    fi

    divider
    echo -e "${GREEN}✅ 通过：${PASS_NUM}${NC}"
    if [ "${FAIL_NUM}" -gt 0 ]; then
        echo -e "${RED}❌ 失败：${FAIL_NUM}${NC}"
    fi
    divider

    cleanup_db
    [ "${FAIL_NUM}" -eq 0 ]
}

main "$@"
