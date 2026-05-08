import { defineConfig } from "vitepress";
import { withMermaid } from "vitepress-plugin-mermaid";

const base = process.env.VITEPRESS_BASE ?? "/pi-mono-zig/book/";

export default withMermaid(
  defineConfig({
    title: "Pi Agent · 从零构建 AI 编码代理",
    description: "用 Zig 重写一个 AI 编码代理，顺便把 AI Agent 的核心概念学透",
    base,
    cleanUrls: true,
    lastUpdated: true,

    head: [
      ["link", { rel: "icon", href: `${base}favicon.svg`, type: "image/svg+xml" }],
      ["meta", { name: "theme-color", content: "#f7a41d" }],
    ],

    themeConfig: {
      logo: { src: "/logo.svg", width: 24, height: 24 },
      search: { provider: "local" },
      socialLinks: [
        { icon: "github", link: "https://github.com/DaviRain-Su/pi-mono-zig" },
      ],
    },

    locales: {
      root: {
        label: "简体中文",
        lang: "zh-CN",
        title: "Pi Agent · 从零构建 AI 编码代理",
        description: "用 Zig 重写一个 AI 编码代理，顺便把 AI Agent 的核心概念学透",
        themeConfig: {
          nav: [
            { text: "首页", link: "/" },
            { text: "学习指南", link: "/guide/" },
            { text: "模块卷宗", link: "/internals/" },
          ],
          sidebar: {
            "/guide/": [
              {
                text: "第一部分 · 基础概念",
                items: [
                  { text: "导言", link: "/guide/" },
                  { text: "1. 什么是 AI Agent", link: "/guide/what-is-an-agent" },
                  { text: "2. LLM API 的本质", link: "/guide/llm-api-shape" },
                  { text: "3. Tool Calling", link: "/guide/tool-calling" },
                  { text: "4. Provider 抽象层", link: "/guide/provider-abstraction" },
                ],
              },
              {
                text: "第二部分 · 核心机制",
                items: [
                  { text: "5. Agent Loop", link: "/guide/agent-loop" },
                  { text: "7. 扩展机制", link: "/guide/extensions" },
                ],
              },
              {
                text: "第三部分 · 应用与工程",
                items: [
                  { text: "6. Coding Agent 实战", link: "/guide/coding-agent" },
                  { text: "8. TUI 与会话", link: "/guide/tui-sessions" },
                ],
              },
              {
                text: "附录",
                items: [
                  { text: "A. C ABI v0.1", link: "/appendix/c-abi-v0" },
                ],
              },
            ],
            "/internals/": [
              {
                text: "模块卷宗",
                items: [
                  { text: "总览", link: "/internals/" },
                  { text: "ai/ — LLM Provider 抽象层", link: "/internals/ai" },
                  { text: "agent/ — Agent Loop 与状态机", link: "/internals/agent" },
                  { text: "coding_agent/ — 工具与扩展", link: "/internals/coding-agent" },
                  { text: "★ 扩展系统设计研究", link: "/internals/extension-system" },
                ],
              },
            ],
            "/appendix/": [
              {
                text: "附录",
                items: [
                  { text: "A. C ABI v0.1", link: "/appendix/c-abi-v0" },
                ],
              },
            ],
          },
          outline: { label: "本页目录", level: [2, 3] },
          docFooter: { prev: "上一页", next: "下一页" },
          lastUpdatedText: "最后更新",
          returnToTopLabel: "回到顶部",
          sidebarMenuLabel: "目录",
          darkModeSwitchLabel: "主题",
          lightModeSwitchTitle: "切换到浅色模式",
          darkModeSwitchTitle: "切换到深色模式",
          editLink: {
            pattern:
              "https://github.com/DaviRain-Su/pi-mono-zig/edit/zig-implementation/zig/docs/book/:path",
            text: "在 GitHub 上编辑此页",
          },
          footer: {
            message: "MIT 协议 · 用 ❤️ 写于 Pi Agent 项目",
            copyright: "© 2026 Pi Agent",
          },
        },
      },

      en: {
        label: "English",
        lang: "en-US",
        link: "/en/",
        title: "Pi Agent · Building an AI Coding Agent from Scratch",
        description:
          "Rewrite an AI coding agent in Zig and learn the core concepts of AI Agents along the way.",
        themeConfig: {
          nav: [
            { text: "Home", link: "/en/" },
            { text: "Guide", link: "/en/guide/" },
          ],
          sidebar: {
            "/en/guide/": [
              {
                text: "Part I · Foundations",
                items: [
                  { text: "Introduction", link: "/en/guide/" },
                  {
                    text: "1. What is an AI Agent",
                    link: "/en/guide/what-is-an-agent",
                  },
                  {
                    text: "2. The Shape of an LLM API",
                    link: "/en/guide/llm-api-shape",
                  },
                  {
                    text: "3. Tool Calling",
                    link: "/en/guide/tool-calling",
                  },
                  {
                    text: "4. The Provider Abstraction",
                    link: "/en/guide/provider-abstraction",
                  },
                ],
              },
              {
                text: "Part II · Core Machinery",
                items: [
                  { text: "5. The Agent Loop", link: "/en/guide/agent-loop" },
                  { text: "7. Extensions", link: "/en/guide/extensions" },
                ],
              },
              {
                text: "Part III · Application & Engineering",
                items: [
                  { text: "6. The Coding Agent in Practice", link: "/en/guide/coding-agent" },
                  { text: "8. TUI and Sessions", link: "/en/guide/tui-sessions" },
                ],
              },
              {
                text: "Appendix",
                items: [
                  { text: "A. C ABI v0.1", link: "/en/appendix/c-abi-v0" },
                ],
              },
            ],
            "/en/appendix/": [
              {
                text: "Appendix",
                items: [
                  { text: "A. C ABI v0.1", link: "/en/appendix/c-abi-v0" },
                ],
              },
            ],
          },
          outline: { label: "On this page", level: [2, 3] },
          editLink: {
            pattern:
              "https://github.com/DaviRain-Su/pi-mono-zig/edit/zig-implementation/zig/docs/book/:path",
            text: "Edit this page on GitHub",
          },
          footer: {
            message: "Released under the MIT License.",
            copyright: "© 2026 Pi Agent",
          },
        },
      },
    },

    markdown: {
      lineNumbers: true,
      theme: { light: "github-light", dark: "github-dark" },
    },

    mermaid: {
      theme: "default",
    },
  }),
);
