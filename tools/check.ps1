# 拾忆发布门禁：发布前/提交前一键验证。
# 对齐 docs/fix-log.md 的「验证」环节：analyze 无告警 + 测试全过 + 快照一致性。
#
# 用法：
#   pwsh tools/check.ps1              # 常规检查
#   pwsh tools/check.ps1 -FixSnapshots # 快照有改动时，以当前输出为准（请人工 review diff 后提交）
#
# 退出码：0 = 全部通过；非 0 = 有失败。

param(
    [switch]$FixSnapshots
)
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '== 1/3 flutter analyze ==' -ForegroundColor Cyan
flutter analyze
if ($LASTEXITCODE -ne 0) {
    Write-Host 'analyze 失败' -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host 'analyze 无告警 ✅' -ForegroundColor Green

Write-Host ''
Write-Host '== 2/3 flutter test ==' -ForegroundColor Cyan
flutter test
if ($LASTEXITCODE -ne 0) {
    Write-Host '测试失败' -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host '测试全部通过 ✅' -ForegroundColor Green

Write-Host ''
Write-Host '== 3/3 快照一致性 ==' -ForegroundColor Cyan
$dirty = git status --porcelain -- test/snapshots/
if ($dirty) {
    if ($FixSnapshots) {
        Write-Host '警告：test/snapshots/ 有改动（已用 -FixSnapshots 接受当前输出）——' -ForegroundColor Yellow
        Write-Host $dirty
        Write-Host '请人工 review 上述 diff 确认是预期变更后再提交。' -ForegroundColor Yellow
    } else {
        Write-Host '快照有未提交改动——门禁拦截：' -ForegroundColor Red
        Write-Host $dirty
        Write-Host '提示词/工具定义已变化：请先 review diff，确认是预期变更后提交快照；' -ForegroundColor Yellow
        Write-Host '如需以当前输出为准，显式运行：pwsh tools/check.ps1 -FixSnapshots' -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host '快照无改动 ✅' -ForegroundColor Green
}

Write-Host ''
Write-Host '全部检查完成 ✅' -ForegroundColor Green
