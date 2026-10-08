#!/bin/bash
set -eo pipefail

# ===================== 配置 =====================
# issue 169: MIN() 在聚合值全部超过 INT_MAX 时返回未绑定
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
DB_NAME="issue169"
DATA_FILE="scripts/test/issue_169_data/nums.nt"
NS="http://logic.local/"
XSD_DECIMAL="http://www.w3.org/2001/XMLSchema#decimal"
XSD_INTEGER="http://www.w3.org/2001/XMLSchema#integer"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS_NUM=0
FAIL_NUM=0

# ===================== 自动获取端口 =====================
PORT=$(grep -m1 '^port=' "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2 | xargs)
if [ -z "${PORT}" ]; then
    PORT=9000
fi
API_URL="http://127.0.0.1:${PORT}/api"

# 删除临时数据库：drop 会同时清理 system.db 中的注册信息
drop_db() {
    call_api "$(build_request "drop" "{\"is_backup\":\"false\"}")" > /dev/null 2>&1 || true
}

cleanup() {
    drop_db
    rm -rf "dbhome/${DB_NAME}.db"
}
trap cleanup EXIT

divider() {
    echo -e "${BLUE}=========================================================================${NC}"
}

# ===================== API 调用 =====================
call_api() {
    curl -s --noproxy '*' -X POST -H 'Content-Type: application/json' -d "$1" "${API_URL}"
}

# 构造请求 JSON，避免 SPARQL 中的引号转义问题
build_request() {
    local operation="$1"
    local extra_param="$2"
    python3 -c 'import json, sys
operation, username, password, db_name, extra_param = sys.argv[1:6]
data = {"operation": operation, "username": username, "password": password, "db_name": db_name}
if extra_param:
    data.update(json.loads(extra_param))
print(json.dumps(data))' "${operation}" "${USERNAME}" "${PASSWORD}" "${DB_NAME}" "${extra_param}"
}

# ===================== 检查服务是否启动 =====================
check_service() {
    echo -e "${YELLOW}检查 gStore 服务状态...${NC}"
    response=$(call_api '{"operation":"check"}' 2>/dev/null || echo "failed")
    if echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${GREEN}服务已启动${NC}"
        return 0
    else
        echo -e "${RED}服务未启动，请先在当前目录执行 ./bin/gserver -b${NC}"
        return 1
    fi
}

# ===================== 构建并加载测试数据库 =====================
prepare_db() {
    cleanup
    echo -e "${YELLOW}构建数据库 ${DB_NAME}...${NC}"
    response=$(call_api "$(build_request "build" "{\"db_path\":\"${DATA_FILE}\"}")")
    if ! echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${RED}构建数据库失败: ${response}${NC}"
        exit 1
    fi

    echo -e "${YELLOW}加载数据库 ${DB_NAME}...${NC}"
    response=$(call_api "$(build_request "load" "")")
    if ! echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${RED}加载数据库失败: ${response}${NC}"
        exit 1
    fi
}

# ===================== 断言聚合结果 =====================
# 结果必须恰好一行、变量已绑定，且 type / datatype / lexical value 完全一致
assert_aggregate() {
    local case_name="$1"
    local response="$2"
    local var="$3"
    local exp_type="$4"
    local exp_datatype="$5"
    local exp_value="$6"
    local reason=""

    if reason=$(printf '%s' "${response}" | python3 -c 'import json, sys
var, exp_type, exp_datatype, exp_value = sys.argv[1:5]
try:
    resp = json.loads(sys.stdin.read())
except Exception as e:
    print("invalid json response: %s" % e)
    sys.exit(1)
if resp.get("StatusCode") != 0:
    print("StatusCode=%s, StatusMsg=%s" % (resp.get("StatusCode"), resp.get("StatusMsg")))
    sys.exit(1)
bindings = resp.get("results", {}).get("bindings", [])
if len(bindings) != 1:
    print("expected exactly 1 result row, got %d" % len(bindings))
    sys.exit(1)
row = bindings[0]
if var not in row:
    print("?%s is unbound, row = %s" % (var, json.dumps(row)))
    sys.exit(1)
cell = row[var]
got = (cell.get("type", ""), cell.get("datatype", ""), cell.get("value", ""))
exp = (exp_type, exp_datatype, exp_value)
if got != exp:
    print("expected type=%s datatype=%s value=%s, got type=%s datatype=%s value=%s" % (exp + got))
    sys.exit(1)
print("ok")' "${var}" "${exp_type}" "${exp_datatype}" "${exp_value}" 2>&1); then
        echo -e "${GREEN}[PASS]${NC} ${case_name}"
        PASS_NUM=$((PASS_NUM + 1))
    else
        echo -e "${RED}[FAIL]${NC} ${case_name}"
        echo -e "${RED}       reason: ${reason}${NC}"
        echo -e "${RED}       response: ${response}${NC}"
        FAIL_NUM=$((FAIL_NUM + 1))
    fi
}

# 执行一条聚合查询并断言结果
run_case() {
    local case_name="$1"
    local sparql="$2"
    local var="$3"
    local exp_type="$4"
    local exp_datatype="$5"
    local exp_value="$6"

    local response
    response=$(call_api "$(build_request "query" "$(python3 -c 'import json, sys
print(json.dumps({"sparql": sys.argv[1], "format": "json"}))' "${sparql}")")")
    assert_aggregate "${case_name}" "${response}" "${var}" "${exp_type}" "${exp_datatype}" "${exp_value}"
}

# ===================== 主流程 =====================
divider
echo -e "issue 169: MIN() over values beyond INT_MAX"
divider

check_service
prepare_db

divider
echo -e "${YELLOW}开始执行聚合查询用例...${NC}"
divider

# 1. 复现用例：所有 decimal 值都超过 INT_MAX
run_case "MIN over decimals > INT_MAX" \
    "SELECT (MIN(?n) AS ?min) WHERE { ?s <${NS}n_big> ?n . }" \
    "min" "typed-literal" "${XSD_DECIMAL}" "3000000000.0"

# 2. 最大值不受影响（回归对照）
run_case "MAX over decimals > INT_MAX" \
    "SELECT (MAX(?n) AS ?max) WHERE { ?s <${NS}n_big> ?n . }" \
    "max" "typed-literal" "${XSD_DECIMAL}" "4000000000.0"

# 3. 最小值出现在第二行时同样正确
run_case "MIN over decimals > INT_MAX (smaller value in second row)" \
    "SELECT (MIN(?n) AS ?min) WHERE { ?s <${NS}n_big_rev> ?n . }" \
    "min" "typed-literal" "${XSD_DECIMAL}" "3000000000.0"

# 4. DISTINCT 聚合路径
run_case "MIN DISTINCT over decimals > INT_MAX" \
    "SELECT (MIN(DISTINCT ?n) AS ?min) WHERE { ?s <${NS}n_big> ?n . }" \
    "min" "typed-literal" "${XSD_DECIMAL}" "3000000000.0"

# 5. 小数值对照
run_case "MIN over small decimals" \
    "SELECT (MIN(?n) AS ?min) WHERE { ?s <${NS}n_dec> ?n . }" \
    "min" "typed-literal" "${XSD_DECIMAL}" "3.5"

run_case "MAX over small decimals" \
    "SELECT (MAX(?n) AS ?max) WHERE { ?s <${NS}n_dec> ?n . }" \
    "max" "typed-literal" "${XSD_DECIMAL}" "4.5"

# 6. 整数对照
run_case "MIN over small integers" \
    "SELECT (MIN(?n) AS ?min) WHERE { ?s <${NS}n_int> ?n . }" \
    "min" "typed-literal" "${XSD_INTEGER}" "3"

run_case "MAX over small integers" \
    "SELECT (MAX(?n) AS ?max) WHERE { ?s <${NS}n_int> ?n . }" \
    "max" "typed-literal" "${XSD_INTEGER}" "4"

# 7. GROUP BY 路径
run_case "MIN over decimals > INT_MAX with GROUP BY" \
    "SELECT ?s (MIN(?n) AS ?min) WHERE { ?s <${NS}n_big_grp> ?n . } GROUP BY ?s" \
    "min" "typed-literal" "${XSD_DECIMAL}" "3000000000.0"

divider
echo -e "总计: ${PASS_NUM} PASS, ${FAIL_NUM} FAIL"
divider

if [ "${FAIL_NUM}" -ne 0 ]; then
    echo -e "${RED}测试失败${NC}"
    exit 1
fi

echo -e "${GREEN}全部用例通过${NC}"
exit 0
