#!/bin/bash
# replay-kernsight-prog.sh — 在指定内核（如 7.3）的 VM 内按顺序重放 repro.kernsight.prog。
# 在 KernSight 容器内执行；调用方传入内核标签、prog、端口、输出目录和 tag。
#
# 用法: replay-kernsight-prog.sh <kernel> <prog> <port> <out-dir> <tag>
#   kernel: 7.3 (also used: 7.1.3, 7.2.11; validation/linux-<kernel>-validate)
set -u
KV="$1"; PROG="$2"; PORT="$3"; OUT="$4"; TAG="$5"
KERNEL="/workspace/validation/linux-$KV-validate/bzImage"
IMAGE="${REPLAY_IMAGE:-/workspace/vm/trixie-validation.img}"
KEY="/workspace/vm/trixie.id_rsa"
EXECPROG="/workspace/syzkaller/bin/linux_amd64/syz-execprog"
EXECUTOR="/workspace/syzkaller/bin/linux_amd64/syz-executor"
CMD="root=/dev/sda console=ttyS0 $(python3 -c "import json;print(json.load(open('/workspace/configs/syzkaller.validate-$KV.cfg'))['vm']['cmdline'])")"

mkdir -p "$OUT"
OVL="/tmp/ksreplay-$TAG.qcow2"
SER="/tmp/ksreplay-$TAG.serial"
qemu-img create -q -f qcow2 -F raw -b "$IMAGE" "$OVL" >/dev/null
rm -f "$SER"
qemu-system-x86_64 -m 6144 -smp 4 -enable-kvm -cpu host \
  -drive file="$OVL",if=ide,format=qcow2 -kernel "$KERNEL" -append "$CMD" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device e1000,netdev=net0 \
  -display none -vga none -serial file:"$SER" -no-reboot -daemonize
echo "qemu started port=$PORT serial=$SER"
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p $PORT root@127.0.0.1"
for i in $(seq 1 40); do
  sleep 5
  if $SSH true 2>/dev/null; then echo "ssh up after $((i*5))s"; break; fi
done
$SSH "uname -r; cat /proc/version" 2>&1 | tee "$OUT/boot-info.txt"
$SSH "cat /proc/cmdline" >"$OUT/cmdline.txt" 2>&1
# Linux >=7.3 把 kcov 从 /dev/kcov(misc) 移到了 debugfs；老镜像没有 /dev/kcov 节点时补一个兼容链接。
$SSH "test -e /dev/kcov || { mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null; test -e /sys/kernel/debug/kcov && ln -sfn /sys/kernel/debug/kcov /dev/kcov; }" 2>/dev/null || true
timeout 300 scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$PORT" \
  "$EXECPROG" "$EXECUTOR" "$PROG" root@127.0.0.1:/tmp/ 2>&1 | tail -2
timeout 60 $SSH "chmod +x /tmp/syz-execprog /tmp/syz-executor; mkdir -p /tmp/replay; cp /tmp/$(basename "$PROG") /tmp/replay/repro.kernsight.prog; cd /tmp/replay && nohup sh -c '/tmp/syz-execprog -procs=1 -repeat=1 -disable=swap -executor /tmp/syz-executor /tmp/replay/repro.kernsight.prog >/tmp/repro.out 2>&1; echo EXIT:\$? >>/tmp/repro.out' >/dev/null 2>&1 & echo started" 2>&1
END=$((SECONDS + ${REPLAY_SECONDS:-300}))
while [ $SECONDS -lt $END ]; do
  sleep 10
  if ! $SSH true 2>/dev/null; then echo "ssh lost (likely panic) at ${SECONDS}s"; break; fi
  if $SSH "grep -q '^EXIT:' /tmp/repro.out" 2>/dev/null; then
    echo "execprog finished without panic at ${SECONDS}s"
    break
  fi
done
timeout 90 $SSH "dmesg" >"$OUT/dmesg.txt" 2>/dev/null || true
timeout 120 scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$PORT" \
  root@127.0.0.1:/tmp/repro.out "$OUT/execprog-out.txt" >/dev/null 2>&1 || true
# hang 类 bug 的 hung_task 报告在程序结束后 ~143s 才打印；给一个宽限窗口。
if [ "${POST_EXIT_WAIT:-0}" != 0 ]; then sleep "${POST_EXIT_WAIT}"; timeout 90 $SSH "dmesg" >"$OUT/dmesg.txt" 2>/dev/null || true; fi
cp "$SER" "$OUT/serial.log" 2>/dev/null || true
echo "---- 崩溃摘要(串口) ----"
grep -aE 'kernel BUG at|WARNING:|KASAN:|BUG: |general protection|blocked for more than|Kernel panic|INFO: task' "$SER" 2>/dev/null | head -12
echo "---- 完整串口: $OUT/serial.log (容器内) ----"
pkill -9 -f "ksreplay-$TAG.qcow2" 2>/dev/null || true
rm -f "$OVL"
