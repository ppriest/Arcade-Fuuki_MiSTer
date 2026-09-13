#!/usr/bin/env python3
"""Build Quartus from a staged snapshot of HEAD, leaving the tree free.

Ported from the Psikyo core (E:\\Arcade-Psikyo_MiSTer), where it exists for
the reason this core kept paying for without it: a Quartus compile takes
about thirteen minutes, and for all of it the tree has to be left alone.
Editing sources during a run risks the build, and NOT editing them means
every unrelated task waits. Both happened here repeatedly on 2026-09-06.

The compile runs in a dedicated git worktree at <repo>/build (gitignored),
so the main tree is free the moment the build starts, and every scrap of
Quartus scratch -- db/, incremental_db/, output_files/, the log -- lands
under build/ instead of the repo root.

The build is exactly HEAD:
  * a dirty tree is refused by default, so what is in the editor and what is
    compiled cannot silently diverge. --allow-dirty builds HEAD anyway,
    explicitly acknowledging the uncommitted edits are EXCLUDED.
  * the built commit is written to build/BUILT_COMMIT beside the log, so
    every .rbf maps to one commit.

    python scripts/build_staged.py                 # compile HEAD, revision Fuuki_stp
    python scripts/build_staged.py --rev Fuuki     # the release revision
    python scripts/build_staged.py --seed 12345    # try another placement
    python scripts/build_staged.py --allow-dirty   # HEAD, ignoring edits

Two Quartus revisions build from the same source (Fuuki.sv, "DEBUG BUILD OR
RELEASE"): Fuuki_stp carries the JTAG probe, the Debug OSD page and the sound
mute switches; Fuuki is the release, with the probe compiled out and those
settings hidden and forced off. They are held to different standards: a
release must close timing on every clock, because it runs on machines we
cannot see; a debug build may miss it, stated, because it runs on ours.
docs/RELEASE_PROCESS.md.

Outputs, all inside the stage:
    build/q_staged.log                 the build log (deploy.py's gate reads it)
    build/output_files/<rev>.rbf       the bitstream
    build/output_files/<rev>.sta.summary
    build/BUILT_COMMIT

Deploy it by pointing deploy.py at the stage (the script prints the exact
command for the revision it built):
    python scripts/deploy.py --rbf-only --log build/q_staged.log \\
        --rbf build/output_files/<rev>.rbf --sta build/output_files/<rev>.sta.summary

The worktree persists between builds -- Quartus's db/ with it, which costs
nothing for full compiles and avoids re-checkout churn -- and each run
hard-resets it to HEAD. A .build_running marker refuses two overlapping
staged builds.

scripts/build.sh still exists and still builds in-tree; use it when you want
the compile to see uncommitted work and are willing to leave the tree alone.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

QUARTUS_BIN = os.environ.get(
    "QUARTUS_BIN", r"C:\intelFPGA_lite\17.0\quartus\bin64")
REVISIONS = ("Fuuki_stp", "Fuuki")   # Fuuki.qpf; the first is the default
REV = REVISIONS[0]                    # set from --rev in main()


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit("FAILED: %s\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout.strip()


def read_slacks(summary):
    """Print every clock's setup slack; return the ones that fail.

    All of them, not clk_sys alone: a violation on any clock is a violation,
    and scripts/build.sh gates on exactly the same rule.
    """
    out = []
    if not os.path.exists(summary):
        print("no timing summary at %s -- treating as unverified" % summary)
        return out
    lines = open(summary, errors="replace").read().splitlines()
    for i, ln in enumerate(lines):
        if not ln.startswith("Type  : Setup ") or i + 2 >= len(lines):
            continue
        clk = ln.split("Setup ", 1)[1].strip().strip("'")
        try:
            slack = float(lines[i + 1].split(":", 1)[1])
        except (IndexError, ValueError):
            continue
        tns = lines[i + 2].split(":", 1)[1].strip()
        if "emu|pll" in clk:
            print("worst clk_sys setup: Slack : %.3f / TNS   : %s" % (slack, tns))
        if slack < 0:
            out.append((clk[-58:], slack, tns))
    return out


def report_resources(stage):
    fit = os.path.join(stage, "output_files", "%s.fit.summary" % REV)
    if not os.path.exists(fit):
        return
    keep = ("Logic utilization", "Total registers", "Total block memory bits",
            "Total RAM Blocks", "Total DSP Blocks", "Total pins", "Total PLLs")
    for ln in open(fit, errors="replace"):
        if any(ln.strip().startswith(k) for k in keep):
            print("  " + ln.strip())


def main():
    global REV
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", default=REVISIONS[0], choices=REVISIONS,
                    help="Quartus revision: Fuuki_stp (default) is the "
                         "instrumented build, Fuuki the release")
    ap.add_argument("--seed", type=int,
                    help="override the fitter SEED in the STAGED .qsf "
                         "(placement only; worth trying before restructuring "
                         "RTL for a sub-ns violation)")
    ap.add_argument("--allow-negative-slack", action="store_true",
                    help="do not fail on a build that misses timing; the "
                         "shortfall must then be stated wherever it is used")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="build HEAD even though the tree has uncommitted "
                         "changes (they are NOT included in the build)")
    args = ap.parse_args()
    REV = args.rev

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    stage = os.path.join(here, "build")

    # The other half of the guard in scripts/hwlock.py: a compile must not
    # start while a JTAG tool is reading the device.
    sys.path.insert(0, os.path.join(here, "scripts"))
    from hwlock import require_no_jtag
    require_no_jtag("this build")

    dirty = run(["git", "-C", here, "status", "--porcelain"])
    # Untracked files are not part of HEAD either, but they are usually
    # scratch; only tracked modifications are treated as a divergence worth
    # refusing over.
    tracked_dirty = "\n".join(ln for ln in dirty.splitlines()
                              if not ln.startswith("??"))
    if tracked_dirty and not args.allow_dirty:
        sys.exit("tree is dirty -- commit first (the build is exactly HEAD), "
                 "or pass --allow-dirty to build HEAD without these:\n"
                 + tracked_dirty)

    head = run(["git", "-C", here, "rev-parse", "HEAD"])
    head_short = run(["git", "-C", here, "rev-parse", "--short", "HEAD"])

    marker = os.path.join(stage, ".build_running")
    if os.path.exists(marker):
        sys.exit("a staged build already appears to be running (%s exists) -- "
                 "wait for it, or delete the marker if it is stale" % marker)

    # Create or update the stage worktree to exactly HEAD.
    if not os.path.isdir(os.path.join(stage, ".git")) and \
       not os.path.isfile(os.path.join(stage, ".git")):
        run(["git", "-C", here, "worktree", "add", "--detach", stage, head])
    else:
        # --force: a seed override patches the STAGED .qsf, and a leftover
        # patch must never wedge the next build. The stage is a disposable
        # copy of HEAD; local changes in it are always discardable.
        run(["git", "-C", stage, "checkout", "--force", "--detach", head])
        run(["git", "-C", stage, "reset", "--hard", head])

    # Fitter seed override, patched into the STAGE only, so a build stays
    # reproducible from its commit plus this flag.
    if args.seed is not None:
        qsf = os.path.join(stage, "%s.qsf" % REV)
        if not os.path.isfile(qsf):
            sys.exit("no %s to patch a SEED into" % qsf)
        text = open(qsf, encoding="utf-8", errors="replace").read()
        new, n = re.subn(r"(?m)^set_global_assignment -name SEED .*$",
                         "set_global_assignment -name SEED %d" % args.seed, text)
        if n == 0:
            new = text.rstrip("\n") + \
                "\nset_global_assignment -name SEED %d\n" % args.seed
        elif n > 1:
            sys.exit("expected at most one SEED assignment in %s, found %d" % (qsf, n))
        open(qsf, "w", encoding="utf-8", newline="\n").write(new)
        print("seed:   %d (stage only)" % args.seed)

    stamp = "%s  %s\n" % (head, datetime.datetime.now().isoformat())
    open(os.path.join(stage, "BUILT_COMMIT"), "w").write(stamp)
    print("stage:  %s" % stage)
    print("rev:    %s (%s)" % (REV, "release" if REV == "Fuuki" else "instrumented"))
    print("commit: %s (%s)" % (head_short, head))
    if dirty and args.allow_dirty:
        print("NOTE:   the tree has uncommitted changes and they are NOT in "
              "this build")

    quartus = os.path.join(QUARTUS_BIN, "quartus_sh.exe")
    log_path = os.path.join(stage, "q_staged.log")
    open(marker, "w").write(stamp)
    try:
        with open(log_path, "w") as log:
            subprocess.run([quartus, "--flow", "compile", REV, "-c", REV],
                           cwd=stage, stdout=log, stderr=subprocess.STDOUT)
    finally:
        os.remove(marker)

    tail = open(log_path, errors="replace").read().splitlines()[-25:]
    ok = any("Full Compilation was successful" in ln for ln in tail)
    for ln in tail:
        if any(k in ln for k in ("successful", "Error", "Elapsed")):
            print(ln.strip())

    print("")
    print("==== resource usage ====")
    report_resources(stage)
    print("")
    print("==== timing ====")
    violations = read_slacks(
        os.path.join(stage, "output_files", "%s.sta.summary" % REV))

    if not ok:
        sys.exit("BUILD FAILED -- see %s" % log_path)

    # A debug build may ship with negative slack: it runs on our own DE10-nano,
    # and the probe and tracer cost timing a release does not pay. A release
    # may not -- once it leaves here we cannot know what it runs on, and a
    # marginal path is exactly the fault that surfaces as someone else's
    # intermittent glitch. docs/RELEASE_PROCESS.md.
    is_release = (REV == "Fuuki")
    if violations and is_release and not args.allow_negative_slack:
        print("")
        for clk, slack, tns in violations:
            print("  FAILING: %-58s %8.3f  TNS %s" % (clk, slack, tns))
        sys.exit(
            "\nNOT RELEASE QUALIFIED -- %d clock(s) fail timing. The .rbf at\n"
            "  %s\nmust not be published. Close timing, try --seed, rebuild as\n"
            "the debug revision (no --rev), or pass --allow-negative-slack if\n"
            "you are deliberately publishing a known-marginal build and will\n"
            "say so in the release notes."
            % (len(violations),
               os.path.join(stage, "output_files", "%s.rbf" % REV)))
    if violations and is_release:
        print("")
        print("WARNING: --allow-negative-slack given; publishing a build that")
        print("         fails timing on %d clock(s). Say so in the release notes."
              % len(violations))
    elif violations:
        print("")
        for clk, slack, tns in violations:
            print("  FAILING: %-58s %8.3f  TNS %s" % (clk, slack, tns))
        print("(negative slack is qualified for the debug revision; a release")
        print(" build is gated on closing it. deploy.py needs --allow-timing-miss.)")

    rbf = os.path.join(stage, "output_files", "%s.rbf" % REV)
    print("\nOK -- deploy with:\n"
          "  python scripts/deploy.py --rbf-only --log \"%s\" \\\n"
          "      --rbf \"%s\" \\\n"
          "      --sta \"%s\""
          % (log_path, rbf,
             os.path.join(stage, "output_files", "%s.sta.summary" % REV)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
