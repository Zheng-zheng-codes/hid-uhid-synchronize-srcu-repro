# Run records

All runs were started from the KernSight container on the host, with QEMU 6.2.0
and the 7.3.0 kernel image
`/workspace/validation/linux-7.3-validate/bzImage` (release
`7.3.0-kernsight-kasan #1`). The guest command line is
`cmdline/cmdline-7.3.0.txt`. Each run boots a new guest from a fresh qcow2
overlay of `/workspace/vm/trixie-validation.img` (see `qemu started` in the
console logs).

## About `repro.prog`

`repro/repro.prog` retains the original syzkaller reproducer options in its
first line, e.g.:

```
# {Threaded:true Repeat:true RepeatTimes:0 Procs:6 Slowdown:1 Sandbox:none ...}
```

That line is the historical setting saved with the reproducer. The manual
replays reported here used the commands below (`-procs=1 -repeat=1
-disable=swap`, sandbox none, threaded executor, no additional syzkaller
features).

## 7.3.0 — execution sequence (reproduced)

Host command:

```sh
docker exec kernsight bash /workspace/scripts/replay-kernsight-prog.sh 7.3 \
  /workspace/kernsight_workspace/runs/syzkaller/crashes/a0c67458bdd7263122192a958462a6c64b25f727/repro.kernsight.prog \
  11523 /workspace/validation/ksval-out/replay-7.3-all/a0c67458bdd7263122192a958462a6c64b25f727 \
  all-a0c67458bdd7263122192a958462a6c64b25f727
```

with `REPLAY_SECONDS=480 POST_EXIT_WAIT=180
REPLAY_IMAGE=/workspace/vm/trixie-validation.img`. The script copies
`syz-execprog`, `syz-executor` and the program into the guest and runs:

```sh
./syz-execprog -procs=1 -repeat=1 -disable=swap \
  -executor ./syz-executor ./repro.kernsight.prog
```

Observed console (`logs/console-7.3-sequence.log`): `ssh up after 75s`,
`started`, then `ssh lost (likely panic) at 303s`; the serial log
(`logs/serial-7.3.log`) contains the GPF at t=276.234483 s. Because the guest
panicked, `syz-execprog`'s stdout was not recovered for this run.

## 7.3.0 — standalone programs (no trigger)

Two runs of the standalone two-call program on fresh guests:

```sh
PROG=/workspace/kernsight_workspace/runs/syzkaller/crashes/a0c67458bdd7263122192a958462a6c64b25f727/repro.prog
docker exec kernsight bash /workspace/scripts/replay-kernsight-prog.sh 7.3 \
  "$PROG" 12202 /workspace/validation/ksval-out/replay-7.3-srcu-minimal srcu73min
docker exec kernsight bash /workspace/scripts/replay-kernsight-prog.sh 7.3 \
  "$PROG" 12204 /workspace/validation/ksval-out/replay-7.3-srcu-minimal3 srcu73min3
```

with `REPLAY_SECONDS=420 POST_EXIT_WAIT=120
REPLAY_IMAGE=/workspace/vm/trixie-validation.img` and the same guest command.

Observed:
- run 1: `execprog finished without panic at 215s`; syz-execprog output
  `parsed 1 programs` / `EXIT:0` (`logs/execprog-7.3-minimal1.txt`); serial has
  no GPF (`logs/serial-7.3-minimal1.log`).
- run 2: `execprog finished` and `parsed 1 programs` / `EXIT:0`
  (`logs/execprog-7.3-minimal2.txt`); serial has no GPF
  (`logs/serial-7.3-minimal2.log`).

So both standalone runs completed the program execution (EXIT:0) without
triggering the GPF.
