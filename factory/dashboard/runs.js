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
const derivedTokenCache = new Map()

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

function stampTime(stamp) {
  const match = typeof stamp === 'string' && stamp.match(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/)
  if (!match) return null
  const [, year, month, day, hour, minute, second] = match.map(Number)
  const date = new Date(year, month - 1, day, hour, minute, second)
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day ||
      date.getHours() !== hour || date.getMinutes() !== minute || date.getSeconds() !== second) return null
  return date.getTime()
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

function hasTokenSource(record) {
  return TOKEN_FIELDS.some(([field]) => typeof record[field] === 'number' && Number.isFinite(record[field]))
}

function derivedTokens(dir, id) {
  const file = path.resolve(dir, '.runs', `${id}.jsonl`)
  let stat
  try {
    stat = fs.statSync(file)
    if (!stat.isFile()) throw new Error('not a regular file')
  } catch {
    derivedTokenCache.delete(file)
    return null
  }
  const cached = derivedTokenCache.get(file)
  if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) {
    return cached.tokens ? { ...cached.tokens } : null
  }

  let text
  try { text = fs.readFileSync(file, 'utf8') } catch {
    derivedTokenCache.delete(file)
    return null
  }
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
  const tokens = found ? totals : null
  derivedTokenCache.set(file, { mtimeMs: stat.mtimeMs, size: stat.size, tokens })
  return tokens ? { ...tokens } : null
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
      tokens: hasTokenSource(record) ? tokensFromUsage(record) : null,
      tokens_from: hasTokenSource(record) ? 'usage' : null,
    }
    runs.set(id, run)
  })

  for (const [id, record] of assigned) {
    const run = runs.get(id)
    const details = promptDetails(dir, id)
    run.task = details.task ?? record.task ?? null
    run.round = details.round ?? record.round ?? null
    run.model = record.model ?? null
    run.tokens = hasTokenSource(record) ? tokensFromUsage(record) : null
    run.tokens_from = hasTokenSource(record) ? 'usage' : null
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
  const parsedReviewRuns = ordered
    .map((run, index) => ({ run, index, time: stampTime(run.stamp) }))
    .filter(({ run, time }) => run.stage === 'review' && Number.isInteger(run.round) && run.round > 0 && time !== null)
  for (const run of ordered) {
    if (run.stage !== 'review' || run.round != null) continue
    const time = stampTime(run.stamp)
    if (time === null) continue
    let nearest = null
    for (const candidate of parsedReviewRuns) {
      const distance = Math.abs(candidate.time - time)
      if (!nearest || distance < nearest.distance ||
          (distance === nearest.distance && candidate.time > nearest.candidate.time) ||
          (distance === nearest.distance && candidate.time === nearest.candidate.time && candidate.index > nearest.candidate.index)) {
        nearest = { candidate, distance }
      }
    }
    if (nearest) run.round = nearest.candidate.run.round
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
