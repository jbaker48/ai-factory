// Builds the dashboard's ordered agent runs from .runs/ files and usage records.
// Exports STEM, stageOfKey, listRuns and derivedUsage.
'use strict'
const fs = require('fs')
const path = require('path')

const STEM = /^\d{8}-\d{6}-[a-z][a-z0-9-]*$/
const TOKEN_FIELDS = [
  ['input', 'input_tokens'],
  ['cached', 'cached_input_tokens'],
  ['output', 'output_tokens'],
  ['reasoning', 'reasoning_output_tokens'],
]

function stageOfKey(key) {
  if (key === 'spec-writer') return 'spec'
  if (key === 'planner') return 'plan'
  if (key === 'builder' || key === 'builder-escalation') return 'build'
  if (key.startsWith('reviewer-')) return 'review'
  if (key === 'approver') return 'approve'
  if (key === 'autopilot') return 'autopilot'
  if (key === 'briefer') return 'needs-human'
  if (key === 'retro') return 'retro'
  return null
}

function dateStamp(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) return null
  const pad = (n, size = 2) => String(n).padStart(size, '0')
  return `${pad(date.getFullYear(), 4)}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
}

function stampFromTs(ts) {
  if (typeof ts !== 'string' && typeof ts !== 'number') return null
  return dateStamp(new Date(ts))
}

function isoFromStamp(stamp) {
  const match = stamp.match(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/)
  if (!match) return null
  const [, year, month, day, hour, minute, second] = match.map(Number)
  const date = new Date(year, month - 1, day, hour, minute, second)
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day ||
      date.getHours() !== hour || date.getMinutes() !== minute || date.getSeconds() !== second) return null
  return date.toISOString()
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function tokensFromUsage(record) {
  return {
    input: record.input ?? null,
    cached: record.cached ?? null,
    output: record.output ?? null,
    reasoning: record.reasoning ?? null,
  }
}

function derivedTokens(dir, id) {
  let text
  try { text = fs.readFileSync(path.join(dir, '.runs', `${id}.jsonl`), 'utf8') } catch { return null }
  const totals = { input: 0, cached: 0, output: 0, reasoning: 0 }
  let found = false
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    let event
    try { event = JSON.parse(line) } catch { continue }
    if (!isPlainObject(event) || event.type !== 'turn.completed' || !isPlainObject(event.usage)) continue
    for (const [field, source] of TOKEN_FIELDS) {
      const value = event.usage[source]
      if (typeof value !== 'number' || !Number.isFinite(value)) continue
      totals[field] += value
      found = true
    }
  }
  return found ? totals : null
}

function promptDetails(dir, id) {
  let text
  try {
    const file = path.join(dir, '.runs', `${id}.prompt.md`)
    if (!fs.lstatSync(file).isFile()) throw new Error('not a regular file')
    text = fs.readFileSync(file, 'utf8')
  } catch {
    return { task: null, round: null, decision: null }
  }
  const line = text.split(/\r?\n/).map((part) => part.trim()).filter(Boolean).at(-1) || ''
  const task = line.match(/\bBuild task\s+([A-Za-z0-9][A-Za-z0-9._-]*?)\.(?=\s|$)/)
  const reviewRound = line.match(/\bReview round (\d+)\./)
  const finalRound = line.match(/\bFinal round:\s*(\d+)\./)
  const decision = line.match(/\bDecision file:\s*(.+?)\.(?=\s|$)/)
  return {
    task: task ? task[1] : null,
    round: reviewRound ? Number(reviewRound[1]) : finalRound ? Number(finalRound[1]) : null,
    decision: decision ? decision[1] : null,
  }
}

function listRuns(dir, job, usage) {
  const runsDir = path.join(dir, '.runs')
  let entries
  try { entries = fs.readdirSync(runsDir, { withFileTypes: true }) } catch { entries = [] }

  const runs = new Map()
  for (const entry of entries) {
    if (!entry.isFile()) continue
    const match = entry.name.match(/^(\d{8}-\d{6}-[a-z][a-z0-9-]*)\..+$/)
    if (!match || !STEM.test(match[1])) continue
    const id = match[1]
    if (runs.has(id)) continue
    const stamp = id.slice(0, 15)
    const key = id.slice(16)
    const details = promptDetails(dir, id)
    const promptPath = path.join(runsDir, `${id}.prompt.md`)
    const lastPath = path.join(runsDir, `${id}.last.md`)
    runs.set(id, {
      id,
      stamp,
      key,
      stage: stageOfKey(key),
      task: details.task,
      round: details.round,
      decision: details.decision,
      prompt: fs.existsSync(promptPath) ? `.runs/${id}.prompt.md` : null,
      last: fs.existsSync(lastPath) ? `.runs/${id}.last.md` : null,
      model: null,
      tokens: null,
      tokens_from: null,
    })
  }

  const assigned = new Map()
  const records = Array.isArray(usage) ? usage : []
  records.forEach((record) => {
    if (!isPlainObject(record) || typeof record.log !== 'string' || !record.log.startsWith('.runs/')) return
    const id = record.log.slice('.runs/'.length)
    if (runs.has(id) && !assigned.has(id)) assigned.set(id, record)
  })

  records.forEach((record, index) => {
    if (!isPlainObject(record)) return
    if (typeof record.log === 'string' && record.log.startsWith('.runs/')) return
    if (typeof record.role !== 'string' || !record.role) return
    const stamp = stampFromTs(record.ts)
    let candidate = null
    if (stamp) {
      for (const run of runs.values()) {
        if (run.key !== record.role || run.stamp > stamp || assigned.has(run.id)) continue
        if (!candidate || run.stamp > candidate.stamp) candidate = run
      }
    }
    if (candidate) {
      assigned.set(candidate.id, record)
      return
    }
    if (!stamp) return
    const id = `usage-${index}`
    const run = {
      id,
      stamp,
      key: record.role,
      stage: stageOfKey(record.role),
      task: record.task ?? null,
      round: record.round ?? null,
      decision: null,
      prompt: null,
      last: null,
      model: record.model ?? null,
      tokens: tokensFromUsage(record),
      tokens_from: 'usage',
    }
    runs.set(id, run)
  })

  for (const [id, record] of assigned) {
    const run = runs.get(id)
    const details = promptDetails(dir, id)
    run.task = details.task ?? record.task ?? null
    run.round = details.round ?? record.round ?? null
    run.model = record.model ?? null
    run.tokens = tokensFromUsage(record)
    run.tokens_from = 'usage'
  }

  for (const run of runs.values()) {
    if (run.tokens_from) continue
    const tokens = derivedTokens(dir, run.id)
    if (tokens) {
      run.tokens = tokens
      run.tokens_from = 'derived'
    }
  }

  const ordered = [...runs.values()].sort((a, b) => a.stamp.localeCompare(b.stamp) || a.key.localeCompare(b.key))
  let priorReviewRound = null
  for (const run of ordered) {
    if (run.stage !== 'review') continue
    if (run.round == null && priorReviewRound != null) run.round = priorReviewRound
    if (run.round != null) priorReviewRound = run.round
  }
  return ordered
}

function derivedUsage(dir, job) {
  if (fs.existsSync(path.join(dir, 'usage.jsonl'))) return []
  return listRuns(dir, job, [])
    .filter((run) => run.tokens_from === 'derived')
    .map((run) => ({
      ts: isoFromStamp(run.stamp),
      role: run.key,
      stage: run.stage,
      round: run.round,
      task: run.task,
      input: run.tokens.input,
      cached: run.tokens.cached,
      output: run.tokens.output,
      reasoning: run.tokens.reasoning,
      model: null,
      log: `.runs/${run.id}`,
      derived: true,
    }))
    .filter((record) => record.ts !== null)
}

module.exports = { STEM, stageOfKey, listRuns, derivedUsage }
