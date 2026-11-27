# Experiment Log

## Current project
- A macOS app (CoreWLAN) records Wi-Fi scans: BSSID, SSID, RSSI and channel for each AP.
- Task: classify a scan into one of 9 points (P1–P9) in one apartment.
- Data: 2 rounds on the same day. Scan 1 of each session is dropped, leaving 126 refs + 33 tests per round (252 / 66 pooled).
- Method: keep a BSSID only if it appears in ≥50% of a point's reference scans, at at least one point. Then k-NN with RMS RSSI distance; missing APs are filled with −100 dBm, two scans must share ≥3 APs, and the k neighbors vote.
- Baseline: pooled 3-NN gets 53/66 (80.3%). Most errors are P8 being labeled as P5/P6.
- Cross-round (train on one round, test on the other) drops to about 52–58% (R1→R2 18–19/33, R2→R1 16–17/33).

## Exp 1: Split APs by band (2026-11-25)
- Idea: assign each BSSID a band from its channel (≤14 is 2.4 GHz, >14 is 5 GHz) and run k-NN on one band only. The data and everything else stay the same.

| 1-NN | APs (pooled) | Pooled | R1→R2 | R2→R1 |
|---|---|---|---|---|
| All (baseline) | 63 | 52/66 | 19/33 | 17/33 |
| 2.4 GHz only | 24 | 32/66 | 13/33 | 11/33 |
| **5 GHz only** | 39 | **62/66** | **25/33** | **33/33** |

- 3-NN shows the same pattern (5 GHz: 62/66, 27/33, 31/33).
- Median RMS distance between the 252 refs (`scripts/band_distance.py`), same point / different point: 2.4 GHz 18.6 / 22.0 dB (×1.18), all 12.9 / 17.1 (×1.33), 5 GHz 7.1 / 13.3 (×1.88).
- Pooled 1-NN confusion (`scripts/confusion_1nn.py`): P8 is 3/8 with all APs (others go to P5/P6/P7) and 8/8 with 5 GHz.
- Finding: 5 GHz alone beats using all APs, both within a round and across rounds, and the P8 confusion goes away. 2.4 GHz signals pass through walls, so every point sees a similar 2.4 GHz pattern. Those APs add noise rather than help tell points apart.
- Caveats:
  - Only 66 test scans.
  - Channels 37/69/101/133 are probably 6 GHz. Dropping them still gives 59/66.
  - 6 GHz channels 1/5/9 look the same as 2.4 GHz channels 1/5/9 and can't be told apart; saving `channelBand` in the app would fix this.

### What the columns mean
- **Pooled:** refs from both rounds, tests from both rounds. Each test comes from the same session as some refs, about 10 s apart, so this is the easy case.
- **R1→R2 / R2→R1:** refs from one round, tests from the other round. This is closer to real use: the database is built first and used later.

### Why cross-round matters
- In Pooled, most test scans match a reference from their own round:

  | 1-NN | Nearest reference from the same round |
  |---|---|
  | All APs | 49/66 |
  | 5 GHz only | 51/66 |

- So Pooled accuracy is optimistic. The baseline's 80% depends mostly on the test and reference scans being only seconds apart.
- With all APs, cross-round accuracy drops to about 52–58%, so the mixed-band fingerprint is unstable. With 5 GHz only, cross-round reaches 25/33 and 33/33, which shows 5 GHz is more stable across rounds, not just higher in Pooled.
- Limit: both rounds were collected on the same day, so this says nothing yet about other days or other devices.
- Implication: collecting references over several rounds covers more environment states and should make the database more robust.

## Exp 2: Adaptive band + multi-scan localization (2026-11-25)
- Idea: the system decides at run time instead of using one fixed setting.
  1. **Band fallback:** match on 5 GHz APs first; if fewer than 3 are shared, use all bands.
  2. **Confidence:** r = (distance to best label) / (distance to 2nd-best label). Smaller r = more sure.
  3. **Scan again if unsure:** if r ≥ τ, take the next scan, average each AP over the scans so far, and decide again (max 3 scans).
- Simulated by replaying each test session's scans in order.

| | Pooled | R1→R2 | R2→R1 | Avg scans |
|---|---|---|---|---|
| Baseline, 1 scan, all APs | 52/66 | 19/33 | 17/33 | 1 |
| 5 GHz + fallback, 1 scan | 62/66 | 25/33 | 33/33 | 1 |
| Adaptive, τ=0.9 | 64/66 | 29/33 | 33/33 | 1.05–1.15 |
| Adaptive, τ=0.8 | 66/66 | 30/33 | 33/33 | 1.18–1.42 |
| Fixed 2 scans (no confidence) | 66/66 | 32/33 | 32/33 | 1.73 |

- Finding: a second scan fixes most errors. The confidence check gets most of that gain with fewer scans (e.g. τ=0.9: +4 cross-round with ~1.1 scans), so τ trades accuracy against waiting time.
- Honest note: fixed 2 scans is as accurate or slightly better; the adaptive version only wins on scan count, not accuracy.
- Caveat: test sessions have only 2–7 scans, so "next scan" is sometimes unavailable.

## Exp 3: Adaptive system in the app (2026-11-25)
- Built Exp 2 into the app (`KNN.swift`, `CollectionModel.swift`): 5 GHz first with fallback, r, rescan while r ≥ τ = 0.9 (max 3 scans).
- Offline check: replayed the test scans through the app's own Swift code (scan 1 dropped from refs).

| τ = 0.9 | Pooled | R1→R2 | R2→R1 |
|---|---|---|---|
| 1 scan | 62/66 | 25/33 | 33/33 |
| Adaptive | 64/66 (1.05 scans) | 29/33 (1.15) | 33/33 (1.06) |

- Same numbers as the Python simulation, so the app matches the experiment.
- Live test: pick the true point under 实际点位; each finished request goes to `live-tests/live-<date>.jsonl` (truth, prediction, r, band, scan count, latency, raw scans).

## Exp 4: Live test (2026-11-25)
- 4 days after the reference collection (refs 11-21, live 11-25 19:50–20:19), same Mac. Library = 252 refs from both rounds.
- 50 requests (5 per point, P9 10), 63 valid scans, τ = 0.9.

| | Correct | Avg scans | ≈ time / fix |
|---|---|---|---|
| **App (adaptive, 5 GHz first)** | **43/50 (86%)** | 1.26 | median 5 s |
| Original: 1 scan, all APs (replayed) | 31/63 (49%) | 1 | — |
| 5 GHz, 1 scan (replayed) | 48/63 (76%) | 1 | — |

- Replaying the logged scans through the Python version gives the same 43/50, so the app matches the simulation.
- Rescans: 7 requests were unsure; 4 became correct after rescans, 3 stayed wrong. A rescan costs ~15 s (fresh scans come ~15 s apart; cached repeats are skipped), so 1 scan ≈ 5 s, 3 scans ≈ 35 s.
- Errors: P7 → P5 in 5/5 requests. Rescans don't fix it, so it's a systematic change at P7, not noise. 5 of 7 wrong answers ended with r < 0.9 (4 after one scan, 1 after three), so r is not a perfect check. "Confident but wrong" below uses this final-r definition.
- Implication: across days, 5 GHz matters most (49% → 76%); rescans add +10 points. Fixing P7 likely needs fresh references there.

## Exp 5: Band agreement + confirm-and-update library (2026-11-25)
- **Band agreement:** also call it unsure when the 5 GHz answer and the all-band answer differ.
- **Confirm and update:** if a request is still unsure after 3 scans, ask the user where they are, save those scans under that label into the library, and rebuild it. Control: "self-update" adds every confident answer under its own predicted label.
- Replayed on the live-test scans in time order (τ = 0.9). The app's Swift code gives the same numbers.

| Live test | Correct | Avg scans | Confident but wrong | User prompts |
|---|---|---|---|---|
| App as tested | 43/50 (86%) | 1.26 | 5 | 0 |
| + band agreement | 36/41 (88%) | 1.54 | 2 | 0 |
| + self-update | 42/52 (81%) | 1.21 | 7 | 0 |
| **+ confirm and update** | **47/52 (90%)** | **1.21** | 3 | 5 |
| + both | 38/43 (88%) | 1.47 | 1 | 10 |

- Band agreement: confident-but-wrong answers drop (live 5 → 2; R1→R2 4 → 2; pooled 2 → 0), but it costs more scans.
- Confirm and update: P7 was wrong 5/5; after its first prompt, 4 of the next 6 P7 requests were right. 5 prompts in 52 requests.
- Self-update makes things worse: P7 scans get saved as P5, so P7 stays wrong and a new P6 → P5 error appears. User confirmation is what makes updating safe.
- Combining both gives no gain over confirm-and-update alone and doubles the prompts.
- **Decision:** confirm-and-update is not adopted, because the system should not ask the user. The app keeps only the band-agreement toggle (default off). Self-update without confirmation is unsafe on this data, so the library stays fixed.
