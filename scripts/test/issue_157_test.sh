#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
# issue #157: 语言标签按大小写敏感比较，导致 "hello"@en 与 "hello"@EN 在
# = / CONTAINS / STRSTARTS 中互不匹配（RFC 5646 2.1.1 规定语言标签大小写不敏感）
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
TEST_DATA_DIR="scripts/test/issue_157_data"
DB_NAME="iss157_test"

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

# 单用例校验：$4 期望返回行数，$5 期望返回的语言标签（逗号分隔，可为空）
PASS_NUM=0
FAIL_NUM=0
check_case() {
    local case_name="$1"
    local result="$2"
    local python_check="$3"
    local expect_num="$4"
    local expect_lang="$5"
    local reason=""
    if reason=$(echo "$result" | python3 -c "$python_check" "$expect_num" "$expect_lang" 2>&1); then
        echo -e "  ${GREEN}PASS${NC}: $case_name"
        PASS_NUM=$((PASS_NUM+1))
    else
        echo -e "  ${RED}FAIL${NC}: $case_name"
        echo -e "        ${YELLOW}原因：${NC}$(echo "$reason" | tail -n 1)"
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

# 查询的断言：校验返回行数，并可选校验语言标签集合
CHECK_QUERY_PY=$(cat <<'PY'
import sys, json
d = json.load(sys.stdin)
assert d.get("StatusCode") == 0, "query failed: %s" % d
bindings = d.get("results", {}).get("bindings", [])
expect_num = int(sys.argv[1])
assert len(bindings) == expect_num, "expect %d rows, got %d" % (expect_num, len(bindings))
expect_lang = sys.argv[2]
if expect_lang:
    tags = sorted(b["name"].get("lang", "") for b in bindings)
    assert tags == sorted(expect_lang.split(",")), "expect lang tags %s, got %s" % (expect_lang, tags)
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

    local result=$(call_api '{"operation":"build","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","db_path":"'"${TEST_DATA_DIR}"'/issue_157.nt"}')
    check_case "构建测试库（2 条三元组）" "$result" "$CHECK_BUILD_PY" "2" ""
    [ "${FAIL_NUM}" -eq 0 ] || return 1

    result=$(call_api '{"operation":"load","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}')
    check_case "加载测试库" "$result" "$CHECK_LOAD_PY" "" ""
    [ "${FAIL_NUM}" -eq 0 ] || return 1

    return 0
}

# ===================== 测试 2：= 运算符 =====================
test_equal() {
    divider
    echo -e "${PURPLE}📌 测试 2：等值比较 =（RFC 5646 语言标签大小写不敏感）${NC}"
    divider

    check_case '?name = "hello"@en 命中 @en 与 @EN 两行' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (?name = "hello"@en) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "2" "en,EN"

    check_case '?name = "hello"@EN 命中 @en 与 @EN 两行' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (?name = "hello"@EN) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "2" "en,EN"

    check_case '?name = "hello"@fr 不命中任何行' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (?name = "hello"@fr) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case '?name = "HELLO"@en 不命中（字符串内容大小写敏感）' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (?name = "HELLO"@en) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case '?name != "hello"@EN 不命中任何行（与 = 一致）' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (?name != "hello"@EN) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case '?name != "hello"@fr 命中两行' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (?name != "hello"@fr) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "2" "en,EN"
}

# ===================== 测试 3：字符串函数参数兼容性 =====================
test_string_functions() {
    divider
    echo -e "${PURPLE}📌 测试 3：CONTAINS / STRSTARTS 参数兼容性${NC}"
    divider

    check_case 'CONTAINS(?name, "ell"@EN) 命中两行' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (CONTAINS(?name, "ell"@EN)) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "2" "en,EN"

    check_case 'CONTAINS("hello"@EN, ?name) 命中两行' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (CONTAINS("hello"@EN, ?name)) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "2" "en,EN"

    check_case 'STRSTARTS(?name, "he"@EN) 命中两行' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (STRSTARTS(?name, "he"@EN)) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "2" "en,EN"

    check_case 'CONTAINS(?name, "ELL"@en) 不命中（字符串内容大小写敏感）' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (CONTAINS(?name, "ELL"@en)) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "0" ""

    check_case 'CONTAINS(?name, "ell"@fr) 不命中（语言标签不同）' \
        "$(call_query 'SELECT ?s ?name WHERE { ?s <http://logic.local/name> ?name . FILTER (CONTAINS(?name, "ell"@fr)) } ORDER BY ?s')" \
        "$CHECK_QUERY_PY" "0" ""
}

# ===================== 测试 4：原始语言标签不受影响 =====================
test_lang_tag_output() {
    divider
    echo -e "${PURPLE}📌 测试 4：查询结果中的语言标签保持原样${NC}"
    divider

    check_case 'SELECT ?name 返回原始语言标签 @en 与 @EN' \
        "$(call_query 'SELECT ?name WHERE { ?s <http://logic.local/name> ?name } ORDER BY ?name')" \
        "$CHECK_QUERY_PY" "2" "en,EN"
}

# ===================== 主流程 =====================
main() {
    divider
    echo -e "${PURPLE}          🚀 gStore issue #157 语言标签大小写测试${NC}"
    divider

    cleanup_db

    if test_build_and_load; then
        test_equal
        test_string_functions
        test_lang_tag_output
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
