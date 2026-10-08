# Issue 回归测试（#152–#171）

这 13 份端到端测试是 issue #152–#171 修复过程的验证资产，保存在本分支，
**不随任何 PR 提交**（上游 pkumod/gStore 的修复 PR 惯例为只带源码改动，
且 scripts/test/ 在 .gitignore 中）。

每个脚本自成一体，从 conf/conf.ini 读取 gserver 端口。复跑方式：

    # 在对应修复分支的 worktree 中
    cp -r <本分支>/scripts/test/issue_<N>_data scripts/test/
    cp <本分支>/scripts/test/issue_<N>_test.sh scripts/test/
    ./bin/gserver -b
    bash scripts/test/issue_<N>_test.sh

原始运行证据保存在 /tmp/issue_<N>_before.txt 与 /tmp/issue_<N>_after.txt
（#166 的中间失败记录为 issue_166_after_agent_run.txt）。
