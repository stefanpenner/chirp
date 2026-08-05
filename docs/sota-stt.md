# On-device STT landscape vs Chirp (2026-08-05 fire)

Chirp is **speech-to-text** (hold-to-talk dictation), not TTS.
Tracked: `yodel-adv3`. **Decision: KEEP default; TRIAL optional engines (one path shipped).**

## Chirp today

| Piece | Choice |
|-------|--------|
| ASR | NVIDIA **Parakeet TDT 0.6b v3** int8 via **sherpa-onnx** (`ModelVariant`: `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`, ~465MB) |
| EP | **CPU** default (`InferenceProvider`); CoreML optional `CHIRP_ASR_PROVIDER=coreml` |
| VAD | Silero ONNX, CPU (bundled `silero_vad.onnx`) |
| Streaming | Offline one-shot buffers; VAD endpoints; peek on `pendingAudio` |
| Fixup | Optional on-device T5 / cloud LLM batch at flush |
| Cloud STT | Optional OpenAI Whisper / Google / etc. via modes |
| **Apple Speech (trial)** | `TranscriptionMode.systemSpeech` → `SystemSpeechClient` (SpeechAnalyzer / SpeechTranscriber, macOS 26+); flush batch + local Parakeet peek; **not** default |

CPU-first is intentional: Parakeet int8 via sherpa often **slower/less stable on CoreML** than multi-thread CPU (EP thrashing).

Local model on disk may still be v2 (`models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/`); product download URL is **v3**.

## SOTA paths on Apple Silicon (2026)

| Engine | Model IDs | Runtime | Offline | Notes |
|--------|-----------|---------|---------|-------|
| **Chirp default** | `parakeet-tdt-0.6b-v3` int8 (sherpa-onnx NeMo TDT) | ORT CPU (CoreML optional) | Yes, pinned | Multilingual 25 Euro langs; chunked offline + VAD |
| **FluidAudio** | CoreML ports of same family: `parakeet-tdt-0.6b-v3-coreml`, **EOU 120m** streaming, TDT-CTC-110M (3.01% WER LS-clean, 96.5× RTFx M2) | **ANE** | Yes | Same family, better ANE path; streaming EOU English-only |
| **Apple SpeechAnalyzer** | `SpeechTranscriber` / `DictationTranscriber` + `SpeechDetector` | ANE (OS 26+) | On-device | Best clean multi-lang WER in Dictato 13k bench; not user-swappable weights |
| **WhisperKit** | `openai/whisper-{tiny,base,small,large-v3}` Core ML | ANE/GPU | Yes | Strong EN/ES clean; best brand/vocab boosting |
| **Qwen3-ASR** (Fluid/Dictato) | multilingual ~30 langs | on-device | Yes | When 25-lang Parakeet coverage insufficient |
| **MLX-audio** | Whisper/etc MLX | GPU/unified mem | Yes | Research/tooling; less productized for Swift menu-bar |

### External quality signals (not Chirp benches)

Dictato (2026-04, 13k samples, 5 langs, on-device):

- Clean read-aloud: **SpeechAnalyzer** wins 4/5 langs; WhisperKit leads EN (~5.2% WER) and ES
- **Disfluent / real talk: Parakeet wins 3/5** — fillers/restarts (dictation-shaped)
- Jargon: raw engines weak; **LLM proofread** ~halves WER (Chirp already has T5/cloud fixup modes)
- Brands/proper nouns: WhisperKit prompt-bias strongest

FluidAudio Parakeet TDT-CTC-110M: 3.01% WER LibriSpeech test-clean, 96.5× RTFx on M2 (batch CoreML).

## Pillar scores (default path)

Scale 1–5. Higher = better for Chirp’s product.

| Path | SOTA | Perf (M4/M5) | Local/offline | Quality (dictation) | **Action** |
|------|------|--------------|---------------|---------------------|------------|
| **Parakeet TDT 0.6b v3 int8 + sherpa CPU** (shipped) | 4 | 4 (RTF ≫1, multi-thread) | **5** (pinned, MIT/Apache stack + CC-BY model) | **4** (disfluent win; multilingual) | **KEEP** |
| FluidAudio Parakeet CoreML/ANE (same weights family) | 4 | **5** (ANE, lower idle power) | 5 | 4 | **DEFERRED** — Bazel packaging (see below) |
| FluidAudio Parakeet EOU 120m streaming | 4 | 5 (true partials) | 5 | 3 (EN-only, smaller) | **DEFERRED** — design/TLA done; needs engine trial |
| Apple SpeechAnalyzer (macOS 26+) | **5** clean multi-lang | **5** ANE | 4 (on-device; opaque OS model) | 4 clean / 3 disfluent | **TRIAL shipped** — optional AI mode |
| WhisperKit large-v3 | 4 | 3–4 (ANE; heavier) | 5 | 4 clean EN; brand bias | **DEFERRED** — optional mode later |
| Cloud Whisper / vendor STT | 4–5 | n/a (net) | **1** | 4–5 | Keep as **opt-in mode** only |

### Decision (this fire)

1. **KEEP** `sherpa-onnx` + **Parakeet TDT 0.6b v3 int8** + Silero VAD + CPU EP as default.
   - Matches dictation (disfluent) strengths, full offline, no OS floor, existing TLA/pipeline.
2. **Do not swap** to SpeechAnalyzer/WhisperKit as sole engine (quality gap not decisive for Chirp’s talk-as-you-think + command grammar).
3. **TRIAL shipped**: `TranscriptionMode.systemSpeech` → `SystemSpeechClient` + `SystemSpeechAvailability`.
   - AI mode picker: “Apple Speech (trial)”. Flush via SpeechAnalyzer file path; peek still Parakeet.
   - Fallback to offline if OS &lt; 26. Pillars: SOTA↑ optional, local (on-device OS model), default path untouched.
4. **FluidAudio ANE DEFERRED** (`yodel-ckb`): SPM package is fine (MIT/Apache + binary NemoTextProcessing), but Chirp **ships via Bazel** (`ChirpLib` + vendored sherpa/ORT). Pulling FluidAudio means rules_swift remote package **or** vendored framework + multi‑GB CoreML model manager + code-sign story — larger than a trial slice. Modeled in `EngineMode.tla` (`fluid` → offline when `fluidOk=FALSE`); product has no picker case yet. Revisit when re-bench shows ANE energy win on Chirp peek cadence.
5. **Streaming EOU DEFERRED** (`yodel-88e`): design + TLA shipped — product stays **peekOnly** (offline re-decode cadence). True streaming/EOU needs a streaming ASR (e.g. FluidAudio EOU 120m EN-only) and would auto-commit on EOU; that path is isolated in `StreamingPartial.tla` / `StreamingPartialDecision` and is **not** selectable. Un-defer only with: streaming engine behind optional mode + dual tests + re-bench latency/WER vs peek-only.
5b. **Empty-total vs live peeks**: **fixed** — flush promotes last non-empty peek when re-decode empty (`DecodePolicy.shouldPromotePeekOnEmptyFlush` / `PeekCommitHyp` PromoteEmpty).
6. **Re-bench infra shipped** (`yodel-go0` partial): `TranscriptionScoring` live/total + grades; `VoiceCondition`; manual `//:LiveTotalPipelineTests` / `//:VoiceConditionPipelineTests`. Residual: hardware RTF/battery log vs optional engines.
7. **Engine mode rigor**: `EngineMode.tla` + `EngineModeDecision` — optional engines fall back to offline; mid-session select defers (with `PipelineRebuild`).
8. **Partial path rigor**: `StreamingPartial.tla` — peekOnly default; EOU auto-commit only in streamingEOU; partials only in session.

## m4/m5 practical notes (Chirp)

- Mic convert hops off I/O thread; AsyncStream + convert backlog are bounded (`yodel-adv1` fixed).
- `num_threads = 4` ASR fine for burst dictation; watch UI + T5 contention on long sessions.
- Prefer smaller decode work per peek (PeekCache / speech-window).
- Avoid eager VP aggregate devices when idle (lazy prepare + park teardown).
- ANE trial paths matter most for **battery/thermal** on continuous peek, not one-shot RTF.

## Hostile / adversarial notes

| ID | Topic | Status |
|----|--------|--------|
| yodel-adv1 | Unbounded `AsyncStream` + RT-thread convert | **fixed**: `bufferingNewest(AudioCapturePolicy.streamBufferChunks)`; convert hops on `chirp.audio.convert` with `ConvertBacklog` |
| yodel-adv2 | Mid-session config change → stale converter in tap | **fixed**: live `AudioConverterSlot`; convert uses **tap-time snapshot** (not hop re-read) so in-flight buffers keep matching rate/converter |
| yodel-adv3 | SOTA notes + optional engine trial | **decision + systemSpeech trial shipped**; FluidAudio **deferred** (Bazel); EOU **design/TLA done** (peekOnly kept); re-bench residual |
| yodel-adv4 | Rejoin dual-consumer without gen cancel | **fixed** (SessionMachine + `consumerGeneration` gate) |
| clean-pass | Adversarial on audio/status/session/engine | **clean** (2026-08-05): no new material bugs; TLC AppStatus/SessionMachine/EngineMode/PeekCommitHyp green; residual = deferred Fluid/EOU/energy only |

## Refs

- FluidAudio Models.md (Parakeet TDT v3 / EOU / Silero / diarization CoreML)
- Dictato engine comparison (2026-04): SpeechAnalyzer / WhisperKit / Parakeet / Qwen3
- Argmax WhisperKit vs Apple SpeechAnalyzer
- sherpa-onnx NeMo Parakeet TDT model cards
- Chirp: `InferenceProvider`, `ModelVariant`, `Architecture.md`
