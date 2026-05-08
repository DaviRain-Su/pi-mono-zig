---
title: Introduction
---

# Introduction

This book has one goal: **to teach you how to build an AI coding agent from scratch.**

We use [`pi-mono`](https://github.com/DaviRain-Su/pi-mono-zig) — a real-world AI coding agent written in TypeScript and being rewritten in Zig — as the running example. By the end you'll have:

1. **Concepts**: what an LLM is, what tool calling means, how the agent loop works, how to abstract providers, and how to extend an agent safely.
2. **Code**: every concept is backed by runnable code in the repository, in **both TypeScript and Zig**.

## Who this book is for

- **Developers entering AI agent engineering** — you've used ChatGPT or Claude but you're fuzzy on what happens between "API" and "agent".
- **People moving toward Zig** — you want to read a non-toy Zig codebase.
- **TypeScript/Node.js developers curious about systems programming** — every abstraction is shown in both TS and Zig, and the comparison teaches more than either alone.

## Chapter map

| Ch. | Topic | What you'll learn |
| --- | --- | --- |
| 1 | What is an AI Agent | The line between LLMs and agents; loops vs one-shot calls |
| 2 | The shape of an LLM API | messages, tokens, streaming, SSE |
| 3 | Tool calling | function schemas, `tool_use`, `tool_result` |
| 4 | Provider abstraction | Reconciling OpenAI, Anthropic, and Google |
| 5 | The agent loop | State machines, turns, termination |
| 6 | The coding agent | File I/O, shell, safety boundaries |
| 7 | Extensions | WASM, sub-agents, capability boundaries |
| 8 | TUI and sessions | Streaming output, replay, cancellation |

::: tip How to read
Each chapter follows the same shape: **concept → diagram → minimal code → tour of the real implementation**. Skim the first two sections for concepts; follow the third hands-on.
:::

::: info Prerequisites
- Comfort writing small projects in any mainstream language
- Knowing what HTTP and JSON are
- **No** Zig knowledge — we teach it as we go
- **No** machine learning background needed
:::

Ready? Start with Chapter 1: [**What is an AI Agent →**](./what-is-an-agent)
