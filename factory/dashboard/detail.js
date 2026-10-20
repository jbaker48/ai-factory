// Assemble a job's acceptance criteria, plan coverage and ordered run timeline.
// Exports detail.
'use strict'
const fs = require('fs')
const path = require('path')
const { listRuns } = require('./runs')

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function readFile(dir, rel) {
  const file = path.join(dir, rel)
  try {
    if (!fs.lstatSync(file).isFile()) return null
    return fs.readFileSync(file, 'utf8')
  } catch {
    return null
  }
}

function section(text, title) {
  const lines = text.split(/\r?\n/)
  const start = lines.findIndex((line) => line === `## ${title}`)
  if (start < 0) return null
  let end = lines.length
  for (let i = start + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i])) {
      end = i
      break
    }
  }
  return lines.slice(start + 1, end).join('\n').replace(/^\n+|\n+$/g, '')
}

function criteriaFrom(markdown, jobTasks, planTasks) {
  const lines = markdown.split(/\r?\n/)
  const items = []
  let current = null
  for (const line of lines) {
    const match = line.match(/^(\d+)\. (.*)$/)
    if (match) {
      if (current) items.push(current)
      current = { n: Number(match[1]), lines: [match[2]] }
    } else if (current) {
      current.lines.push(line)
    }
  }
  if (current) items.push(current)

  return items.map((item) => {
    const text = item.lines.join('\n').replace(/\n+$/g, '')
    const tasks = []
    for (const planTask of planTasks) {
      if (!Array.isArray(planTask.covers) || !planTask.covers.includes(item.n)) continue
      const jobTask = jobTasks.find((task) => task && task.id === planTask.id)
      if (!jobTask) continue
      tasks.push({
        id: jobTask.id,
        title: jobTask.title ?? planTask.title ?? null,
        status: jobTask.status ?? null,
      })
    }
    return { n: item.n, text, tasks }
  })
}

function planData(dir, job) {
  const text = readFile(dir, 'plan.json')
  if (text === null) return { plan: null, tasks: [] }
  let plan
  try { plan = JSON.parse(text) } catch { return { plan: null, tasks: [] } }
  if (!isPlainObject(plan) || !Array.isArray(plan.tasks) || !plan.tasks.every(isPlainObject)) {
    return { plan: null, tasks: [] }
  }

  const jobTasks = Array.isArray(job.tasks) ? job.tasks : []
  const tasks = plan.tasks.map((task, index) => {
    const keyed = task.key == null ? null : jobTasks.find((item) => item && item.key === task.key)
    const mapped = keyed || jobTasks[index]
    return {
      key: task.key ?? null,
      title: task.title ?? null,
      covers: Array.isArray(task.covers) ? task.covers : [],
      id: mapped && typeof mapped.id === 'string' ? mapped.id : null,
    }
  })
  return { plan: { status: plan.status ?? null, tasks }, tasks }
}

function stampMs(stamp) {
  const match = typeof stamp === 'string' && stamp.match(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/)
  if (!match) return null
  const [, year, month, day, hour, minute, second] = match.map(Number)
  const date = new Date(year, month - 1, day, hour, minute, second)
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day ||
      date.getHours() !== hour || date.getMinutes() !== minute || date.getSeconds() !== second) return null
  return date.getTime()
}

function existsFile(dir, rel) {
  if (typeof rel !== 'string' || !rel || path.isAbsolute(rel)) return false
  const file = path.resolve(dir, rel)
  if (!file.startsWith(path.resolve(dir) + path.sep)) return false
  try { return fs.lstatSync(file).isFile() } catch { return false }
}

function outputFor(dir, run, lastApprover) {
  const candidates = []
  if (run.stage === 'spec') candidates.push('spec.md')
  if (run.stage === 'plan') candidates.push('plan.json')
  if (run.stage === 'build' && run.task) candidates.push(`build/${run.task}.md`)
  if (run.stage === 'review' && run.round != null) {
    candidates.push(`round-${run.round}/review-${run.key.slice('reviewer-'.length)}.md`)
  }
  if (run.stage === 'approve') {
    if (lastApprover) candidates.push('decision.md')
    if (run.round != null) candidates.push(`decision-round${run.round}.md`)
  }
  if (run.stage === 'autopilot' && run.decision) candidates.push(run.decision)
  if (run.last) candidates.push(run.last)
  return candidates.find((candidate) => existsFile(dir, candidate)) || null
}

function noteFiles(dir) {
  let entries
  try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch { return [] }
  return entries.filter((entry) => entry.isFile() && /^(?:rework|human|human-brief)-[^/]+\.md$/.test(entry.name))
    .map((entry) => {
      const file = path.join(dir, entry.name)
      try { return { path: entry.name, mtime: fs.statSync(file).mtimeMs } } catch { return null }
    })
    .filter(Boolean)
    .sort((a, b) => a.path.localeCompare(b.path))
}

function timeline(dir, job, usage) {
  const rawRuns = listRuns(dir, job, usage)
  const approvers = rawRuns.filter((run) => run.stage === 'approve')
  const lastApprover = approvers.at(-1) || null
  const runs = rawRuns.map((run) => ({
    ...run,
    output: outputFor(dir, run, Boolean(lastApprover && run.id === lastApprover.id)),
  }))
  const groups = []
  const assigned = new Set()
  const add = (kind, matches) => {
    const selected = runs.filter(matches)
    if (!selected.length) return
    for (const run of selected) assigned.add(run.id)
    groups.push({ kind, runs: selected })
  }

  add('spec', (run) => run.stage === 'spec')
  add('plan', (run) => run.stage === 'plan')
  const firstReview = runs.findIndex((run) => run.stage === 'review')
  add('build', (run) => run.stage === 'build' && (firstReview < 0 || runs.indexOf(run) < firstReview))

  const rounds = [...new Set(runs
    .filter((run) => (run.stage === 'review' || run.stage === 'approve') && Number.isInteger(run.round) && run.round > 0)
    .map((run) => run.round))].sort((a, b) => a - b)
  const roundRuns = new Map()
  for (const round of rounds) {
    roundRuns.set(round, runs.filter((run) => (run.stage === 'review' || run.stage === 'approve') && run.round === round))
  }

  const notes = noteFiles(dir)
  const assignedNotes = new Set()
  const betweenGroups = []
  for (let index = 0; index < rounds.length; index++) {
    const round = rounds[index]
    const members = roundRuns.get(round)
    const shown = members.filter((run) => !(lastApprover && run.id === lastApprover.id))
    for (const run of shown) assigned.add(run.id)
    if (shown.length) groups.push({ kind: 'round', round, runs: shown })

    const times = members.map((run) => stampMs(run.stamp)).filter((time) => time !== null)
    const start = times.length ? Math.max(...times) : null
    const nextMembers = index + 1 < rounds.length ? roundRuns.get(rounds[index + 1]) : []
    const nextTimes = nextMembers.map((run) => stampMs(run.stamp)).filter((time) => time !== null)
    const end = nextTimes.length ? Math.min(...nextTimes) : Infinity
    const betweenRuns = runs.filter((run) => {
      if (assigned.has(run.id) || rounds.some((number) => roundRuns.get(number).some((item) => item.id === run.id))) return false
      const time = stampMs(run.stamp)
      return start !== null && time !== null && time > start && time < end
    })
    const betweenNotes = notes.filter((note) => !assignedNotes.has(note.path) && start !== null && note.mtime > start && note.mtime < end)
    for (const note of betweenNotes) assignedNotes.add(note.path)
    if (betweenRuns.length || betweenNotes.length) {
      for (const run of betweenRuns) assigned.add(run.id)
      const group = { kind: 'between', after: round, runs: betweenRuns, notes: betweenNotes.map(({ path: notePath }) => ({ path: notePath })) }
      groups.push(group)
      betweenGroups.push(group)
    }
  }

  const unmatchedNotes = notes.filter((note) => !assignedNotes.has(note.path))
  if (unmatchedNotes.length && betweenGroups.length) {
    betweenGroups.at(-1).notes.push(...unmatchedNotes.map(({ path: notePath }) => ({ path: notePath })))
    for (const note of unmatchedNotes) assignedNotes.add(note.path)
  } else if (unmatchedNotes.length && rounds.length) {
    const lastRound = rounds.at(-1)
    const members = roundRuns.get(lastRound)
    const start = Math.max(...members.map((run) => stampMs(run.stamp)).filter((time) => time !== null))
    const afterNotes = unmatchedNotes.filter((note) => note.mtime > start)
    if (afterNotes.length) {
      const group = { kind: 'between', after: lastRound, runs: [], notes: afterNotes.map(({ path: notePath }) => ({ path: notePath })) }
      const at = groups.findIndex((item) => item.kind === 'round' && item.round === lastRound)
      groups.splice(at + 1, 0, group)
      betweenGroups.push(group)
      for (const note of afterNotes) assignedNotes.add(note.path)
    }
  }

  if (lastApprover) {
    const finalRun = runs.find((run) => run.id === lastApprover.id)
    assigned.add(finalRun.id)
    groups.push({ kind: 'approve', runs: [finalRun], output: existsFile(dir, 'decision.md') ? 'decision.md' : null })
  }

  if (job.stage === 'merged' || job.stage === 'dropped') {
    groups.push({ kind: 'merge', pr: job.pr ?? null, stage: job.stage })
  }
  return groups
}

function detail(dir, job, usage) {
  const spec = readFile(dir, 'spec.md')
  let criteria = null
  let criteriaNote = null
  let outOfScope = null
  const planDataResult = planData(dir, job)
  const jobTasks = Array.isArray(job.tasks) ? job.tasks : []
  if (spec === null) {
    criteriaNote = 'No spec yet.'
  } else {
    const acceptance = section(spec, 'Acceptance criteria')
    if (acceptance === null) criteriaNote = 'The spec has no Acceptance criteria section.'
    else criteria = criteriaFrom(acceptance, jobTasks, planDataResult.tasks)
    outOfScope = section(spec, 'Out of scope')
  }
  return {
    criteria,
    criteria_note: criteriaNote,
    out_of_scope: outOfScope,
    plan: planDataResult.plan,
    timeline: timeline(dir, job, usage),
  }
}

module.exports = { detail }
