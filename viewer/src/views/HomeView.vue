<template>
  <div class="home">
    <div class="home-card">
      <h1>Open Dataset</h1>
      <p class="subtitle">Enter the path to a FIM dataset directory (containing train.jsonl + metadata.json)</p>
      <form @submit.prevent="openDataset" class="open-form">
        <input
          v-model="path"
          type="text"
          placeholder="/path/to/.dataset/"
          class="path-input"
          autofocus
        />
        <button type="submit" :disabled="loading" class="open-btn">
          {{ loading ? 'Opening...' : 'Open' }}
        </button>
      </form>
      <p v-if="error" class="error">{{ error }}</p>

      <div v-if="recentPaths.length" class="recent">
        <h3>Recent</h3>
        <button
          v-for="p in recentPaths"
          :key="p"
          class="recent-btn"
          @click="path = p; openDataset()"
        >{{ p }}</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { api } from '../api.js'

const router = useRouter()
const path = ref('')
const loading = ref(false)
const error = ref('')
const recentPaths = ref([])

onMounted(() => {
  const saved = localStorage.getItem('fim-viewer-recent')
  if (saved) recentPaths.value = JSON.parse(saved)
})

async function openDataset() {
  if (!path.value.trim()) return
  loading.value = true
  error.value = ''
  try {
    await api.open(path.value.trim())
    // Save to recent
    const recent = recentPaths.value.filter(p => p !== path.value.trim())
    recent.unshift(path.value.trim())
    recentPaths.value = recent.slice(0, 5)
    localStorage.setItem('fim-viewer-recent', JSON.stringify(recentPaths.value))
    router.push({ path: '/dataset', query: { path: path.value.trim() } })
  } catch (err) {
    error.value = err.message
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
.home {
  display: flex;
  justify-content: center;
  padding: 80px 20px;
}
.home-card {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 40px;
  max-width: 600px;
  width: 100%;
}
h1 { margin-bottom: 8px; }
.subtitle { color: var(--text-muted); margin-bottom: 20px; }
.open-form { display: flex; gap: 8px; }
.path-input { flex: 1; }
.open-btn {
  background: var(--accent);
  border-color: var(--accent);
  color: white;
  font-weight: 600;
}
.open-btn:hover { opacity: 0.9; }
.error { color: var(--accent); margin-top: 12px; }
.recent { margin-top: 24px; }
.recent h3 { color: var(--text-muted); margin-bottom: 8px; font-size: 14px; }
.recent-btn {
  display: block;
  width: 100%;
  text-align: left;
  padding: 8px 12px;
  margin-bottom: 4px;
  font-family: monospace;
  font-size: 13px;
}
</style>
