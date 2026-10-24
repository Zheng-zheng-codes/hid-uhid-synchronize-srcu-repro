# HID/uhid: general protection fault in `synchronize_srcu()` on device-creation failure

Reproducers and logs for:

```
Oops: general protection fault, probably for non-canonical address ...
KASAN: null-ptr-deref in range [0x178-0x17f]
RIP: synchronize_srcu+0x53/0x3b0 kernel/rcu/srcutree.c:1576
Call Trace:
 hid_bpf_destroy_device drivers/hid/bpf/hid_bpf_dispatch.c:632
 hid_destroy_device     drivers/hid/hid-core.c:3085
 hid_allocate_device    drivers/hid/hid-core.c:3056   (out_err path)
 uhid_dev_create2       drivers/hid/uhid.c:511
```

## Root cause (as observed)

`hid_allocate_device()` calls `hid_bpf_device_init()` (which runs
`init_srcu_struct(&hdev->bpf.srcu)`). If that call fails, the `out_err` path
calls `hid_destroy_device()` → `hid_bpf_destroy_device()`, which unconditionally
runs `synchronize_srcu(&hdev->bpf.srcu)` and `cleanup_srcu_struct()`. SRCU
initialization failed, but the error path still invokes `synchronize_srcu()` on
the unsuccessfully initialized SRCU structure; `check_init_srcu_struct()` then
dereferences it and the kernel takes a GPF/null-ptr-deref.

The reproducer makes `hid_bpf_device_init()` fail with a fault-injection
allocation failure (`failslab`, `fail_nth: 5` on the `UHID_CREATE` write).

## Related patch

This exact error path is addressed by:

- `[PATCH] HID: core: fix device cleanup on allocation failure` — Tristan
  Madani, 2026-09-04, <https://lkml.iu.edu/2609.0/09658.html>. The patch
  replaces `hid_destroy_device()` with `put_device()` in the
  `hid_allocate_device()` error path (also carries `Fixes: 6cd735f0e57a` and
  `Cc: stable`).

The tested kernels **do not include** the fix: `hid_allocate_device()` still
calls `hid_destroy_device()` on the `hid_bpf_device_init()` failure path.

## Tested kernels

| Kernel | Release | Notes |
|---|---|---|
| 7.1.3 | `7.1.3-kernsight-kasan #13` | KASAN/KCOV, `CONFIG_FAULT_INJECTION=y`, failslab enabled |
| 7.3.0 | `7.3.0-kernsight-kasan #1` | vanilla 7.3.0 (tarball sha256 `87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953`) + KASAN/KCOV |

No HID source changes were made for this testing (for 7.3.0,
`drivers/hid/` matches vanilla apart from build artifacts).

## Observed results

- **7.1.3**: the syzkaller reproducer (`repro/repro.prog`) reproduces. No C
  reproducer was produced for this report.
- **7.3.0**:
  - Replaying the stored 68-program execution sequence
    (`repro/repro.kernsight.prog`) reproduces the GPF (`logs/serial-7.3.log`,
    first report at t=276.2 s). The UHID trigger is program #64 and appears
    again inside the final program #67.
  - The standalone two-call program did **not** reproduce in two runs on fresh
    guests (`logs/serial-7.3-minimal1.log`, `logs/serial-7.3-minimal2.log`).
    Earlier operations may affect whether the fault-injection point is reached,
    but this has not been isolated.

## Reproduction

All runs used a fresh KVM guest, a threaded executor, `sandbox=none`,
`procs=1`, `repeat=1`, no extra syzkaller features, 4 vCPU / 6 GiB, QEMU 6.2.0.
The host/guest commands and console outputs of the three runs are recorded in
`RUNS.md`. Note that `repro.prog` keeps the original syzkaller repro options in
its first line (`Threaded:true Repeat:true Procs:6 ...`); that is the saved
reproducer setting, while the manual replays used `-procs=1 -repeat=1`.
syzkaller revision `853b104bb454141a5b0fc0e4218ec78e9f34ffb1+` (local KernSight
integration changes only; syscall descriptions and fault-injection semantics
are unchanged).

### 7.1.3 — minimal program

```sh
scp syz-execprog syz-executor repro/repro.prog root@guest:/tmp/
ssh root@guest
cd /tmp && chmod +x syz-execprog syz-executor
./syz-execprog -procs=1 -repeat=1 -disable=swap -executor ./syz-executor ./repro.prog
```

Program (2 calls, `fail_nth: 5` on the UHID write):

```
r0 = openat$uhid(0xffffffffffffff9c, &(0x7f0000000000), 0x2, 0x0)
write$UHID_CREATE(r0, &(0x7f0000000140)={0x0, {'syz1\x00', 'syz0\x00', 'syz0\x00', &(0x7f0000001300)=""/191, 0xbf, 0x24, 0x2, 0x160e, 0x3, 0xffff8000}}, 0x120) (fail_nth: 5)
```

### 7.3.0 — execution sequence

```sh
scp syz-execprog syz-executor repro/repro.kernsight.prog root@guest:/tmp/
ssh root@guest
cd /tmp && chmod +x syz-execprog syz-executor
./syz-execprog -procs=1 -repeat=1 -disable=swap -executor ./syz-executor ./repro.kernsight.prog
```

## Fault injection

The `write$UHID_CREATE()` call is annotated with `fail_nth: 5`. During the
execution the kernel logged:

```
FAULT_INJECTION: forcing a failure.
name failslab, interval 1, probability 0, space 0, times 0
```

followed by the GPF report.

## Manual verification

| Check | Command | Expected |
|---|---|---|
| programs in the sequence | `grep -c '^executing program' repro/repro.kernsight.prog` | 68 |
| UHID trigger programs | `./verify.sh` | #64 and #67 |
| GPF reports, 7.3 sequence | `grep -a -c 'general protection fault' logs/serial-7.3.log` | 1 |
| first GPF timestamp, 7.3 | `grep -a -m1 'Oops: general protection fault' logs/serial-7.3.log` | `[ 276.2...]` |
| GPF in standalone 7.3 runs | same grep on `logs/serial-7.3-minimal*.log` | 0 / 0 |
| GPF in the 7.1.3 report | `grep -a -c 'general protection fault' logs/report-7.1.3.txt` | 1 |
| `failslab` injection logged | `grep -a 'name failslab' logs/serial-7.3.log` | present |

`./verify.sh` runs these checks and prints `OK`/`FAIL`.

## Files

```
repro/repro.prog              syz program with fail_nth: 5 (7.1.3 minimal)
repro/repro.kernsight.prog    68-program execution sequence (7.3.0)
logs/report-7.1.3.txt         original 7.1.3 report
logs/repro-report-7.1.3.log   7.1.3 reproduction report
logs/gpf-7.3.txt              7.3.0 GPF report (timestamps stripped)
logs/serial-7.3.log           full 7.3.0 console (sequence replay)
logs/serial-7.3-minimal1.log  standalone 7.3.0 run 1 (no trigger)
logs/serial-7.3-minimal2.log  standalone 7.3.0 run 2 (no trigger)
kernel/                       kernel configs
cmdline/                      kernel command lines
RUNS.md                       exact host/guest commands and console outputs
scripts/replay-kernsight-prog.sh   the exact run script used
verify.sh                     checks the numbers quoted above
MANIFEST.sha256               sha256 of every file
```
