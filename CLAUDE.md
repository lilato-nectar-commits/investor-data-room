# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

Single-page, self-contained investor data room for Nectar Capital. There is **no build step, no package manager, no test suite, no backend**. The entire site is:

- `index.html` — ~3,700 lines, ~1.8MB. Contains all markup, CSS, JS, and data (inline `<style>` + `<script>`).
- `images/` — deal property photos named `<dealId>.png` (e.g. `images/1275.png`).

Deploying = serve `index.html` statically. Developing = open `index.html` in a browser (or any static server, e.g. `python -m http.server`). Reload after edits.

Third-party dependencies are loaded from CDNs inside `index.html`: Chart.js 4.4.1, Google Fonts (DM Serif/Mono/Sans + Manrope). There is no local `node_modules`.

## Working with index.html

Because the file is so large, Read on the full file **will fail with a token-limit error**. Always either:
- Use `Grep` to locate the line you want, then `Read` with `offset`/`limit`.
- Edit with `Edit` using unique surrounding context — targeted edits are fine, whole-file rewrites are not.

One line in particular, ~line 3061, is a **single-line ~1.5MB JSON literal** (`const PMT_DATA = {...}`) — never try to read it in full; grep into it or use it only via surrounding code.

## High-level architecture

### 1. Inline data constants (the "database")

All data lives as inline JS constants. When the user says "update the deals" or "the numbers are wrong," they almost always mean editing these:

- `RAW` (~line 1724) — primary deals array (~144 rows). Each row: `{id, name, asset, type, vintage, advance, collected, outstanding, monthlyPmt, irr, ltv, dscr, status, term, fundDate}`. Drives the Track Record table, KPIs, filters, scenarios, charts, and the cumulative-funding chart.
- `PMT_DATA` (~line 3061, single giant line) — `{tape, dpd, sched}`. Payment-level data for the Payment Analysis tab (delinquency curves, DPD drill-downs, schedules). Keyed by deal `id`.
- `MEMO` (~line 1927) — enriched qualitative memo content (strengths, risks, city, description) keyed by memo slug. Used by the deal detail side-panel (`openOP`).
- `PHOTO_MAP` / `DEAL_PHOTOS` (~line 1887 / 1924) — deal id → image path. Falls back to `images/<id>.png`, then to an emoji in `AICO` if the image 404s.
- `AICO` (~line 1881) — asset-type → emoji icon map.

### 2. Section navigation

Top nav has three groups — **Who We Are** (`firm`, `track`, `cases`), **The Opportunity** (`market`, `operate`, `whynectar`), **Invest** (`terms`, `fit`). Each section is a `<div class="dr-sec" id="sec-<id>">`. Switching is handled by `showSec(id)` (~line 3011), which toggles the `ds-active` class / `display`, sets the matching parent nav button (`SEC_PARENT` map, ~line 3005), scrolls to top, and re-renders the Track Record charts when `track` becomes visible. On `DOMContentLoaded` everything is hidden and `firm` is shown.

### 3. Track Record render pipeline

The Track Record section is the heart of the app. The flow is:

`applyFilters()` → sets `filtered = RAW filtered by dropdowns` → `renderAll()` → calls `renderKPIs()`, `renderCharts()`, `renderScenario()`, `renderTable()`, and (if the cashflow canvas is mounted) `renderCashFlow()`.

- Chart instances are cached in `let charts = {}` and torn down via `destroyChart(id)` before re-render — always destroy before re-creating to avoid Chart.js leaking canvases.
- Color palettes: `COLORS` (asset/type/vintage palette) and `TYPE_COLORS` (~line 2327/2335).
- Table pagination: `currentPage`, `PER_PAGE=20`, `sortKey`/`sortDir`. `sortTable(key)` toggles direction; `gotoPage(p)` re-renders.
- Scenarios ("base", etc.) are projected by `setScenario` / `renderScenario`, which applies a multiplier map defined inline inside `renderScenario` (~line 2481).

### 4. Deal detail side-panel

`openOP(deal)` (~line 2607) opens the right-hand panel for a row: highlights the row, looks up `MEMO[deal.id]`, resolves the image via `DEAL_PHOTOS[id] || PHOTO_MAP[id] || images/<id>.png` with an `onerror` fallback to the asset emoji. `closeOP()` tears it down. `selDeal` holds the selection.

### 5. Payment Analysis tab

Lazy-initialized: the first time `setView('payments', …)` runs, it calls `initPaymentTab()` (guarded by `paInitialized`), which calls `buildDealDropdowns()` then `renderPaymentTab()`. Chart instances live in a separate cache `paCharts` with its own `paDestroyChart(id)`.

Two main computations:
- `computeChart1(deals, delinFilter)` — delinquency buckets across payment numbers using `PMT_DATA.dpd`. Helpers: `c1Is30dpd` / `c1Is90dpd`.
- `computeChart2(deals, delinFilter)` — point-in-time DPD by observation month via `pitDpd(rec, obsYear, obsMonth)`.

Clicking a chart point opens a drill-down modal via `showDrilldown(type, key, threshold, deals)` (`type` is `'pmt'` or `'month'`), closed by `closeDrilldown()`.

### 6. Cash-flow view

`renderCashFlow()` bucketizes `RAW` into `monthlyActual` and `monthlyProj` maps using `projTotal(d)` (IRR-based projection) and renders into `#chartCFActual`. Only runs if the canvas is present in the DOM. `setView('cashflow', …)` shows/hides the container.

## Editing conventions observed in this repo

- Everything — structure, styling, data, logic — goes into `index.html`. Don't split files unless the user explicitly asks; the deployment model assumes one file.
- Brand colors are CSS variables at the top of the `<style>` block (`:root`). Use these rather than hard-coding hex values when adding UI.
- Chart.js canvases have IDs used as keys into the `charts` / `paCharts` caches. New charts should follow the same "destroy-then-create" pattern.
- To add a new deal: append to `RAW`. To add its photo, drop `images/<id>.png` (or add an entry in `PHOTO_MAP`). To add its memo content, add to `MEMO`.
- Section-level visibility is class-driven (`ds-active`) plus inline `display`. Don't rely on CSS `:target` or hash routing — there is none.
