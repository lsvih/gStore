#!/bin/bash
# Issue #164: 字符串字面量中的转义序列（ECHAR）在数据侧与查询侧未归一化，
#             导致 FILTER 等值比较对含转义的字符串字面量永远不成立。
# 用法：先启动服务（./bin/gserver -b），再执行 bash scripts/test/issue_164_test.sh
set -eo pipefail

# ===================== 配置 =====================
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
DB_NAME="iss164"
DATA_FILE="scripts/test/issue_164_data/data.nt"
E1="http://newsrc30.local/e1"
E2="http://newsrc30.local/e2"
E3="http://newsrc30.local/e3"
N1="http://newsrc30.local/n1"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 自动获取端口 =====================
PORT=$(grep -m1 'port=' "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2 | xargs)
if [ -z "${PORT}" ]; then
    PORT=9000
fi
API_URL="http://127.0.0.1:${PORT}/api"

PASS_NUM=0
FAIL_NUM=0

divider() {
    echo -e "${BLUE}=========================================================================${NC}"
}

# ===================== 工具函数 =====================
call_api() {
    curl -s --noproxy '*' -X POST -H 'Content-Type: application/json' -d "$1" "${API_URL}" 2>/dev/null || echo '{"StatusCode":-1}'
}

# 用 python3 拼 JSON 请求体，避免在 shell 里手工转义 SPARQL 中的反斜杠与引号
query_body() {
    python3 -c '
import json, sys
print(json.dumps({
    "operation": "query",
    "username": sys.argv[1],
    "password": sys.argv[2],
    "db_name": sys.argv[3],
    "format": "json",
    "sparql": sys.argv[4],
}))
' "${USERNAME}" "${PASSWORD}" "${DB_NAME}" "$1"
}

# 执行查询并校验 ?s 的结果集：$1 用例描述，$2 SPARQL，$3 期望的 ?s 值（逗号分隔，空表示无结果）
check_query_case() {
    local desc="$1" sparql="$2" expect="$3"
    local resp out
    resp=$(call_api "$(query_body "${sparql}")")
    if out=$(python3 -c '
import json, sys
resp = json.loads(sys.argv[1])
expect = sorted(v for v in sys.argv[2].split(",") if v)
if resp.get("StatusCode") != 0:
    print("  API error: StatusCode=" + str(resp.get("StatusCode")) + " " + str(resp.get("StatusMsg", "")))
    sys.exit(1)
bindings = resp.get("results", {}).get("bindings", [])
got = sorted(b.get("?s", b.get("s", {})).get("value", "") for b in bindings)
if got != expect:
    print("  expect: " + (", ".join(expect) if expect else "(empty)"))
    print("  actual: " + (", ".join(got) if got else "(empty)"))
    sys.exit(1)
' "${resp}" "${expect}" 2>&1); then
        printf "${GREEN}PASS${NC} %s\n" "${desc}"
        PASS_NUM=$((PASS_NUM + 1))
    else
        printf "${RED}FAIL${NC} %s\n" "${desc}"
        [ -n "${out}" ] && echo "${out}"
        FAIL_NUM=$((FAIL_NUM + 1))
    fi
}

# ===================== 检查服务 =====================
divider
echo -e "${YELLOW}🔍 检查 gStore 服务状态...${NC}"
if call_api '{"operation":"check"}' | grep -q '"StatusCode":0'; then
    echo -e "${GREEN}✅ 服务已启动（端口 ${PORT}）${NC}"
else
    echo -e "${RED}❌ 服务未启动，请先执行 ./bin/gserver -b${NC}"
    exit 1
fi
divider

# ===================== 构建并加载数据库 =====================
echo -e "${YELLOW}📦 构建数据库 ${DB_NAME}...${NC}"
# 忽略不存在时的卸载/删除报错，保证脚本可重复执行
call_api "{\"operation\":\"unload\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\"}" > /dev/null
call_api "{\"operation\":\"drop\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\"}" > /dev/null

BUILD_RESP=$(call_api "{\"operation\":\"build\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\",\"db_path\":\"${DATA_FILE}\"}")
if ! echo "${BUILD_RESP}" | grep -q '"StatusCode":0'; then
    echo -e "${RED}❌ 构建失败：${BUILD_RESP}${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 构建完成${NC}"

LOAD_RESP=$(call_api "{\"operation\":\"load\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\"}")
if ! echo "${LOAD_RESP}" | grep -q '"StatusCode":0'; then
    echo -e "${RED}❌ 加载失败：${LOAD_RESP}${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 加载完成${NC}"
divider

# ===================== 用例 =====================
echo -e "${YELLOW}📌 FILTER 等值比较（SPARQL 1.1 §17.3 比较的是解码后的字符串值）${NC}"
check_query_case 'FILTER (?label = "a\"b") 命中 e1' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> ?label . FILTER (?label = "a\"b") }' "${E1}"
check_query_case 'FILTER (?label = "a\nb") 命中 e2' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> ?label . FILTER (?label = "a\nb") }' "${E2}"
check_query_case 'FILTER (?label = "a\tb") 命中 e3' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> ?label . FILTER (?label = "a\tb") }' "${E3}"
check_query_case 'FILTER (?label = "anb") 只命中 n1（对照组）' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> ?label . FILTER (?label = "anb") }' "${N1}"

echo
echo -e "${YELLOW}📌 三元组模式中的字面量对象（与数据侧同样的解码规则）${NC}"
check_query_case '模式 ?s label "a\"b" 命中 e1' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> "a\"b" }' "${E1}"
check_query_case '模式 ?s label "a\nb" 命中 e2' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> "a\nb" }' "${E2}"
check_query_case '模式 ?s label "a\tb" 命中 e3' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> "a\tb" }' "${E3}"
check_query_case '模式 ?s label "anb" 只命中 n1（对照组）' \
    'SELECT ?s WHERE { ?s <http://newsrc30.local/label> "anb" }' "${N1}"

divider
echo -e "用例统计：${GREEN}PASS=${PASS_NUM}${NC} ${RED}FAIL=${FAIL_NUM}${NC}"
divider

if [ "${FAIL_NUM}" -ne 0 ]; then
    echo -e "${RED}❌ 存在失败用例${NC}"
    exit 1
fi
echo -e "${GREEN}🎉 全部用例通过${NC}"
exit 0
