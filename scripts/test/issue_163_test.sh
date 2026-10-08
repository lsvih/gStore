#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
# 用例来源：https://github.com/pkumod/gStore/issues/163
# 查询模式中的 [] 与空白节点标签应作为新变量处理（SPARQL 1.1 Query §4.1.4）
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
DB_NAME="iss163"
TEST_DATA_DIR="scripts/test/issue_163_data"
RDF_FILE="${TEST_DATA_DIR}/data.nt"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 用例计数
PASS_NUM=0
FAIL_NUM=0

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

# 执行 SPARQL 查询，返回 JSON 格式的响应
run_query() {
    local sparql="$1"
    local esc
    esc=$(echo "$sparql" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | tr -d '\r' | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/\t/\\t/g')
    call_api '{"operation":"query","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","sparql":"'"${esc}"'","format":"json"}'
}

# ===================== 单用例校验 =====================
check_case() {
    local case_name="$1"
    local result="$2"
    local python_check="$3"
    if echo "$result" | python3 -c "$python_check" 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: ${case_name}"
        PASS_NUM=$((PASS_NUM + 1))
    else
        echo -e "  ${RED}FAIL${NC}: ${case_name}"
        echo -e "  ${YELLOW}响应：${NC}${result}"
        FAIL_NUM=$((FAIL_NUM + 1))
    fi
    return 0
}

# 执行一个查询用例并校验
run_case() {
    local case_name="$1"
    local sparql="$2"
    local python_check="$3"
    echo -e "${YELLOW}查询：${NC}${sparql}"
    local result
    result=$(run_query "${sparql}")
    check_case "${case_name}" "${result}" "${python_check}"
}

# ===================== 重置数据库（通过接口卸载并删除） =====================
reset_db() {
    call_api '{"operation":"unload","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}' > /dev/null 2>&1 || true
    call_api '{"operation":"drop","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","is_backup":"false"}' > /dev/null 2>&1 || true
}

# ===================== 准备数据库 =====================
prepare_db() {
    local expect_num="$1"
    divider
    echo -e "${PURPLE}📌 构建并加载数据库 ${DB_NAME}（数据：${RDF_FILE}）${NC}"
    divider

    local result
    result=$(call_api '{"operation":"build","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'","db_path":"'"${RDF_FILE}"'"}')
    check_case "build ${DB_NAME} (${expect_num} triples)" "${result}" "
import sys,json
d=json.load(sys.stdin)
assert d.get(\"StatusCode\")==0, d.get(\"StatusMsg\")
assert d.get(\"success_num\")==${expect_num}, \"expected ${expect_num} triples, got %s\" % d.get(\"success_num\")
"

    result=$(call_api '{"operation":"load","username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'","db_name":"'"${DB_NAME}"'"}')
    check_case "load ${DB_NAME}" "${result}" '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
'
}

# ===================== 测试 1：issue 原始用例 =====================
test_anonymous_subject() {
    divider
    echo -e "${PURPLE}📌 测试 1：匿名空白节点作主语（issue 原始用例）${NC}"
    divider

    # [] <p> ?o 等价于 ?anon <p> ?o，应匹配 2 个主语对应的对象
    run_case "[] 作主语匹配 2 行，且匿名变量不出现在结果中" \
        'SELECT ?o WHERE { [] <http://logic.local/p> ?o . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
assert sorted(r["o"]["value"] for r in b)==["http://logic.local/o1","http://logic.local/o2"], b
for r in b:
    assert sorted(r.keys())==["o"], "anonymous variable should not be projected: %s" % r
'

    # 对照：显式变量作主语，行为不应改变
    run_case "对照：显式变量 ?s 作主语匹配 2 行" \
        'SELECT ?o WHERE { ?s <http://logic.local/p> ?o . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
assert sorted(r["o"]["value"] for r in b)==["http://logic.local/o1","http://logic.local/o2"], b
'

    # ASK：[] <p> ?o 存在解
    run_case "ASK [] 作主语应为 true" \
        'ASK WHERE { [] <http://logic.local/p> ?o . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==1, "expected 1 row, got %d" % len(b)
assert b[0]["_askResult"]["value"]=="true", b[0]
'
}

# ===================== 测试 2：匿名空白节点作宾语 =====================
test_anonymous_object() {
    divider
    echo -e "${PURPLE}📌 测试 2：匿名空白节点作宾语${NC}"
    divider

    # ?s <p> [] 应匹配所有以 p 为谓语的主语
    run_case "[] 作宾语匹配 2 行" \
        'SELECT ?s WHERE { ?s <http://logic.local/p> [] . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
assert sorted(r["s"]["value"] for r in b)==["http://logic.local/a","http://logic.local/b"], b
'

    # 匿名变量参与 join
    run_case "匿名变量与显式变量 join 匹配 2 行" \
        'SELECT ?s WHERE { [] <http://logic.local/p> ?o . ?s <http://logic.local/p> ?o . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
assert sorted(r["s"]["value"] for r in b)==["http://logic.local/a","http://logic.local/b"], b
'
}

# ===================== 测试 3：同一模式中多个匿名空白节点 =====================
test_multiple_anonymous() {
    divider
    echo -e "${PURPLE}📌 测试 3：同一模式中多个匿名空白节点（各自是独立的新变量）${NC}"
    divider

    # 每个 [] 是独立的新变量，[] <p> [] 不要求主语与宾语相同
    run_case "[] <p> [] 匹配 2 行（两个 [] 不是同一变量）" \
        'SELECT * WHERE { [] <http://logic.local/p> [] . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
'

    run_case "ASK [] <p> [] 应为 true" \
        'ASK WHERE { [] <http://logic.local/p> [] . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==1, "expected 1 row, got %d" % len(b)
assert b[0]["_askResult"]["value"]=="true", b[0]
'

    # 两处 [] 作主语是不同变量，?o 为公共连接变量：每个宾语只有唯一主语，故为 2 行
    run_case "两处 [] 作主语是不同变量，匹配 2 行" \
        'SELECT * WHERE { [] <http://logic.local/p> ?o . [] <http://logic.local/p> ?o . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
'
}

# ===================== 测试 5：多个匿名空白节点的相互独立 =====================
# 数据中存在两个主语共用一个宾语，若两个 [] 被错误地当作同一变量则会少解
test_multiple_anonymous_shared_object() {
    divider
    echo -e "${PURPLE}📌 测试 5：多个匿名空白节点相互独立（data_shared.nt）${NC}"
    divider

    # o1 有两个主语、o2 有一个主语；共享变量时会退化为 0 行
    run_case "[] <p> [] 匹配 3 行" \
        'SELECT * WHERE { [] <http://logic.local/p> [] . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==3, "expected 3 rows, got %d" % len(b)
'

    # o1：2 个主语的两两组合共 4 解，o2：1 解，共 5 行；共享变量时只有 3 行
    run_case "两处 [] 作主语相互独立，匹配 5 行" \
        'SELECT * WHERE { [] <http://logic.local/p> ?o . [] <http://logic.local/p> ?o . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==5, "expected 5 rows, got %d" % len(b)
'
}

# ===================== 测试 4：空白节点标签 =====================
test_blank_node_label() {
    divider
    echo -e "${PURPLE}📌 测试 4：空白节点标签 _:b（同一 BGP 内相同标签是同一变量）${NC}"
    divider

    run_case "_:b 作主语匹配 2 行" \
        'SELECT ?o WHERE { _:b <http://logic.local/p> ?o . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
assert sorted(r["o"]["value"] for r in b)==["http://logic.local/o1","http://logic.local/o2"], b
'

    # 同一标签的两次出现是同一个变量，每个主语各 1 解，共 2 行；若被当作两个新变量则为 4 行
    run_case "同一标签重复出现是同一变量，应为 2 行" \
        'SELECT * WHERE { _:b <http://logic.local/p> ?o1 . _:b <http://logic.local/p> ?o2 . }' '
import sys,json
d=json.load(sys.stdin)
assert d.get("StatusCode")==0, d.get("StatusMsg")
b=d.get("results",{}).get("bindings",[])
assert len(b)==2, "expected 2 rows, got %d" % len(b)
'
}

# ===================== 主流程 =====================
main() {
    divider
    echo -e "${PURPLE}          🚀 gStore Issue #163 匿名空白节点查询模式测试${NC}"
    divider

    reset_db
    prepare_db 2

    test_anonymous_subject
    test_anonymous_object
    test_multiple_anonymous
    test_blank_node_label

    reset_db
    DB_NAME="iss163b"
    RDF_FILE="${TEST_DATA_DIR}/data_shared.nt"
    prepare_db 3

    test_multiple_anonymous_shared_object

    divider
    echo -e "${GREEN}✅ 通过：${PASS_NUM}${NC}"
    if [ ${FAIL_NUM} -gt 0 ]; then
        echo -e "${RED}❌ 失败：${FAIL_NUM}${NC}"
    fi
    divider

    reset_db

    return ${FAIL_NUM}
}

main "$@"
