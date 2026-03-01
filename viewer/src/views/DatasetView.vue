<template>
  <div class="dataset-layout">
    <aside class="sidebar">
      <FilterPanel
        :facets="facets"
        :filters="filters"
        @update:filters="onFiltersUpdate"
      />
    </aside>
    <main class="main-content">
      <DatasetOverview v-if="metadata" :metadata="metadata" :files="files" :activeFile="activeFile" @selectFile="selectFile" />

      <SearchBar v-model="searchQuery" @search="doSearch" />

      <div v-if="loading" class="loading">Loading...</div>

      <template v-if="!loading && examples.length">
        <ExampleList
          :examples="examples"
          :language="metadata?.language || 'python'"
          :activeFile="activeFile"
          :pendingMoves="pendingMoves"
          @move="onMove"
          @undo="onUndo"
        />
        <Pagination
          :page="page"
          :totalPages="totalPages"
          :total="total"
          @update:page="goToPage"
        />
      </template>

      <div v-if="!loading && !examples.length && hasLoaded" class="empty">
        No examples found.
      </div>

      <button v-if="pendingCount > 0" class="save-fab" @click="onSave">
        Save {{ pendingCount }} change{{ pendingCount === 1 ? '' : 's' }}
      </button>
    </main>
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { api } from '../api.js'
import FilterPanel from '../components/FilterPanel.vue'
import DatasetOverview from '../components/DatasetOverview.vue'
import SearchBar from '../components/SearchBar.vue'
import ExampleList from '../components/ExampleList.vue'
import Pagination from '../components/Pagination.vue'

const router = useRouter()
const route = useRoute()
const metadata = ref(null)
const files = ref([])
const activeFile = ref('train.jsonl')
const facets = ref({ span_kinds: [], filepaths: [], complexity_range: { min: 0, max: 0 } })
const filters = reactive({ span_kinds: [], filepath: '', complexity_min: null, complexity_max: null })
const examples = ref([])
const page = ref(1)
const totalPages = ref(0)
const total = ref(0)
const loading = ref(false)
const hasLoaded = ref(false)
const searchQuery = ref('')
const pendingMoves = ref({}) // keyed by "sourceFile:index"
const pendingCount = computed(() => Object.keys(pendingMoves.value).length)

async function initDataset(queryPath) {
  try {
    let status = await api.status()

    // Open the requested dataset if not open or if a different one is requested
    if (queryPath && (!status.open || status.path !== queryPath)) {
      await api.open(queryPath)
      status = await api.status()
    }

    if (!status.open) {
      router.push('/')
      return
    }

    // Ensure the URL reflects the open dataset path
    if (status.path && status.path !== queryPath) {
      router.replace({ path: '/dataset', query: { path: status.path } })
    }

    metadata.value = await api.metadata()
    // Try to get file list from status (includes reject.jsonl), fall back to metadata
    if (status.files) {
      files.value = status.files
    } else {
      files.value = []
      if (metadata.value.train_examples) files.value.push({ name: 'train.jsonl', examples: metadata.value.train_examples })
      if (metadata.value.val_examples) files.value.push({ name: 'val.jsonl', examples: metadata.value.val_examples })
    }
    // Reset view state for new dataset
    activeFile.value = 'train.jsonl'
    page.value = 1
    searchQuery.value = ''
    Object.assign(filters, { span_kinds: [], filepath: '', complexity_min: null, complexity_max: null })
    pendingMoves.value = {}
    await loadFacets()
    await loadExamples()
  } catch {
    router.push('/')
  }
}

onMounted(() => initDataset(route.query.path))

watch(() => route.query.path, (newPath, oldPath) => {
  if (newPath !== oldPath) initDataset(newPath)
})

async function loadFacets() {
  facets.value = await api.facets(activeFile.value)
}

async function loadExamples() {
  loading.value = true
  try {
    const params = {
      file: activeFile.value,
      page: page.value,
      per_page: 20,
    }
    if (filters.span_kinds.length) params.span_kinds = filters.span_kinds.join(',')
    if (filters.filepath) params.filepath = filters.filepath
    if (filters.complexity_min != null) params.complexity_min = filters.complexity_min
    if (filters.complexity_max != null) params.complexity_max = filters.complexity_max

    let data
    if (searchQuery.value) {
      data = await api.search({ ...params, q: searchQuery.value })
    } else {
      data = await api.examples(params)
    }
    examples.value = data.examples
    totalPages.value = data.total_pages
    total.value = data.total
    hasLoaded.value = true
  } finally {
    loading.value = false
  }
}

function selectFile(f) {
  activeFile.value = f
  page.value = 1
  loadFacets()
  loadExamples()
}

function onFiltersUpdate(newFilters) {
  Object.assign(filters, newFilters)
  page.value = 1
  loadExamples()
}

function goToPage(p) {
  page.value = p
  loadExamples()
}

function doSearch() {
  page.value = 1
  loadExamples()
}

async function onMove({ sourceFile, index, destFile }) {
  const key = `${sourceFile}:${index}`
  pendingMoves.value = { ...pendingMoves.value, [key]: { sourceFile, index, destFile } }
  await api.move(sourceFile, index, destFile)
}

async function onUndo({ sourceFile, index }) {
  const key = `${sourceFile}:${index}`
  const copy = { ...pendingMoves.value }
  delete copy[key]
  pendingMoves.value = copy
  await api.undoMove(sourceFile, index)
}

async function onSave() {
  const result = await api.save()
  pendingMoves.value = {}
  if (result.files) {
    files.value = result.files
  }
  await loadFacets()
  await loadExamples()
}
</script>

<style scoped>
.dataset-layout {
  display: grid;
  grid-template-columns: 260px 1fr;
  min-height: calc(100vh - 49px);
}
.sidebar {
  background: var(--bg-sidebar);
  border-right: 1px solid var(--border);
  padding: 16px;
  overflow-y: auto;
}
.main-content {
  padding: 20px 24px;
  overflow-y: auto;
  position: relative;
}
.loading {
  color: var(--text-muted);
  padding: 40px;
  text-align: center;
}
.empty {
  color: var(--text-muted);
  padding: 40px;
  text-align: center;
}
.save-fab {
  position: fixed;
  bottom: 24px;
  right: 24px;
  padding: 12px 24px;
  background: #3fb950;
  color: #fff;
  border: none;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  z-index: 100;
  transition: background 0.15s;
}
.save-fab:hover {
  background: #2ea043;
}
</style>
