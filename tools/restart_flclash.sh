#!/system/bin/sh
echo "== FlClash running? =="
ps -A | grep -i clash | head -3
echo "== restart FlClash app =="
monkey -p com.follow.clash.dev -c android.intent.category.LAUNCHER 1 2>&1 | tail -1
sleep 5
echo "== services =="
dumpsys activity services com.follow.clash.dev 2>/dev/null | grep -E "ServiceRecord" | head -5
echo "== try start VPN service explicitly =="
dumpsys package com.follow.clash.dev 2>/dev/null | grep -E "Service" | head -8
