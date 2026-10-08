#!/bin/bash
set -eo pipefail

# ===================== 【全局配置】 =====================
# issue #165：FILTER 中的单引号字符串字面量与数据中的双引号字面量不相等
CONF_FILE="./conf/conf.ini"
USERNAME="root"
PASSWORD="123456"
DB_NAME="issue165"
DATA_FILE="scripts/test/issue_165_data/data.nt"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ===================== conf配置端口 =====================
PORT=$(grep -m1 'port=' "${CONF_FILE}" 2>/dev/null)
PORT_STR="${PORT#*=}"
BASE_URL="http://127.0.0.1:${PORT_STR}/api"

# ===================== 用例计数 =====================
PASS_NUM=0
FAIL_NUM=0

divider() {
	echo -e "${BLUE}=========================================================================${NC}"
}

# ===================== 工具函数 =====================
# 将查询语句转义为 JSON 字符串字面量（含两侧引号）
escape_json() {
	python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
}

call_api() {
	local data="$1"
	curl -s --noproxy '*' -X POST -H 'Content-Type: application/json' \
		-d "$data" "${BASE_URL}" 2>/dev/null || echo '{"StatusCode":-1,"StatusMsg":"curl request failed"}'
}

check_service() {
	call_api '{"operation":"check"}' | grep -q '"StatusCode":0'
}

# 执行 SPARQL 查询，输出结果行数；查询失败（返回码非 0 或响应异常）时输出 ERR
query_rows() {
	local sparql="$1" resp
	resp=$(call_api "{\"operation\":\"query\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\",\"format\":\"json\",\"sparql\":$(printf '%s' "$sparql" | escape_json)}")
	echo "$resp" | python3 -c '
import json, sys
try:
	resp = json.load(sys.stdin)
except Exception:
	print("ERR")
	sys.exit(0)
if resp.get("StatusCode") != 0:
	print("ERR")
	sys.exit(0)
print(len(resp.get("results", {}).get("bindings", [])))
'
}

# 生成 FILTER 查询，$1 为 FILTER 中比较的那个字面量
filter_query() {
	echo "SELECT ?s WHERE { ?s <http://logic.local/label> ?label . FILTER (?label = $1) }"
}

# 生成三元组模式查询，$1 为对象位置的那个字面量
object_query() {
	echo "SELECT ?s WHERE { ?s <http://logic.local/label> $1 }"
}

# 断言：查询结果行数等于期望值
check_rows() {
	local desc="$1" sparql="$2" expect="$3" actual
	actual=$(query_rows "$sparql")
	if [ "${actual}" = "${expect}" ]; then
		echo -e "  ${GREEN}[PASS]${NC} ${desc}（期望 ${expect} 行，实际 ${actual} 行）"
		PASS_NUM=$((PASS_NUM + 1))
	else
		echo -e "  ${RED}[FAIL]${NC} ${desc}（期望 ${expect} 行，实际 ${actual} 行）"
		echo -e "         SPARQL: ${sparql}"
		FAIL_NUM=$((FAIL_NUM + 1))
	fi
}

# 断言：单引号字面量与对应的双引号字面量行为一致
check_same_as_double_quoted() {
	local desc="$1" single_quoted="$2" double_quoted="$3" rows_single rows_double
	rows_single=$(query_rows "$single_quoted")
	rows_double=$(query_rows "$double_quoted")
	if [ "${rows_single}" != "ERR" ] && [ "${rows_single}" = "${rows_double}" ]; then
		echo -e "  ${GREEN}[PASS]${NC} ${desc}（单引号 ${rows_single} 行，双引号 ${rows_double} 行）"
		PASS_NUM=$((PASS_NUM + 1))
	else
		echo -e "  ${RED}[FAIL]${NC} ${desc}（单引号 ${rows_single} 行，双引号 ${rows_double} 行）"
		echo -e "         SPARQL: ${single_quoted}"
		FAIL_NUM=$((FAIL_NUM + 1))
	fi
}

# ===================== 主流程 =====================
divider
echo -e "${PURPLE}issue #165 测试：FILTER 中单引号字符串字面量 = 双引号字符串字面量${NC}"
divider

if ! check_service; then
	echo -e "${RED}gStore 服务未启动，请先执行 bin/gserver -b${NC}"
	exit 1
fi

# 清理同名库，保证脚本可重复执行
call_api "{\"operation\":\"drop\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\",\"is_backup\":\"false\"}" > /dev/null || true

echo -e "${YELLOW}构建测试库 ${DB_NAME}${NC}"
build_resp=$(call_api "{\"operation\":\"build\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\",\"db_path\":\"${DATA_FILE}\"}")
echo "${build_resp}"
if ! echo "${build_resp}" | grep -q '"StatusCode":0'; then
	echo -e "${RED}构建测试库失败，测试终止${NC}"
	exit 1
fi

echo -e "${YELLOW}加载测试库 ${DB_NAME}${NC}"
load_resp=$(call_api "{\"operation\":\"load\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"db_name\":\"${DB_NAME}\"}")
echo "${load_resp}"
if ! echo "${load_resp}" | grep -q '"StatusCode":0' && ! echo "${load_resp}" | grep -q 'already loaded'; then
	echo -e "${RED}加载测试库失败，测试终止${NC}"
	exit 1
fi

divider
echo -e "${PURPLE}执行测试用例${NC}"
divider

# 1. issue 复现用例：FILTER 中的单引号字面量应匹配数据中的 "plain"
check_rows "FILTER (?label = 'plain') 匹配数据中的 \"plain\"" "$(filter_query "'plain'")" 1

# 2. 对照用例：FILTER 中的双引号字面量
check_rows "FILTER (?label = \"plain\") 匹配数据中的 \"plain\"" "$(filter_query '"plain"')" 1

# 3. 单引号与双引号字面量完全等价
check_same_as_double_quoted "单引号与双引号 FILTER 结果一致" \
	"$(filter_query "'plain'")" "$(filter_query '"plain"')"

# 4. 负例：数据中不存在的值
check_rows "FILTER (?label = 'other') 不匹配数据" "$(filter_query "'other'")" 0

# 5. 三元组模式对象位置的单引号字面量
check_rows "三元组模式对象 'plain' 匹配数据" "$(object_query "'plain'")" 1

# 6. 含转义字符的字面量：单引号形式与双引号形式行为一致
check_same_as_double_quoted "字面量 'a\\'b' 与 \"a\\'b\" 行为一致" \
	"$(filter_query "'a\\'b'")" "$(filter_query "\"a\\'b\"")"

# 7. 字面量中的冒号不应被当作前缀
check_rows "字面量 'a:b' 中的冒号不被解析为前缀" "$(filter_query "'a:b'")" 0

divider
echo -e "测试用例：${GREEN}PASS ${PASS_NUM}${NC} / ${RED}FAIL ${FAIL_NUM}${NC}"
divider

if [ "${FAIL_NUM}" -ne 0 ]; then
	echo -e "${RED}issue #165 测试未通过${NC}"
	exit 1
fi
echo -e "${GREEN}issue #165 测试全部通过${NC}"
