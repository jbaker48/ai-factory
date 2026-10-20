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
  const start = lines.findIndex((line) => new RegExp(`^##[ \\t]+${title}[ \\t]*$`, 'i').test(line))
  if (start < 0) return null
  let end = lines.length
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##[ \t]+/.test(lines[i])) {
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

  const addFileStage = (kind, stage, output) => {
    const selected = runs.filter((run) => run.stage === stage)
    const hasOutput = existsFile(dir, output)
    if (!selected.length && !hasOutput) return
    for (const run of selected) assigned.add(run.id)
    const group = { kind, runs: selected }
    if (hasOutput) group.output = output
    groups.push(group)
  }

  addFileStage('spec', 'spec', 'spec.md')
  addFileStage('plan', 'plan', 'plan.json')
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
  const roundInfo = rounds.map((round) => {
    const members = roundRuns.get(round)
    const times = members.map((run) => stampMs(run.stamp)).filter((time) => time !== null)
    return { round, members, start: times.length ? Math.min(...times) : null, end: times.length ? Math.max(...times) : null }
  })
  const gaps = []
  if (roundInfo.length && roundInfo[0].start !== null) {
    gaps.push({ after: 0, lower: null, upper: roundInfo[0].start, runs: [], notes: [] })
  }
  for (let index = 0; index < roundInfo.length; index++) {
    const current = roundInfo[index]
    if (current.end === null) continue
    const next = roundInfo[index + 1]
    gaps.push({
      after: current.round,
      lower: current.end,
      upper: next && next.start !== null ? next.start : Infinity,
      runs: [],
      notes: [],
    })
  }

  const distanceToGap = (time, gap) => {
    if (gap.lower !== null && time < gap.lower) return gap.lower - time
    if (gap.upper !== Infinity && time > gap.upper) return time - gap.upper
    return 0
  }
  const matchingGap = (time, gap) => {
    if (gap.lower === null) return time < gap.upper
    return time > gap.lower && time < gap.upper
  }
  const nearestGap = (time) => gaps.reduce((nearest, gap, index) => {
    const distance = distanceToGap(time, gap)
    if (!nearest || distance < nearest.distance || (distance === nearest.distance && index > nearest.index)) {
      return { gap, index, distance }
    }
    return nearest
  }, null)?.gap || null

  const roundMemberIds = new Set(rounds.flatMap((round) => roundRuns.get(round).map((run) => run.id)))
  for (const run of runs) {
    if (assigned.has(run.id) || roundMemberIds.has(run.id) || (lastApprover && run.id === lastApprover.id)) continue
    const time = stampMs(run.stamp)
    if (time === null || !gaps.length) continue
    const gap = gaps.find((candidate) => matchingGap(time, candidate)) || nearestGap(time)
    if (gap) gap.runs.push(run)
  }
  for (const note of notes) {
    const gap = gaps.find((candidate) => candidate.after !== 0 && candidate.upper !== Infinity && matchingGap(note.mtime, candidate))
    if (gap) {
      gap.notes.push(note)
      assignedNotes.add(note.path)
    }
  }

  const emitGap = (gap) => {
    if (!gap || (!gap.runs.length && !gap.notes.length)) return
    for (const run of gap.runs) assigned.add(run.id)
    const group = {
      kind: 'between',
      after: gap.after,
      runs: gap.runs,
      notes: gap.notes.map(({ path: notePath }) => ({ path: notePath })),
    }
    groups.push(group)
    betweenGroups.push({ group, gap })
    for (const note of gap.notes) assignedNotes.add(note.path)
  }

  let gapIndex = 0
  for (let index = 0; index < roundInfo.length; index++) {
    if (index === 0 && gaps[0] && gaps[0].after === 0) emitGap(gaps[gapIndex++])
    const { round, members } = roundInfo[index]
    const shown = members.filter((run) => !(lastApprover && run.id === lastApprover.id))
    for (const run of shown) assigned.add(run.id)
    if (shown.length) groups.push({ kind: 'round', round, runs: shown })
    const gap = gaps[gapIndex]
    if (gap && gap.after === round) emitGap(gaps[gapIndex++])
  }

  const unmatchedNotes = notes.filter((note) => !assignedNotes.has(note.path))
  for (const note of unmatchedNotes) {
    if (!betweenGroups.length) break
    const nearest = betweenGroups.reduce((current, candidate, index) => {
      const distance = distanceToGap(note.mtime, candidate.gap)
      if (!current || distance < current.distance || (distance === current.distance && index > current.index)) {
        return { ...candidate, index, distance }
      }
      return current
    }, null)
    nearest.group.notes.push({ path: note.path })
    assignedNotes.add(note.path)
  }

  const otherRuns = runs.filter((run) => !assigned.has(run.id) && !(lastApprover && run.id === lastApprover.id))
  const otherNotes = notes.filter((note) => !assignedNotes.has(note.path))
  if (otherRuns.length || otherNotes.length) {
    for (const run of otherRuns) assigned.add(run.id)
    for (const note of otherNotes) assignedNotes.add(note.path)
    groups.push({ kind: 'other', runs: otherRuns, notes: otherNotes.map(({ path: notePath }) => ({ path: notePath })) })
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
