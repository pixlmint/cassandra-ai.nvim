# Tree-sitter for AST-aware span extraction (Phase 1)
try:
    from tree_sitter import Language, Parser, Node
    HAS_TREE_SITTER = True
except ImportError:
    HAS_TREE_SITTER = False
    Parser = None
    Node = None
    Language = None

# BM25 for cross-file retrieval (Phase 3)
try:
    from rank_bm25 import BM25Okapi
    HAS_BM25 = True
except ImportError:
    HAS_BM25 = False
    BM25Okapi = None

# Transformers for accurate token counting (replaces CHARS_PER_TOKEN heuristic)
try:
    from transformers import AutoTokenizer
    HAS_TRANSFORMERS = True
except ImportError:
    HAS_TRANSFORMERS = False
    AutoTokenizer = None
