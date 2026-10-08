#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
TEST_DATA_DIR="scripts/test/issue_155_data"

DB_LONG="iss155_long"
DB_INT="iss155_int"
DB_BASIC="iss155_basic"
DB_NUMERIC="iss155_numeric"

XSD="http://www.w3.org/2001/XMLSchema#"

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

# ===================== 用例计数 =====================
PASS_NUM=0
FAIL_NUM=0

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

# 提交一条 SPARQL 查询，返回 JSON 响应
run_query() {
    local db="$1"
    local sparql="$2"
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({'operation': 'query', 'username': sys.argv[3], 'password': sys.argv[4],
                  'db_name': sys.argv[1], 'sparql': sys.argv[2], 'format': 'json'}))
" "$db" "$sparql" "${USERNAME}" "${PASSWORD}")
    call_api "$payload"
}

# ===================== 单用例校验 =====================
check_case() {
    local case_name="$1"
    local result="$2"
    local python_check="$3"
    local err
    if err=$(echo "$result" | python3 -c "$python_check" 2>&1); then
        echo -e "  ${GREEN}PASS${NC}: $case_name"
        PASS_NUM=$((PASS_NUM + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $case_name"
        echo -e "        ${YELLOW}$(echo "$err" | tail -n 1)${NC}"
        FAIL_NUM=$((FAIL_NUM + 1))
    fi
    return 0
}

# 校验查询结果行数（可选校验某个变量的取值集合）
# $1 用例名 $2 响应 $3 期望行数 $4 变量名（不含 ?，留空则只校验行数）$5 期望取值（| 分隔）
check_rows() {
    local case_name="$1"
    local result="$2"
    local expected_num="$3"
    local var_name="$4"
    local expected_vals="$5"
    check_case "$case_name" "$result" "
import sys, json
d = json.load(sys.stdin)
assert d.get('StatusCode') == 0, 'StatusCode=%s' % d.get('StatusCode')
bindings = d.get('results', {}).get('bindings', [])
assert len(bindings) == ${expected_num}, 'expected ${expected_num} rows, got %d: %s' % (len(bindings), bindings)
var_name = '${var_name}'
if var_name:
    vals = [v.get('value') for b in bindings for k, v in b.items() if k == var_name]
    expected = [x for x in '${expected_vals}'.split('|') if x]
    assert sorted(vals) == sorted(expected), 'expected %s, got %s' % (expected, vals)
print('OK')
"
}

# ===================== 清理旧数据 =====================
cleanup_dbs() {
    for db in ${DB_LONG} ${DB_INT} ${DB_BASIC} ${DB_NUMERIC}; do
        # 先通过 drop 从系统库中注销，再删除数据目录，保证脚本可重复执行
        call_api '{"operation":"drop","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${db}"'"}' > /dev/null 2>&1 || true
        rm -rf dbhome/${db}.db 2>/dev/null || true
    done
}

# ===================== 构建测试数据 =====================
build_db() {
    local db="$1"
    local data_file="$2"
    local expected_num="$3"
    local result=$(call_api '{"operation":"build","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${db}"'","db_path":"'"${data_file}"'"}')
    check_case "build ${db} (${data_file})" "$result" "
import sys, json
d = json.load(sys.stdin)
assert d.get('StatusCode') == 0, 'build failed: %s' % d
assert d.get('success_num') == ${expected_num}, 'expected ${expected_num} triples, got %s' % d.get('success_num')
print('OK')
"
    # 构建失败时不执行 load，避免加载不存在的数据库
    if ! echo "$result" | grep -q '"StatusCode":0'; then
        return 0
    fi
    call_api '{"operation":"load","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${db}"'"}' > /dev/null
    return 0
}

# ===================== 测试 1：xsd:long 数据（issue 前三组查询） =====================
test_long() {
    divider
    echo -e "${PURPLE}📌 测试 1：xsd:long 上的 ISLITERAL / ISNUMERIC / DATATYPE${NC}"
    divider

    local P="<http://logic.local/n>"
    local result

    result=$(run_query "${DB_LONG}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISLITERAL(?n)) }")
    check_rows "longs: ISLITERAL(?n) returns both rows" "$result" 2 "s" \
        "http://logic.local/c|http://logic.local/d"

    result=$(run_query "${DB_LONG}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISNUMERIC(?n)) }")
    check_rows "longs: ISNUMERIC(?n) returns both rows" "$result" 2 "s" \
        "http://logic.local/c|http://logic.local/d"

    result=$(run_query "${DB_LONG}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (DATATYPE(?n) = <${XSD}long>) }")
    check_rows "longs: DATATYPE(?n) = xsd:long returns both rows" "$result" 2 "s" \
        "http://logic.local/c|http://logic.local/d"

    result=$(run_query "${DB_LONG}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (DATATYPE(?n) = <${XSD}int>) }")
    check_rows "longs: DATATYPE(?n) is not xsd:int" "$result" 0

    result=$(run_query "${DB_LONG}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = \"2\"^^<${XSD}long>) }")
    check_rows "longs: \"2\"^^xsd:long = \"2\"^^xsd:long" "$result" 1 "s" "http://logic.local/c"

    result=$(run_query "${DB_LONG}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n != \"2\"^^<${XSD}long>) }")
    check_rows "longs: \"3\"^^xsd:long != \"2\"^^xsd:long" "$result" 1 "s" "http://logic.local/d"
}

# ===================== 测试 2：xsd:int 数据（issue 后两组查询） =====================
test_int() {
    divider
    echo -e "${PURPLE}📌 测试 2：xsd:int 上的自相等 / ISNUMERIC / DATATYPE${NC}"
    divider

    local P="<http://logic.local/n>"
    local result

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = \"2\"^^<${XSD}int>) }")
    check_rows "ints: \"2\"^^xsd:int = \"2\"^^xsd:int" "$result" 1 "s" "http://logic.local/a"

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISNUMERIC(?n)) }")
    check_rows "ints: ISNUMERIC(?n) returns the row" "$result" 1 "s" "http://logic.local/a"

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISLITERAL(?n)) }")
    check_rows "ints: ISLITERAL(?n) returns the row" "$result" 1 "s" "http://logic.local/a"

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (DATATYPE(?n) = <${XSD}int>) }")
    check_rows "ints: DATATYPE(?n) = xsd:int returns the row" "$result" 1 "s" "http://logic.local/a"

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (DATATYPE(?n) = <${XSD}long>) }")
    check_rows "ints: DATATYPE(?n) is not xsd:long" "$result" 0

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = \"2\"^^<${XSD}integer>) }")
    check_rows "ints: \"2\"^^xsd:int = \"2\"^^xsd:integer (same value space)" "$result" 1 "s" "http://logic.local/a"

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n < \"3\"^^<${XSD}int>) }")
    check_rows "ints: \"2\"^^xsd:int < \"3\"^^xsd:int" "$result" 1 "s" "http://logic.local/a"

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n > \"3\"^^<${XSD}int>) }")
    check_rows "ints: \"2\"^^xsd:int > \"3\"^^xsd:int is false" "$result" 0

    result=$(run_query "${DB_INT}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = \"3\"^^<${XSD}int>) }")
    check_rows "ints: \"2\"^^xsd:int = \"3\"^^xsd:int is false" "$result" 0
}

# ===================== 测试 3：IRI 与 xsd:integer 对照（不回归） =====================
test_basic_control() {
    divider
    echo -e "${PURPLE}📌 测试 3：IRI / 普通字面量 / xsd:integer 对照${NC}"
    divider

    local P="<http://logic.local/n>"
    local result

    result=$(run_query "${DB_BASIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = <http://logic.local/o>) }")
    check_rows "basics: IRI object is stored (sanity check)" "$result" 1 "s" "http://logic.local/f"

    result=$(run_query "${DB_BASIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISLITERAL(?n)) }")
    check_rows "basics: ISLITERAL is false for IRI, true for literals" "$result" 2 "s" \
        "http://logic.local/e|http://logic.local/g"

    result=$(run_query "${DB_BASIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISNUMERIC(?n)) }")
    check_rows "basics: ISNUMERIC is false for IRI and plain literal" "$result" 1 "s" "http://logic.local/e"

    result=$(run_query "${DB_BASIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (DATATYPE(?n) = <${XSD}integer>) }")
    check_rows "basics: DATATYPE(?n) = xsd:integer is unchanged" "$result" 1 "s" "http://logic.local/e"

    result=$(run_query "${DB_BASIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = \"2\"^^<${XSD}integer>) }")
    check_rows "basics: \"2\"^^xsd:integer = \"2\"^^xsd:integer is unchanged" "$result" 1 "s" "http://logic.local/e"

    result=$(run_query "${DB_BASIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (DATATYPE(?n) = <${XSD}string>) }")
    check_rows "basics: DATATYPE of plain literal is xsd:string" "$result" 1 "s" "http://logic.local/g"
}

# ===================== 测试 4：全部数值类型 =====================
test_numeric_family() {
    divider
    echo -e "${PURPLE}📌 测试 4：整数族 / decimal / float / double 数值语义${NC}"
    divider

    local P="<http://logic.local/n>"
    local result

    result=$(run_query "${DB_NUMERIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISNUMERIC(?n)) }")
    check_rows "numerics: ISNUMERIC(?n) covers all 12 numeric literals" "$result" 12

    result=$(run_query "${DB_NUMERIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (ISLITERAL(?n)) }")
    check_rows "numerics: ISLITERAL(?n) covers all 12 numeric literals" "$result" 12

    result=$(run_query "${DB_NUMERIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (DATATYPE(?n) = <${XSD}unsignedInt>) }")
    check_rows "numerics: DATATYPE(?n) = xsd:unsignedInt returns only s7" "$result" 1 "s" "http://logic.local/s7"

    result=$(run_query "${DB_NUMERIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = \"2\"^^<${XSD}int>) }")
    check_rows "numerics: value 2 of the whole integer family equals \"2\"^^xsd:int" "$result" 9 "s" \
        "http://logic.local/s1|http://logic.local/s2|http://logic.local/s3|http://logic.local/s4|http://logic.local/s5|http://logic.local/s6|http://logic.local/s7|http://logic.local/s8|http://logic.local/s9"

    result=$(run_query "${DB_NUMERIC}" "SELECT ?s WHERE { ?s ${P} ?n . FILTER (?n = \"7.5\"^^<${XSD}double>) }")
    check_rows "numerics: \"7.5\" equals decimal/float/double of the same value" "$result" 3 "s" \
        "http://logic.local/s10|http://logic.local/s11|http://logic.local/s12"
}

# ===================== 主流程 =====================
main() {
    divider
    echo -e "${PURPLE}          🚀 gStore issue #155 派生整数类型测试${NC}"
    divider

    local response=$(call_api '{"operation":"check"}')
    if ! echo "${response}" | grep -q '"StatusCode":0'; then
        echo -e "${RED}❌ gStore 服务未启动，请先执行 ./bin/gserver -b${NC}"
        return 1
    fi

    cleanup_dbs

    build_db "${DB_LONG}"    "${TEST_DATA_DIR}/longs.nt"    2
    build_db "${DB_INT}"     "${TEST_DATA_DIR}/ints.nt"     1
    build_db "${DB_BASIC}"   "${TEST_DATA_DIR}/basics.nt"   3
    build_db "${DB_NUMERIC}" "${TEST_DATA_DIR}/numerics.nt" 12

    test_long
    test_int
    test_basic_control
    test_numeric_family

    divider
    echo -e "${GREEN}✅ 通过：${PASS_NUM}${NC}"
    if [ ${FAIL_NUM} -gt 0 ]; then
        echo -e "${RED}❌ 失败：${FAIL_NUM}${NC}"
    fi
    divider

    cleanup_dbs

    # 有失败用例时退出码非 0
    [ ${FAIL_NUM} -eq 0 ]
}

main "$@"
