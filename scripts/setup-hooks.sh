#!/bin/sh
# 讓 git 改用 repo 內的 hooks（scripts/hooks），這樣版本蓋章 hook 會隨 repo 走，
# 換電腦或重新 clone 只要跑這一行就好：  sh scripts/setup-hooks.sh
set -e
cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/hooks/*
git config core.hooksPath scripts/hooks
echo "✅ core.hooksPath = scripts/hooks（版本蓋章已啟用）"
