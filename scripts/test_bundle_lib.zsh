#!/bin/zsh
# XCTest bundle 定位。两个验证脚本共用。
#
# **为什么需要这层间接**：Xcode 27 起 SwiftPM 默认换成 swiftbuild 后端，产物布局变了——
#   旧（native 后端）：.build/<triple>/debug/kongshanPackageTests.xctest  ← 单一合并包
#   新（swiftbuild）： .build/out/Products/Debug/<Target>.xctest          ← 每个测试 target 一个
# 脚本原先硬编码旧路径与"必须恰好一个包"，2026-09-18 装上 Xcode 27 后发布门禁直接报
# "预期唯一 XCTest bundle，实际找到 0 个"。把两种布局都认下来，换工具链不再整个失效。

# 列出全部测试 bundle（每行一个）。
kongshan_all_test_bundles() {
    local project_dir=$1
    typeset -a bundles
    bundles=("$project_dir"/.build/*/debug/kongshanPackageTests.xctest(N))
    if (( ${#bundles[@]} == 0 )); then
        bundles=("$project_dir"/.build/out/Products/Debug/*.xctest(N))
    fi
    print -l -- $bundles
}

# 给定测试 ID（如 `KongshanCoreTests.FooTests/testBar`），返回承载它的 bundle。
# 合并布局下永远是那唯一一个；拆分布局下按 ID 的第一段（测试 target 名）取。
kongshan_bundle_for_test() {
    local project_dir=$1 test_id=$2
    typeset -a merged
    merged=("$project_dir"/.build/*/debug/kongshanPackageTests.xctest(N))
    if (( ${#merged[@]} == 1 )); then
        print -r -- "$merged[1]"
        return 0
    fi
    local target=${test_id%%.*}
    typeset -a split
    split=("$project_dir"/.build/out/Products/Debug/${target}.xctest(N))
    (( ${#split[@]} == 1 )) || return 1
    print -r -- "$split[1]"
}
