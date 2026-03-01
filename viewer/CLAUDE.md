# FIM Dataset Viewer

Web application for browsing, filtering, and curating FIM code completion datasets. Displays JSONL examples with syntax-highlighted prefix/middle/suffix sections, supports faceted filtering, and allows accept/reject curation with batch save.

## Commands

```bash
npm run dev      # Express (port 3000) + Vite dev server (port 5173) with HMR
npm run build    # Production build → dist/
npm start        # Production — Express serves dist/ + API
```

## Tech Stack

- **Frontend**: Vue 3.5 (Composition API, `<script setup>`), Vue Router, Vite 5.4, highlight.js
- **Backend**: Node.js, Express 4.21
- **No external DB** — reads JSONL files directly with byte-offset random access

## Architecture

### Project Structure

```
viewer/
├── src/                         # Vue 3 SPA
│   ├── main.js                  # App init
│   ├── App.vue                  # Root (header + router-view)
│   ├── router.js                # 2 routes: Home, Dataset
│   ├── api.js                   # HTTP client
│   ├── views/
│   │   ├── HomeView.vue         # Dataset path input
│   │   └── DatasetView.vue      # Main browser
│   └── components/
│       ├── FilterPanel.vue      # Facet filters (span_kind, filepath, complexity)
│       ├── SearchBar.vue        # Full-text search
│       ├── DatasetOverview.vue  # Stats and feature flags
│       ├── ExampleList.vue      # Card grid
│       ├── ExampleCard.vue      # FIM example display
│       ├── CodeBlock.vue        # Syntax-highlighted code
│       └── Pagination.vue       # Page nav
└── server/                      # Express API
    ├── index.js                 # Server entry, static serving, route mounting
    ├── routes/datasets.js       # API endpoints
    └── lib/
        ├── store.js             # DatasetStore singleton (in-memory state)
        ├── indexer.js           # Byte-offset JSONL indexing
        ├── filter.js            # Metadata filtering + facet extraction
        └── reader.js            # LineReader — random-access line reads
```

### Key Patterns

**Byte-offset indexing**: `buildIndex()` scans JSONL files, stores byte offset and length per line plus lightweight metadata (span_kind, filepath, complexity_score). `LineReader` uses these for random-access reads without loading entire files into memory.

**DatasetStore singleton**: Manages open dataset path, per-file indexes/readers, pending moves, and indexing progress. Lifecycle: `.open()` → `.close()` / `.applyMoves()`.

**Optimistic curation UI**: Accept/reject actions add to `pendingMoves` immediately (visual indicators: opacity + badge). Undo removes from pending. Save commits all moves atomically, rewrites affected JSONL files, and rebuilds indexes.

### API Endpoints (all under `/api/datasets`)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/open?path=` | Load dataset directory |
| GET | `/status` | Open path, indexing status, file list |
| GET | `/metadata` | Parsed metadata.json |
| GET | `/facets?file=` | Facet counts for filtering |
| GET | `/examples?file=&page=&per_page=&...` | Paginated, filtered examples |
| GET | `/search?file=&q=` | Full-text search |
| POST | `/move` | Record pending move |
| DELETE | `/move` | Undo pending move |
| POST | `/save` | Apply pending moves to disk |

Vite dev server proxies `/api/*` to Express on port 3000.
