#!/bin/bash
set -eo pipefail

# Regression test for issue #152:
# FILTER / IF / ! / && / || must apply the Effective Boolean Value rules
# (SPARQL 1.1 17.2.2) to numeric and string operands.
#
# Usage: run it from the gStore root directory, with the gserver running:
#   ./bin/gserver -b
#   bash scripts/test/issue_152_test.sh

# ===================== 配置 =====================
CONF_FILE="./conf/conf.ini"
DATA_DIR="scripts/test/issue_152_data"
USERNAME="root"
PASSWORD="123456"

DB_NUMS="iss152_nums"
DB_STRS="iss152_strs"
DB_BOOLS="iss152_bools"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ===================== 自动获取端口 =====================
PORT=$(grep -m1 'port=' "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2 | xargs)
if [ -z "${PORT}" ]; then
    PORT=9000
fi
API_URL="http://127.0.0.1:${PORT}/api"

pass_num=0
fail_num=0

# ===================== HTTP API =====================
# Send a JSON body to the HTTP API
api_post() {
    curl -s --noproxy '*' -X POST -H 'Content-Type: application/json' -d "$1" "${API_URL}"
}

# Build a request body from key=value arguments (python escapes the values)
api_request() {
    local body
    body=$(python3 -c '
import json, sys
request = {}
for arg in sys.argv[1:]:
    key, value = arg.split("=", 1)
    request[key] = value
print(json.dumps(request))
' "$@")
    api_post "${body}"
}

# Abort when a request did not succeed
ensure_ok() {
    local response="$1" what="$2"
    if ! grep -q '"StatusCode":0' <<< "${response}"; then
        echo -e "${RED}ERROR: ${what} failed: ${response}${NC}"
        exit 1
    fi
}

# ===================== 环境准备 =====================
check_service() {
    echo -e "${YELLOW}Checking gStore service...${NC}"
    ensure_ok "$(api_post '{"operation":"check"}')" "check"
    echo -e "${GREEN}gStore service is ready on port ${PORT}${NC}"
}

# (Re)build and load one test database
prepare_db() {
    local db_name="$1" rdf_file="$2" response
    api_request "operation=drop" "username=${USERNAME}" "password=${PASSWORD}" \
        "db_name=${db_name}" "is_backup=false" > /dev/null 2>&1 || true
    response=$(api_request "operation=build" "username=${USERNAME}" "password=${PASSWORD}" \
        "db_name=${db_name}" "db_path=${rdf_file}")
    ensure_ok "${response}" "build ${db_name}"
    response=$(api_request "operation=load" "username=${USERNAME}" "password=${PASSWORD}" \
        "db_name=${db_name}")
    ensure_ok "${response}" "load ${db_name}"
    echo -e "${GREEN}database ${db_name} is loaded from ${rdf_file}${NC}"
}

# ===================== 查询 =====================
# Run a SPARQL query and print the sorted local names of the ?s bindings,
# or an ERR_* marker when the query itself failed.
run_query() {
    local response
    response=$(api_request "operation=query" "username=${USERNAME}" "password=${PASSWORD}" \
        "db_name=$1" "sparql=$2" "format=json")
    python3 -c '
import json, sys
try:
    result = json.loads(sys.stdin.read())
except ValueError:
    print("ERR_BAD_JSON")
    sys.exit(0)
if result.get("StatusCode") != 0:
    print("ERR_STATUS_" + str(result.get("StatusCode")))
    sys.exit(0)
names = [binding["s"]["value"].rsplit("/", 1)[-1] for binding in result["results"]["bindings"]]
print(",".join(sorted(names)))
' <<< "${response}"
}

run_case() {
    local name="$1" db_name="$2" sparql="$3" expected="$4" actual
    actual=$(run_query "${db_name}" "${sparql}")
    if [ "${actual}" = "${expected}" ]; then
        echo -e "${GREEN}PASS${NC} ${name} -> [${actual}]"
        pass_num=$((pass_num + 1))
    else
        echo -e "${RED}FAIL${NC} ${name}"
        echo "     sparql:   ${sparql}"
        echo "     expected: [${expected}]"
        echo "     actual:   [${actual}]"
        fail_num=$((fail_num + 1))
    fi
}

# ===================== 测试用例 =====================
# The last argument is the expected ?s result: the sorted local names, "," joined
# (an empty string means "no row").
run_all_cases() {
    # --- issue #152: numeric operands (5 is true, 0 is false) ---
    run_case "numeric FILTER(?n)" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (?n) }" "nonzero"
    run_case "numeric IF(?n,true,false)" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (IF(?n, true, false)) }" "nonzero"
    run_case "numeric ?n && true" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (?n && true) }" "nonzero"
    run_case "numeric false || ?n" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (false || ?n) }" "nonzero"
    # --- issue #152: string operands (zero length is false) ---
    run_case "string FILTER(?l)" "${DB_STRS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/label> ?l . FILTER (?l) }" "plain,typed"
    run_case "string !?l" "${DB_STRS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/label> ?l . FILTER (!?l) }" "empty"
    run_case "string IF(?l,true,false)" "${DB_STRS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/label> ?l . FILTER (IF(?l, true, false)) }" "plain,typed"
    run_case "string ?l && true" "${DB_STRS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/label> ?l . FILTER (?l && true) }" "plain,typed"
    # --- numeric operands: falsy side and the other operators ---
    run_case "numeric !?n" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (!?n) }" "zero"
    run_case "numeric ?n || false" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (?n || false) }" "nonzero"
    run_case "numeric ?n && false" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (?n && false) }" ""
    run_case "numeric IF(?n && false,true,false)" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (IF(?n && false, true, false)) }" ""
    # --- string operands: falsy side and the other operators ---
    run_case "string !?l || false" "${DB_STRS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/label> ?l . FILTER (!?l || false) }" "empty"
    run_case "string ?l || false" "${DB_STRS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/label> ?l . FILTER (?l || false) }" "plain,typed"
    # --- the EBV table of 17.2.2 for the other numeric types ---
    run_case "ebv decimal 0.0 is false" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (\"0.0\"^^<http://www.w3.org/2001/XMLSchema#decimal>) }" ""
    run_case "ebv double 0.5 is true" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (\"0.5\"^^<http://www.w3.org/2001/XMLSchema#double>) }" "nonzero,zero"
    run_case "ebv float 0.0 is false" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (\"0.0\"^^<http://www.w3.org/2001/XMLSchema#float>) }" ""
    run_case "ebv long 7 is true" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (\"7\"^^<http://www.w3.org/2001/XMLSchema#long>) }" "nonzero,zero"
    run_case "ebv double NaN is false" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (\"NaN\"^^<http://www.w3.org/2001/XMLSchema#double>) }" ""
    # --- types outside 17.2.2 must stay a type error (no row kept) ---
    run_case "ebv unknown datatype is error" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (\"5\"^^<http://example.org/num>) }" ""
    run_case "ebv dateTime is error" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (\"2020-01-01T00:00:00\"^^<http://www.w3.org/2001/XMLSchema#dateTime>) }" ""
    run_case "ebv iri is error" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (<http://logic.local/nonzero>) }" ""
    # --- boolean literals must keep their old behaviour ---
    run_case "boolean FILTER(?b)" "${DB_BOOLS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/b> ?b . FILTER (?b) }" "trueval"
    run_case "boolean !?b" "${DB_BOOLS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/b> ?b . FILTER (!?b) }" "falseval"
    run_case "boolean ?b && true" "${DB_BOOLS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/b> ?b . FILTER (?b && true) }" "trueval"
    run_case "boolean false || ?b" "${DB_BOOLS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/b> ?b . FILTER (false || ?b) }" "trueval"
    run_case "boolean IF(?b,true,false)" "${DB_BOOLS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/b> ?b . FILTER (IF(?b, true, false)) }" "trueval"
    # --- control: the comparison still selects the same row ---
    run_case "control ?n > 1" "${DB_NUMS}" \
        "SELECT ?s WHERE { ?s <http://logic.local/n> ?n . FILTER (?n > \"1\"^^<http://www.w3.org/2001/XMLSchema#integer>) }" "nonzero"
}

# ===================== 主流程 =====================
check_service
prepare_db "${DB_NUMS}" "${DATA_DIR}/nums.nt"
prepare_db "${DB_STRS}" "${DATA_DIR}/strs.nt"
prepare_db "${DB_BOOLS}" "${DATA_DIR}/bools.nt"

echo "========================================================================="
run_all_cases
echo "========================================================================="
echo "issue #152: ${pass_num} passed, ${fail_num} failed"

if [ "${fail_num}" -ne 0 ]; then
    echo -e "${RED}issue #152 test FAILED${NC}"
    exit 1
fi
echo -e "${GREEN}issue #152 test PASSED${NC}"
