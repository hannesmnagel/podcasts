# Chapterization Notes

## Test Case

Primary test episode:

- Podcast: The Skeptics' Guide to the Universe
- Episode: `The Skeptics Guide #1085 - Apr 25 2026`
- Episode ID: `825bac4c9f7e51c5f2cc0377d9323ef243a27937498c5c75780c521b86ecf8a1`
- Transcript fixture: `/tmp/sgu1085-chapter-fixture.json`
- Transcript size: 1,144 Whisper segments, about 7,065 seconds, about 111 KB of transcript text, about 21k words

## Final SGU Result

Command:

```sh
PODCAST_CHAPTERIZER_FIXTURE=/tmp/sgu1085-chapter-fixture.json \
PODCAST_OLLAMA_MODEL=gemma3:12b \
PODCAST_OLLAMA_CONTEXT=32768 \
swift test --filter ChapterizerTests/testOllamaChapterizerAgainstTranscriptFixtureWhenEnabled
```

Result:

```text
0s     Introduction
462s   What's the Word: Cryptomnesia
1009s  News Items: Belief in Unproven Health Claims
2022s  News Items: Regenerating Limbs
3122s  News Items: Suicide Hotline Seems to Work
3970s  News Items: Why is Rubber Strong
4595s  Who's That Noisy
5263s  Your Questions and E-mails: Mythos Follow Up
5647s  Your Questions and E-mails: Americans' Knowledge of Mexico
6249s  Science or Fiction
```

This is the first run that matched the expected listener-level episode structure without falling back to generated show-note chapters.

## What Works

- Long episodes are split into full-text transcript sections, not compact excerpts.
- The section windows preserve all transcript text for each part.
- Window boundaries use duration, text length, and a relative pause threshold derived from that podcast episode's own pauses.
- The model emits only `{title,startSecond}` JSON.
- Section-level LLM candidates are grounded against transcript text before they can be used.
- Grounding uses rolling transcript boundaries so title words split across adjacent Whisper segments can still align to the real start.
- When show notes provide an inventory, final deduplication prefers LLM candidates matching those major segments over adjacent ads or subtopics.
- Raw model output can be inspected with `PODCAST_CHAPTER_LOG_RAW=true`.

## What Failed

- Original anchor-string matching was brittle on long transcripts because paraphrased or shifted anchors got dropped.
- A single full-transcript `llama3.1:8b` prompt took about 10 minutes and returned invalid/truncated JSON in testing.
- The `llama3.2:3b` path was not promising for full-transcript long-context quality.
- Early section prompts overused show-note inventory and hallucinated later topics at intro timestamps.
- Simple first-candidate deduplication allowed adjacent subtopics or ads to crowd out real segment candidates.

## Current Production Choice

- Default chapter model: `gemma3:12b`
- Default Ollama context: `65536`
- Tested SGU context: `32768`
- Default minimum chapter spacing: `90` seconds

The important quality constraint is that the worker must fail rather than synthesize low-quality fallback chapters. The current path uses LLM-generated candidates plus transcript grounding and inventory-constrained candidate selection; it does not create deterministic show-note fallback chapters.
