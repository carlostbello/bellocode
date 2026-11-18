#!/usr/bin/env python3 -I
"""Derive seccomp-chromium.json from Docker's default profile (github.com/moby/profiles, seccomp/default.json):
the only change is that clone/unshare/setns/chroot are allowed without CAP_SYS_ADMIN, so Chromium can create the user, PID
and network namespaces of its own renderer sandbox. No capability is added. Usage: make-seccomp.py default.json out.json"""
import json, sys
profile = json.load(open(sys.argv[1]))
profile["syscalls"].append({"names": ["clone", "unshare", "setns", "chroot"], "action": "SCMP_ACT_ALLOW",
                            "comment": "BelloCode G7: Chromium namespace sandbox"})
json.dump(profile, open(sys.argv[2], "w"), indent=1)
