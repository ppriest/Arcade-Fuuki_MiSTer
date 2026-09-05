#!/usr/bin/env python3
"""Copy the built core and its .mra files to a MiSTer.

    python scripts/deploy.py                 # FG-2 sets only (see --all)
    python scripts/deploy.py --all           # include the FG-3 sets
    python scripts/deploy.py --mra-only      # skip the bitstream
    python scripts/deploy.py --dry-run       # show what would be copied

Connection settings come from ./mister.env (gitignored):

    MISTER_HOST=...
    MISTER_USER=...
    MISTER_PASSWORD=...

Transport is PuTTY's plink/pscp, because Windows has no OpenSSH password-auth
automation without sshpass and that is not commonly installed there.

WHY THE BUILD GUARD IS HERE
---------------------------
Ported from the Psikyo core's scripts/deploy_rbf.py, which records the reason:
a Quartus build died mid-Fitter, Quartus left the PREVIOUS build's .rbf in
output_files/, the deploy copied that stale bitstream under a new name, and the
verification screenshot came back healthy -- because it was verifying the
previous build. A green result against a stale artifact is worse than a red
one, because it looks like evidence.

So two independent checks, either of which alone can be fooled:
  1. the build log contains Quartus's success line;
  2. the .rbf is not meaningfully older than that log.

A third check is specific to this project: the timing summary must contain no
negative slack. Quartus reports "Fitter was successful" on a design that
grossly fails timing (Fuuki.sdc's header says so), and a bitstream that failed
timing is not worth the time it takes to test.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REMOTE_CORES = "/media/fat/_Arcade/cores"
# The .mra files live in their own folder, clones in _alternatives beneath it.
REMOTE_ARCADE = "/media/fat/_Arcade/_Fuuki"
SUCCESS = "Full Compilation was successful"

# FG-3 needs the SDRAM controller widened past 32 MB before it can run at all
# (rtl/memory/fuuki_sdram_top.sv). Its .mra files are proven and correct, but
# putting them on the device invites launching a game that cannot work, so they
# are opt-in rather than default.
FG3_SETS = ("Asura Blade", "Asura Buster")


def load_env(path):
    env = {}
    if not path.exists():
        sys.exit(f"{path.name} not found. Create it with MISTER_HOST, "
                 f"MISTER_USER and MISTER_PASSWORD (it is gitignored).")
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    for k in ("MISTER_HOST", "MISTER_USER", "MISTER_PASSWORD"):
        if not env.get(k):
            sys.exit(f"{path.name} does not set {k}")
    return env


def find_putty(name):
    for c in (name, os.path.join(r"C:\Program Files\PuTTY", name)):
        found = shutil.which(c) or (c if os.path.isfile(c) else None)
        if found:
            return found
    sys.exit(f"Couldn't find {name}. Install PuTTY, or put it on PATH.")


class Mister:
    def __init__(self, env, dry_run):
        self.host = env["MISTER_HOST"]
        self.user = env["MISTER_USER"]
        self.pw = env["MISTER_PASSWORD"]
        self.dry = dry_run
        self.plink = find_putty("plink.exe")
        self.pscp = find_putty("pscp.exe")

    def run(self, command):
        if self.dry:
            print(f"    [dry-run] ssh: {command}")
            return ""
        # -batch refuses interactively rather than hanging; the host key is
        # accepted automatically, matching the plain plink -pw flow.
        p = subprocess.run([self.plink, "-ssh", "-batch", "-pw", self.pw,
                            f"{self.user}@{self.host}", command],
                           capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            sys.exit(f"ssh failed ({p.returncode}): {command}\n{p.stderr.strip()}")
        return p.stdout

    def put(self, local, remote):
        print(f"    {local.name}  ->  {remote}")
        if self.dry:
            return
        p = subprocess.run([self.pscp, "-batch", "-pw", self.pw,
                            str(local), f"{self.user}@{self.host}:{remote}"],
                           capture_output=True, text=True, timeout=300)
        if p.returncode != 0:
            sys.exit(f"copy failed ({p.returncode}): {local} -> {remote}\n"
                     f"{p.stderr.strip()}")


def print_timing(sta):
    """Print every clock's worst setup/hold slack from the STA summary.

    Always printed, met or not, so the timing of the build being deployed is
    on the record next to the deploy rather than having to be dug out of
    output_files/ afterwards.
    """
    kind = None
    rows = []
    for line in sta.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("Type"):
            kind = line.split(":", 1)[1].strip()
        elif line.startswith("Slack") and kind:
            slack = float(line.split(":", 1)[1])
            typ, _, clk = kind.partition(" ")
            clk = clk.strip("'")
            # the PLL outputs are all called divclk; name them by their PLL
            for key, name in (("emu|pll|", "clk_sys (emu pll)"), ("pll_hdmi", "hdmi pll"),
                              ("pll_audio", "audio pll")):
                if key in clk:
                    clk = name; break
            else:
                clk = clk.split("|")[-1]
            rows.append((typ, clk, slack))
            kind = None
    print(f"\n  timing ({sta.name}):")
    for typ, clk, slack in rows:
        flag = "  <-- NEGATIVE" if slack < 0 else ""
        print(f"    {typ:9s} {slack:+8.3f} ns  {clk}{flag}")


def check_build(rbf, log, sta, allow_timing_miss=False):
    """Refuse to deploy a bitstream the build did not actually produce.

    Returns (hard_problems, warnings). The STALE-ARTIFACT checks are hard: a
    bitstream that is not the one just built makes every later measurement a
    lie. A TIMING miss is different -- during bring-up a design that misses by
    a fraction of a nanosecond usually still runs, and finding out whether it
    boots at all is worth more than a green report. So that one is
    downgradeable with --allow-timing-miss, and never by --force alone.
    """
    problems = []
    warnings = []

    if not rbf.exists():
        problems.append(f"{rbf} does not exist")
    if not log.exists():
        problems.append(f"build log {log} does not exist")
    else:
        text = log.read_text(encoding="utf-8", errors="replace")
        if SUCCESS not in text:
            problems.append(f"build log lacks {SUCCESS!r} -- the build FAILED")
            for line in text.splitlines():
                if line.startswith("Error ("):
                    problems.append("    " + line.strip()[:110])

    if rbf.exists() and log.exists():
        skew = log.stat().st_mtime - rbf.stat().st_mtime
        if skew > 900:
            problems.append(
                f".rbf is {int(skew/60)} minutes older than the build log -- "
                f"almost certainly left over from a PREVIOUS build")

    if not sta.exists():
        problems.append(f"{sta} does not exist -- STA did not run")
    else:
        print_timing(sta)
        neg = [l.strip() for l in sta.read_text(encoding="utf-8").splitlines()
               if l.strip().startswith("Slack") and ": -" in l]
        if neg:
            msg = (f"TIMING NOT MET -- {len(neg)} negative slack entries, "
                   f"worst {neg[0]}")
            (warnings if allow_timing_miss else problems).append(msg)
    return problems, warnings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rbf", default=str(REPO / "output_files" / "Fuuki.rbf"))
    # Default to the NEWEST compile*.log: several build flows write differently
    # named logs (compile.log, compile_fix.log, compile_phase.log), and the
    # guard must check the log of the build that actually produced the .rbf.
    logs = sorted((REPO / "output_files").glob("compile*.log"), key=lambda f: f.stat().st_mtime)
    ap.add_argument("--log", default=str(logs[-1]) if logs else str(REPO / "output_files" / "compile.log"))
    ap.add_argument("--sta", default=str(REPO / "output_files" / "Fuuki.sta.summary"))
    ap.add_argument("--name", default="Arcade-Fuuki.rbf",
                    help="remote core filename; the .mra's <rbf> tag must match "
                         "its stem")
    ap.add_argument("--all", action="store_true",
                    help="also deploy the FG-3 .mra files (they cannot run yet)")
    ap.add_argument("--mra-only", action="store_true")
    ap.add_argument("--rbf-only", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--allow-timing-miss", action="store_true",
                    help="deploy a build that misses timing (bring-up only -- "
                         "it does NOT relax the stale-bitstream checks)")
    ap.add_argument("--force", action="store_true",
                    help="deploy despite failed build checks -- say why")
    a = ap.parse_args()

    env = load_env(REPO / "mister.env")
    m = Mister(env, a.dry_run)
    print(f"MiSTer: {env['MISTER_USER']}@{env['MISTER_HOST']}")

    # ---- bitstream ----
    if not a.mra_only:
        problems, warnings = check_build(Path(a.rbf), Path(a.log), Path(a.sta),
                                         a.allow_timing_miss)
        for w in warnings:
            print(f"\n  WARNING: {w}")
            print("  Deploying anyway (--allow-timing-miss). This build is for "
                  "bring-up, not release.")
        if problems:
            print("\nREFUSING TO DEPLOY THE BITSTREAM:")
            for p in problems:
                print(f"  {p}")
            if not a.force:
                print("\nNothing was copied. Fix the build, or pass --force "
                      "deliberately.")
                return 1
            print("\n--force given; deploying anyway.")
        print(f"\n  core -> {REMOTE_CORES}")
        m.run(f"mkdir -p {REMOTE_CORES}")
        m.put(Path(a.rbf), f"{REMOTE_CORES}/{a.name}")

    # ---- .mra files ----
    if not a.rbf_only:
        rel = REPO / "releases"
        mras = sorted(rel.rglob("*.mra"))
        if not mras:
            sys.exit("no .mra files in releases/ -- run scripts/build_mra.py")

        skipped = []
        print(f"\n  .mra -> {REMOTE_ARCADE}")
        made = set()
        for f in mras:
            if not a.all and any(f.name.startswith(s) for s in FG3_SETS):
                skipped.append(f.name)
                continue
            sub = f.parent.relative_to(rel).as_posix()
            remote_dir = REMOTE_ARCADE if sub == "." else f"{REMOTE_ARCADE}/{sub}"
            if remote_dir not in made:
                m.run(f'mkdir -p "{remote_dir}"')
                made.add(remote_dir)
            # NOT quoted: pscp takes argv directly, so shell quotes would
            # become part of the remote path. The mkdir above IS quoted,
            # because that one is interpreted by a remote shell.
            m.put(f, f"{remote_dir}/{f.name}")

        if skipped:
            print(f"\n  SKIPPED {len(skipped)} FG-3 .mra file(s): FG-3 needs the "
                  f"SDRAM controller widened past 32 MB before it can run.")
            print(f"  Pass --all to copy them anyway.")

    print("\nDone." if not a.dry_run else "\nDry run -- nothing was copied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
