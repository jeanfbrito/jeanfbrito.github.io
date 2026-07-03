---
title: "My Internet Drops Weren't the ISP: One Night of OPNsense Forensics"
date: 2026-07-03 04:20:00 -0300
categories: [Homelab, Networking]
tags: [opnsense, pppoe, bufferbloat, fq-codel, freebsd, tuning, dummynet, homelab]
description: "TV streams dropped whenever Claude Code got busy. The trail led through WiFi jitter, a pegged CPU core, hardware offloads poisoning FQ-CoDel — and two self-inflicted outages."
pin: false
math: false
mermaid: false
---

My TV streams started stuttering, and it always seemed to happen while Claude Code was chewing through something heavy. Classic blame triangle: is it the ISP, the OPNsense box, or the WiFi? I spent one long night finding out, and the answer was "none of the above, exactly" — it was a single CPU core silently choking on PPPoE at less than half my line rate, with no QoS to soften the blow. Here's the full forensic trail, including the two times I took my own network down while fixing it.

## The setup

The gateway is an OPNsense 25.1 box on an Intel Celeron J4105 (4 cores, 1.5 GHz base, passive cooling) with 2.5GbE igc NICs. WAN is PPPoE fiber, nominally 1 Gbps down / ~500 Mbps up. Symptom: intermittent multi-second "drops" visible on TV streaming and on API-heavy workloads, worse during the day.

First rule of blame triangles: don't guess, bisect. Ping the gateway (hop 1) and something past it (1.1.1.1) simultaneously and compare:

```bash
ping -c 30 -i 0.3 192.168.13.1   # LAN hop
ping -c 30 -i 0.3 1.1.1.1        # through the WAN
```

Result: zero loss everywhere, but the gateway ping showed min 3ms / max **226ms**, and 1.1.1.1 showed the exact same ~224ms max. When the jitter is identical at hop 1 and beyond, the problem lives on your side of the wall. The ISP was innocent from minute ten — everything past the gateway answered in ~5ms flat.

## The router was flying blind

I wanted history, so I went for OPNsense's gateway-quality graphs — and found there weren't any. `dpinger` (gateway monitoring) was disabled, so the box had zero record of WAN health. Worse, the traffic shaper was empty. The router had no idea whether the line was healthy and no mechanism to keep one greedy flow from starving another.

The RRD databases it *did* keep told the story anyway:

```bash
rrdtool fetch /var/db/rrd/wan-traffic.rrd AVERAGE -r 300 -s -172800
```

Sustained ~446 Mbps downloads exactly during the "drops during the day" window. Interesting number, because...

## The smoking gun: one core at 85%, three cores asleep

I ran a load test while sampling per-core CPU on the router:

```bash
# on the Mac
networkQuality -s -v
# on the router, meanwhile
top -bP -d 6 -s 2 | grep -E "^CPU [0-9]"
```

```
CPU 0:  0.4% user, 87.1% system, 12.5% idle
CPU 1:  0.0% user,  3.1% system, 96.9% idle
CPU 2:  0.0% user,  6.7% system, 93.3% idle
CPU 3:  0.0% user,  3.9% system, 96.1% idle
```

There it is. On FreeBSD, PPPoE processing runs through netgraph and, with the default `net.isr.dispatch=direct`, effectively lands on one core. A J4105 core at 1.5 GHz tops out around 450-650 Mbps of PPPoE — exactly where my RRDs showed the sustained pulls. When that core saturates, *everything* queues behind it: the TV stream, DNS, your SSH session. That's the "drop".

The fix is three tunables:

```
net.isr.dispatch=deferred    # runtime-settable, spreads packet processing
net.isr.maxthreads=-1        # one netisr thread per core (boot-time)
net.isr.bindthreads=1        # pin threads to cores (boot-time)
```

I set `dispatch=deferred` live and re-ran the load test: CPU 0 dropped from 87% to 17%, with the load spread across all four cores as interrupt time. One sysctl, most of the win.

## FQ-CoDel, and the offload that poisoned it

With the CPU fixed, the remaining bufferbloat (33ms idle → 112ms loaded) called for a shaper. OPNsense does FQ-CoDel via dummynet: one pipe per direction, sized just under line rate, plus two rules matching `in`/`out` on the WAN interface. I went with 900 Mbit down / 500 Mbit up.

It worked instantly for latency — pings under full load went from 224ms max to **28ms max** — but upload throughput collapsed to 37 Mbps. Through a 500 Mbit pipe.

The culprit was hardware offload. The NICs had TSO and LRO enabled (a leftover from an earlier "optimization" session — mine, of course). LRO coalesces inbound LAN packets into up-to-64KB mega-frames before forwarding; FQ-CoDel's scheduler hands each flow a 1514-byte quantum per round, so a 64KB frame waits ~43 scheduler rounds before it can leave. Throughput starves while the pipe sits mostly idle — zero drops in the stats, which is the fingerprint that distinguishes scheduler starvation from queue overflow.

```bash
ifconfig igc0 -tso -lro
ifconfig igc1 -tso -lro
```

Offloads are for endpoints, not forwarders. Routers should leave checksum offload on and kill TSO/LRO. Upload recovered immediately (multi-stream aggregates ~270 Mbps through the pipe; single-stream varies with path, which is TCP being TCP, not the shaper).

## Self-inflicted outage #1: the apply-path trap

Here's where I owe the honesty section. I had staged the shaper by editing OPNsense's `config.xml` directly (validated, backed up — that part was fine). Then I needed to *apply* it, and instead of using the UI's Apply button, I fired the service actions myself:

```bash
configctl filter reload   # did NOT apply the shaper
configctl ipfw reload     # enabled the ipfw layer... with an incomplete ruleset
```

`ipfw reload` started the ipfw firewall layer whose last rule is `deny all`. Every forwarded packet died. Internet gone, for the whole house, at 1 AM — and my SSH control path with it. Physical reboot required.

The lesson is structural, not just "oops": **on an appliance, the config store is safe to edit, but the apply machinery is the dangerous part.** `configctl` action names are not self-describing — "filter reload" doesn't touch the shaper, and "ipfw reload" *enables a firewall*. The UI's Apply button runs a whole chain (template → module → rules) in a tested order. If you bypass it, either replicate that chain exactly (read `/usr/local/opnsense/service/conf/actions.d/` first) or stage everything in config and let a controlled reboot apply it — a reboot runs the full boot chain, which is by definition the tested order.

## Self-inflicted outage #2: the revert timer that outlived its turn

Round two came later, while disabling EEE (Energy Efficient Ethernet) and flow control on the NICs. I'd learned enough to arm an auto-revert before touching the WAN-parent NIC:

```bash
nohup sh -c 'sleep 180; sysctl dev.igc.0.eee_control=1 dev.igc.0.fc=3' &
sysctl dev.igc.0.eee_control=0 dev.igc.0.fc=0
```

Toggling those flags resets the PHY — expected, PPPoE redials in ~20s. But my verification script ended *during* the redial window, before confirming recovery and killing the timer. Three minutes later the revert fired, re-toggled the NIC, and bounced the WAN a second time with nobody watching.

An armed revert must be **verified and disarmed in the same execution that armed it** — wait through the expected outage, confirm recovery, kill the timer, all in one script. If you can't structure it that way, don't arm a timer that flips state; arm one that converges to a known-good state no matter when it fires (like a scheduled reboot into a known config).

Bonus lesson from the fallout: when PPPoE refuses to reconnect right after a burst of redials, *stop touching the config*. My ISP's BRAS held the dead session and refused new logins for several minutes. A config restore "didn't fix it", a setup-wizard rerun "did" — but a later diff of the two configs showed the PPPoE sections were **functionally identical**. Time fixed it; the wizard got the credit. Wait five to ten minutes and power-cycle the ONU before you "fix" a working config into an unknown state.

## The rest of the fuses

With the box stable, the remaining wins were staged in config and applied with one deliberate reboot:

- **powerd** in hiadaptive mode — the J4105 was pinned at 1.5 GHz forever because powerd wasn't running. Turbo to 2.5 GHz is a +66% single-core ceiling, and this thing runs at 35°C passive, so there was zero thermal reason not to.
- **EEE + flow control off** on both NICs — jitter and head-of-line-blocking removal, staged as `dev.igc.X.eee_control=0` / `dev.igc.X.fc=0` sysctl entries so they apply at boot with no PHY bounce.
- **Spectre/Meltdown mitigations off** (`hw.ibrs_disable=1`, `vm.pmap.pti=0`) — a home firewall runs no untrusted local code; a few percent back on the packet path. Your threat model may differ.
- **MSS clamping** to match the PPPoE MTU — insurance against PMTU-blackhole stalls.
- **DNS-over-TLS forwarding** in Unbound to `1.1.1.1@853`: cold lookups went from 17-235ms (full recursion from Brazil) to a flat 15-20ms against Cloudflare's cache, with the local cache still serving warm hits in 2-3ms.

## The scoreboard

| Metric | Before | After |
|---|---|---|
| Latency under full load | 224ms spikes | 28ms worst case |
| Router throughput ceiling | ~450 Mbps (one core) | 900+ Mbps (4 cores + turbo) |
| Loaded responsiveness (RPM) | Medium, bufferbloated | High |
| Cold DNS lookup | up to 235ms | 15-20ms, encrypted |
| WAN health history | none | dpinger, per-second, graphed |

## Takeaway

Measure per-core, not aggregate — "CPU at 43%" hid a core at 87%, and that one number was the entire problem. And on any remote box that carries your own control path, the discipline that actually keeps you safe isn't a backup file: it's staging changes in the config store and letting one controlled reboot apply them, because the reboot path is the only apply path that's tested every single day.

---

*Written with [Fable 5](https://www.anthropic.com/news/claude-fable-5-mythos-5) (`claude-fable-5`) via Claude Code.*
