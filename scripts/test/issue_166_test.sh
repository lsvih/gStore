#!/bin/bash
set -eo pipefail

# ===================== 【说明】 =====================
# issue #166：ISLITERAL() 对自定义 datatype 的字面量（如 "abc"^^<http://logic.local/T>）返回 false。
# RDF 1.1 Concepts §3.3 / SPARQL 1.1 §17.4.2 规定：任何带 datatype IRI 的 typed literal 都是 literal。

# ===================== 【全局配置】 =====================
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
DB_NAME="iss166"
DB_PATH="scripts/test/issue_166_data/custom.nt"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ===================== 端口配置 =====================
PORT=$(grep -m1 'port=' "${CONF_FILE}" 2>/dev/null)
PORT_STR="${PORT#*=}"
API_URL="http://127.0.0.1:${PORT_STR}/api"

# ===================== 结果统计 =====================
TOTAL=0
PASSED=0
FAILED=0

divider() {
    echo -e "${BLUE}=========================================================================${NC}"
}

# ===================== 请求封装 =====================
call_api() {
    local data="$1"
    curl -s --noproxy '*' -X POST -H 'Content-Type: application/json' \
        -d "$data" "$API_URL" 2>/dev/null || echo '{"StatusCode":-1,"StatusMsg":"curl request failed"}'
}

check_service() {
    local response
    response=$(call_api '{"operation":"check"}')
    if echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${GREEN}✅ 服务已启动${NC}"
        return 0
    else
        echo -e "${RED}❌ 服务未启动，请先执行 ./bin/gserver -b${NC}"
        return 1
    fi
}

# 构造并执行查询，返回查询结果 JSON
run_query() {
    local sparql="$1"
    local payload
    payload=$(python3 -c '
import json, sys
print(json.dumps({
    "operation": "query",
    "username": sys.argv[2],
    "password": sys.argv[3],
    "db_name": sys.argv[4],
    "format": "json",
    "sparql": sys.argv[1],
}))
' "$sparql" "${USERNAME}" "${PASSWORD}" "${DB_NAME}")
    call_api "${payload}"
}

# ===================== 断言：结果中变量 var 的取值集合应与 expected 一致 =====================
# 用法：check_case <用例名> <SPARQL> <变量名> <期望值（逗号分隔，空表示无解）>
check_case() {
    local name="$1"
    local sparql="$2"
    local var="$3"
    local expected="$4"

    TOTAL=$((TOTAL + 1))
    local response
    response=$(run_query "${sparql}")

    if ! python3 -c '
import json, sys

name, var, expected = sys.argv[1], sys.argv[2], sys.argv[3]
resp = json.loads(sys.argv[4])
expect = sorted(v for v in expected.split(",") if v != "")

if resp.get("StatusCode", -1) != 0:
    print("      StatusCode=%s, StatusMsg=%s" % (resp.get("StatusCode"), resp.get("StatusMsg")))
    sys.exit(1)
bindings = resp.get("results", {}).get("bindings", [])
actual = sorted(b[var]["value"] for b in bindings if var in b)
print("      rows: %d" % len(bindings))
print("      expect: %s" % expect)
print("      actual: %s" % actual)
if len(bindings) != len(actual):
    print("      some bindings miss the variable %s" % var)
    sys.exit(1)
if actual != expect:
    print("      raw response: %s" % sys.argv[4])
    sys.exit(1)
' "${name}" "${var}" "${expected}" "${response}"; then
        FAILED=$((FAILED + 1))
        echo -e "${RED}❌ FAIL: ${name}${NC}"
        return 0
    fi

    PASSED=$((PASSED + 1))
    echo -e "${GREEN}✅ PASS: ${name}${NC}"
    return 0
}

# ===================== 数据库构建与清理 =====================
build_db() {
    echo -e "${YELLOW}📦 构建测试数据库 ${DB_NAME}（数据：${DB_PATH}）...${NC}"
    local response
    response=$(call_api '{"operation":"build","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","db_path":"'"${DB_PATH}"'"}')
    if ! echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${RED}❌ 构建失败：${response}${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 数据库构建完成${NC}"
}

load_db() {
    echo -e "${YELLOW}📥 加载数据库 ${DB_NAME}...${NC}"
    local response
    response=$(call_api '{"operation":"load","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}')
    if ! echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${RED}❌ 加载失败：${response}${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 数据库加载完成${NC}"
}

cleanup() {
    call_api '{"operation":"drop","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","is_backup":"false"}' > /dev/null 2>&1 || true
    rm -rf "dbhome/${DB_NAME}.db"
}
trap cleanup EXIT

# ===================== 主流程 =====================
divider
echo -e "${PURPLE}🚀 issue #166: ISLITERAL() 对自定义 datatype 字面量的判定${NC}"
divider

check_service
cleanup
build_db
load_db

V="<http://logic.local/v>"

divider
echo -e "${YELLOW}📌 用例 1：issue 原始复现场景（含自定义 datatype 字面量的行）${NC}"
check_case "ISLITERAL 对自定义 datatype 字面量应为 true" \
    "SELECT ?s WHERE { ?s ${V} ?v . FILTER (?s = <http://logic.local/a> && ISLITERAL(?v)) }" \
    "s" "http://logic.local/a"

divider
echo -e "${YELLOW}📌 用例 2：所有字面量都应满足 ISLITERAL（对照数据含 plain/xsd/自定义 datatype）${NC}"
check_case "ISLITERAL 应覆盖 plain/xsd/自定义 datatype 字面量" \
    "SELECT ?s WHERE { ?s ${V} ?v . FILTER (ISLITERAL(?v)) }" \
    "s" "http://logic.local/a,http://logic.local/b,http://logic.local/c,http://logic.local/d,http://logic.local/f,http://logic.local/g,http://logic.local/h"

divider
echo -e "${YELLOW}📌 用例 3：IRI 不满足 ISLITERAL（对照）${NC}"
check_case "ISLITERAL 对 IRI 应为 false（!ISLITERAL 只返回 IRI）" \
    "SELECT ?s WHERE { ?s ${V} ?v . FILTER (!ISLITERAL(?v)) }" \
    "s" "http://logic.local/e"

divider
echo -e "${YELLOW}📌 用例 4：ISIRI 行为不变（对照）${NC}"
check_case "ISIRI 只对 IRI 为 true" \
    "SELECT ?s WHERE { ?s ${V} ?v . FILTER (ISIRI(?v)) }" \
    "s" "http://logic.local/e"

divider
echo -e "${YELLOW}📌 用例 5：查询中的自定义 datatype 常量${NC}"
check_case "ISLITERAL 对常量 \"abc\"^^<http://logic.local/T> 应为 true" \
    "SELECT ?s WHERE { ?s ${V} ?v . FILTER (ISLITERAL(\"abc\"^^<http://logic.local/T>)) }" \
    "s" "http://logic.local/a,http://logic.local/b,http://logic.local/c,http://logic.local/d,http://logic.local/e,http://logic.local/f,http://logic.local/g,http://logic.local/h"

divider
echo -e "${YELLOW}📌 用例 6：查询中的 IRI 常量（对照）${NC}"
check_case "ISLITERAL 对 IRI 常量应为 false" \
    "SELECT ?s WHERE { ?s ${V} ?v . FILTER (ISLITERAL(<http://logic.local/iri>)) }" \
    "s" ""

divider
echo -e "${YELLOW}📌 用例 7：ISNUMERIC 行为不变（对照）${NC}"
check_case "ISNUMERIC 仍只对数值类型为 true" \
    "SELECT ?s WHERE { ?s ${V} ?v . FILTER (ISNUMERIC(?v)) }" \
    "s" "http://logic.local/f,http://logic.local/g"

divider
if [ "${FAILED}" -eq 0 ]; then
    echo -e "${GREEN}🎉 全部 ${TOTAL} 个用例通过${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}❌ 共 ${TOTAL} 个用例，失败 ${FAILED} 个${NC}"
    EXIT_CODE=1
fi
divider
exit ${EXIT_CODE}
