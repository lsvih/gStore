#!/bin/bash
# Issue #161 复现与回归测试：
#   谓词位置变量（?s ?p ?o 中的 ?p）在 FILTER/BIND 表达式中取值错误。
#   用例覆盖 issue 中的全部查询、各合取项的单独对照与 STR(?s)/STR(?o) 对照。
set -eo pipefail

# ===================== 配置 =====================
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
DB_MAIN="issue161"
DB_LIT="issue161_lit"
DATA_MAIN="scripts/test/issue_161_data/data.nt"
DATA_LIT="scripts/test/issue_161_data/literal.nt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ===================== 自动获取端口 =====================
PORT=$(grep -m1 'port=' "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2 | xargs)
if [ -z "${PORT}" ]; then
    PORT=9000
fi
API_URL="http://127.0.0.1:${PORT}/api"

TMP_DIR=$(mktemp -d)
TMP_PAYLOAD="${TMP_DIR}/payload.json"
TMP_RESP="${TMP_DIR}/response.json"

PASS_NUM=0
FAIL_NUM=0
NEED_STOP=0

divider() {
    echo -e "${BLUE}=========================================================================${NC}"
}

# ===================== 断言脚本 =====================
# 参数：$1 响应 JSON 文件，$2 期望的绑定 JSON 数组（顺序无关）
ASSERT_PY='
import json, sys

with open(sys.argv[1]) as f:
    resp = json.load(f)
expect = json.loads(sys.argv[2])

if resp.get("StatusCode") != 0:
    print("  StatusCode=%s StatusMsg=%s" % (resp.get("StatusCode"), resp.get("StatusMsg")))
    sys.exit(1)

bindings = resp.get("results", {}).get("bindings", [])
rows = [{k: v.get("value") for k, v in b.items()} for b in bindings]
key = lambda r: json.dumps(r, sort_keys=True)
if sorted(rows, key=key) != sorted(expect, key=key):
    print("  期望 %d 行: %s" % (len(expect), json.dumps(sorted(expect, key=key), sort_keys=True)))
    print("  实际 %d 行: %s" % (len(rows), json.dumps(sorted(rows, key=key), sort_keys=True)))
    sys.exit(1)
sys.exit(0)
'

# ===================== 检查服务是否启动 =====================
check_service() {
    response=$(curl -s --noproxy '*' -X POST \
        -H 'Content-Type: application/json' \
        -d '{"operation":"check"}' \
        "${API_URL}" 2>/dev/null || echo "failed")
    if echo "${response}" | grep -q '"StatusCode":0'; then
        return 0
    else
        return 1
    fi
}

# ===================== 调用接口 =====================
# 参数：$1 JSON 请求体字符串
call_api() {
    printf '%s' "$1" > "${TMP_PAYLOAD}"
    curl -s --noproxy '*' -X POST -H 'Content-Type: application/json' \
        --data-binary @"${TMP_PAYLOAD}" "${API_URL}" 2>/dev/null || echo '{"StatusCode":-1}'
}

# ===================== 执行查询并断言结果 =====================
# 参数：$1 用例名，$2 数据库名，$3 SPARQL 语句，$4 期望的绑定 JSON 数组
run_case() {
    local name="$1"
    local db="$2"
    local sparql="$3"
    local expect="$4"
    local payload resp

    payload=$(python3 -c '
import json, sys
print(json.dumps({"operation": "query", "username": "'"${USERNAME}"'", "password": "'"${PASSWORD}"'",
                  "db_name": sys.argv[1], "format": "json", "sparql": sys.argv[2]}))
' "$db" "$sparql")
    resp=$(call_api "$payload")
    printf '%s' "$resp" > "${TMP_RESP}"

    echo -e "${PURPLE}【用例】${name}${NC}"
    echo "  SPARQL: ${sparql}"
    if python3 -c "${ASSERT_PY}" "${TMP_RESP}" "$expect"; then
        echo -e "  ${GREEN}PASS${NC}"
        PASS_NUM=$((PASS_NUM + 1))
    else
        echo -e "  ${RED}FAIL${NC}"
        FAIL_NUM=$((FAIL_NUM + 1))
    fi
}

# ===================== 清理临时数据库 =====================
remove_db() {
    local db="$1"
    call_api "{\"operation\":\"unload\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${db}\"}" > /dev/null 2>&1
    call_api "{\"operation\":\"drop\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${db}\",\"is_backup\":\"false\"}" > /dev/null 2>&1
    rm -rf "dbhome/${db}.db"
}

cleanup() {
    local db
    for db in "${DB_MAIN}" "${DB_LIT}"; do
        remove_db "${db}"
    done
    rm -rf "${TMP_DIR}"
    if [ "${NEED_STOP}" -eq 1 ]; then
        ./bin/gserver -t > /dev/null 2>&1 || fuser -k "${PORT}/tcp" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ===================== 主流程 =====================
divider
echo -e "${PURPLE}   Issue #161 谓词位置变量表达式取值 测试${NC}"
divider

# 1. 确认服务状态
if check_service; then
    echo -e "${GREEN}服务已启动${NC}"
else
    echo -e "${YELLOW}服务未启动，正在启动...${NC}"
    ./bin/gserver -b
    NEED_STOP=1
    for _ in $(seq 1 30); do
        if check_service; then
            break
        fi
        sleep 1
    done
    if ! check_service; then
        echo -e "${RED}服务启动失败${NC}"
        exit 1
    fi
fi

# 2. 构建并加载测试库
for item in "${DB_MAIN}:${DATA_MAIN}" "${DB_LIT}:${DATA_LIT}"; do
    db="${item%%:*}"
    data="${item##*:}"
    remove_db "${db}"
    resp=$(call_api "{\"operation\":\"build\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${db}\",\"db_path\":\"${data}\"}")
    if ! echo "${resp}" | grep -q '"StatusCode":0'; then
        echo -e "${RED}数据库 ${db} 构建失败: ${resp}${NC}"
        exit 1
    fi
    resp=$(call_api "{\"operation\":\"load\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${db}\"}")
    if ! echo "${resp}" | grep -q '"StatusCode":0'; then
        echo -e "${RED}数据库 ${db} 加载失败: ${resp}${NC}"
        exit 1
    fi
    echo -e "${GREEN}数据库 ${db} 构建并加载完成${NC}"
done

# 3. issue 用例：谓词变量与主语变量的合取 FILTER
divider
echo -e "${PURPLE}用例组 1：FILTER 中的谓词位置变量${NC}"
divider
run_case "合取 FILTER (?p=IRI && ?s=IRI)" "${DB_MAIN}" \
    'SELECT ?s ?p WHERE { ?s ?p ?o . FILTER (?p = <http://logic.local/p> && ?s = <http://logic.local/a>) }' \
    '[{"s":"http://logic.local/a","p":"http://logic.local/p"}]'
run_case "合取 FILTER (?s=IRI && ?p=IRI) 交换顺序" "${DB_MAIN}" \
    'SELECT ?s ?p WHERE { ?s ?p ?o . FILTER (?s = <http://logic.local/a> && ?p = <http://logic.local/p>) }' \
    '[{"s":"http://logic.local/a","p":"http://logic.local/p"}]'
run_case "对照：单个合取项 ?s=IRI" "${DB_MAIN}" \
    'SELECT ?s ?p WHERE { ?s ?p ?o . FILTER (?s = <http://logic.local/a>) }' \
    '[{"s":"http://logic.local/a","p":"http://logic.local/p"}]'
run_case "对照：单个合取项 ?p=IRI" "${DB_MAIN}" \
    'SELECT ?s ?p WHERE { ?s ?p ?o . FILTER (?p = <http://logic.local/p>) }' \
    '[{"s":"http://logic.local/a","p":"http://logic.local/p"},{"s":"http://logic.local/b","p":"http://logic.local/p"}]'
run_case "合取 FILTER (?p=IRI && ?o=IRI)" "${DB_MAIN}" \
    'SELECT ?s ?p ?o WHERE { ?s ?p ?o . FILTER (?p = <http://logic.local/p> && ?o = <http://logic.local/o1>) }' \
    '[{"s":"http://logic.local/a","p":"http://logic.local/p","o":"http://logic.local/o1"}]'
run_case "对照：单个合取项 ?o=IRI" "${DB_MAIN}" \
    'SELECT ?s ?o WHERE { ?s ?p ?o . FILTER (?o = <http://logic.local/o1>) }' \
    '[{"s":"http://logic.local/a","o":"http://logic.local/o1"}]'

# 4. issue 用例：BIND 中的谓词位置变量
divider
echo -e "${PURPLE}用例组 2：BIND 表达式中的谓词位置变量${NC}"
divider
run_case "BIND(STR(?p) AS ?ps)" "${DB_MAIN}" \
    'SELECT ?s ?ps WHERE { ?s ?p ?o . BIND(STR(?p) AS ?ps) }' \
    '[{"s":"http://logic.local/a","ps":"http://logic.local/p"},{"s":"http://logic.local/b","ps":"http://logic.local/p"}]'
run_case "对照：BIND(STR(?s) AS ?ps)" "${DB_MAIN}" \
    'SELECT ?s ?ps WHERE { ?s ?p ?o . BIND(STR(?s) AS ?ps) }' \
    '[{"s":"http://logic.local/a","ps":"http://logic.local/a"},{"s":"http://logic.local/b","ps":"http://logic.local/b"}]'
run_case "对照：BIND(STR(?o) AS ?ps)" "${DB_MAIN}" \
    'SELECT ?s ?ps WHERE { ?s ?p ?o . BIND(STR(?o) AS ?ps) }' \
    '[{"s":"http://logic.local/a","ps":"http://logic.local/o1"},{"s":"http://logic.local/b","ps":"http://logic.local/o2"}]'

# 5. 回归用例：谓词变量与字面量变量混用
divider
echo -e "${PURPLE}用例组 3：谓词位置变量与字面量变量的混用回归${NC}"
divider
run_case "合取 FILTER (?p=IRI && ?o=字面量)" "${DB_LIT}" \
    'SELECT ?s ?p ?o WHERE { ?s ?p ?o . FILTER (?p = <http://logic.local/q> && ?o = "hello") }' \
    '[{"s":"http://logic.local/x","p":"http://logic.local/q","o":"hello"}]'
run_case "对照：单个合取项 ?o=字面量" "${DB_LIT}" \
    'SELECT ?s ?o WHERE { ?s <http://logic.local/q> ?o . FILTER (?o = "hello") }' \
    '[{"s":"http://logic.local/x","o":"hello"}]'
run_case "对照：单个合取项 ?p=IRI" "${DB_LIT}" \
    'SELECT ?s ?p ?o WHERE { ?s ?p ?o . FILTER (?p = <http://logic.local/q>) }' \
    '[{"s":"http://logic.local/x","p":"http://logic.local/q","o":"hello"},{"s":"http://logic.local/y","p":"http://logic.local/q","o":"world"}]'
run_case "BIND(STR(?p) AS ?ps) 逐行取值" "${DB_LIT}" \
    'SELECT ?s ?ps WHERE { ?s ?p ?o . BIND(STR(?p) AS ?ps) }' \
    '[{"s":"http://logic.local/x","ps":"http://logic.local/q"},{"s":"http://logic.local/y","ps":"http://logic.local/q"},{"s":"http://logic.local/z","ps":"http://logic.local/r"}]'

# ===================== 汇总 =====================
divider
echo -e "用例总数: $((PASS_NUM + FAIL_NUM))  通过: ${GREEN}${PASS_NUM}${NC}  失败: ${RED}${FAIL_NUM}${NC}"
divider

if [ "${FAIL_NUM}" -ne 0 ]; then
    echo -e "${RED}Issue #161 测试失败${NC}"
    exit 1
fi
echo -e "${GREEN}Issue #161 测试全部通过${NC}"
exit 0
