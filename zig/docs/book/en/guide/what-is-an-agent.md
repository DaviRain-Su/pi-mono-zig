---
title: Chapter 1 · What is an AI Agent
---

# Chapter 1 · What is an AI Agent

## 1.1 The naive question

You've used ChatGPT, Claude, or some other chat UI. You type, it replies, done. In engineering terms that's a **one-shot inference**.

When people say "AI Agent" they usually mean something else:

> You: "Remove every `console.log` in this project."
>
> Then a stream of actions scrolls past:
> 1. List directory
> 2. Read file
> 3. Edit file
> 4. List directory again
> 5. Run tests
> 6. Report back

No human pressed buttons. No copy-paste between two ChatGPT tabs. **That is the line between an agent and a one-shot call:** an agent feeds its own output back in and keeps going.

## 1.2 One picture says it

::: tip
Every diagram in this book is rendered with [Mermaid](https://mermaid.js.org/) — view source if you want to copy.
:::

### One-shot

```mermaid
sequenceDiagram
    participant U as User
    participant L as LLM
    U->>L: A prompt
    L-->>U: A response
    Note over U,L: Done
```

### Agent

```mermaid
sequenceDiagram
    participant U as User
    participant A as Agent
    participant L as LLM
    participant T as Tools<br/>(files / shell / HTTP)

    U->>A: A goal
    loop until goal met or aborted
        A->>L: state + available tools
        L-->>A: think / request a tool
        alt LLM wants a tool
            A->>T: run the tool
            T-->>A: tool result
        else LLM gives a final answer
            A-->>U: final answer
        end
    end
```

If you remember one sentence from this chapter:

> **Agent = LLM + Tools + Loop**

## 1.3 Three ingredients, separately

### 1.3.1 LLM: the decision core

In an agent, an LLM does exactly one thing: **given the current state, decide the next move**. It executes nothing. It only emits "what I want to do."

```mermaid
flowchart LR
    State["current dialog<br/>+ available tools"] --> LLM
    LLM --> Decision{next move}
    Decision -->|done thinking| Reply[final answer]
    Decision -->|needs info| Call[request a tool call]
```

### 1.3.2 Tools: the actuators

Tools are where an agent actually *does* things. The most common in a coding agent:

| Tool | Purpose | In `pi-mono` |
| --- | --- | --- |
| `read` | Read a file | `zig/src/coding_agent/tools/read.zig` |
| `edit` | Modify a file | `zig/src/coding_agent/tools/edit.zig` |
| `bash` | Run a shell command | `zig/src/coding_agent/tools/bash.zig` |
| `grep` | Search the repo | shells out to `rg` |

::: warning
The LLM **does not** touch your disk — it only *requests* a read. The agent framework executes it. That layer of indirection is the foundation of every safety boundary; Chapter 7 explores it in depth.
:::

### 1.3.3 The loop: bringing it to life

A driving loop ties the LLM and tools together. Pseudocode:

```ts
while (!done) {
  const decision = await llm.next(state);
  if (decision.kind === "final") {
    done = true;
    return decision.text;
  }
  const result = await tools.run(decision.tool, decision.args);
  state.append({ tool: decision.tool, result });
}
```

The rest of this book is "expand those ten lines into a real, extensible, production-shaped system."

## 1.4 What is *not* an agent

Pinning down concepts works better with negative space:

- **Chatbot** ≠ agent. No external action.
- **RAG system** ≠ agent (but can be part of one). Retrieval is **single-step**.
- **Workflow** ≠ agent. The steps are **human-authored**; an agent's steps come from the **LLM**.

```mermaid
flowchart TB
    classDef agent fill:#f7a41d22,stroke:#f7a41d
    classDef notagent fill:transparent,stroke:#666

    A[Chatbot]:::notagent
    B[RAG]:::notagent
    C[Static workflow]:::notagent
    D[Agent]:::agent

    A -->|add tool calling| D
    B -->|add a loop| D
    C -->|let the LLM choose steps| D
```

## 1.5 What's next

In Chapter 2 we dig into the first ingredient — **the shape of an LLM API**:

- It's not just a string; what's a `messages` array?
- What's a token? Why is it the billing unit?
- How does streaming output actually work, line by line?
- What is SSE?

[**Continue to Chapter 2 →**](./) <!-- TODO -->

---

::: info Code reference for this chapter
- TypeScript agent loop: `packages/agent/src/agent.ts`
- Zig agent loop: `zig/src/agent/agent.zig`

Chapter 5 walks through both line by line — for now, just know they exist.
:::
