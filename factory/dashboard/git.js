// Read task commits and job changes without modifying the repository.
// Usage: changes(repo, id, job, base) and diff(repo, id, job, selector, base).
// Exports changes and diff.
'use strict'
const { execFile } = require('child_process')

const DIFF_CAP = (() => {
  const configured = Number(process.env.FACTORY_DASHBOARD_DIFF_CAP)
  return Number.isInteger(configured) && configured > 0 ? configured : 2 * 1024 * 1024
})()
const METADATA_CAP = 16 * 1024 * 1024

function run(repo, args, maxBuffer = METADATA_CAP) {
  return new Promise((resolve, reject) => {
    execFile('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer }, (error, stdout, stderr) => {
      if (!error) return resolve({ code: 0, stdout, stderr, overflow: false })
      if (error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') {
        return resolve({ code: 0, stdout: stdout || error.stdout || '', stderr, overflow: true })
      }
      if (typeof error.code === 'number') return resolve({ code: error.code, stdout, stderr, overflow: false })
      reject(error)
    })
  })
}

function checked(result) {
  if (result.overflow) throw new Error('git output exceeded the metadata limit')
  if (result.code !== 0) throw new Error((result.stderr || '').trim() || 'git command failed')
  return result.stdout
}

function parseLog(text) {
  return text.split('\n').filter(Boolean).map((line) => {
    const split = line.indexOf('\x1f')
    return split < 0 ? null : { commit: line.slice(0, split), subject: line.slice(split + 1) }
  }).filter(Boolean)
}

function taskIds(job) {
  return Array.isArray(job.tasks)
    ? job.tasks.filter((task) => task && typeof task.id === 'string').map((task) => task.id)
    : []
}

async function resolve(repo, ref) {
  const result = await run(repo, ['log', '-1', '--format=%H', ref, '--'])
  if (result.code !== 0) return null
  return result.stdout.trim().split('\n')[0] || null
}

async function jobRef(repo, id) {
  const refs = [
    ['branch', `refs/heads/factory/${id}`],
    ['bookmark', `refs/factory/jobs/${id}`],
    ['remote', `refs/remotes/origin/factory/${id}`],
  ]
  for (const [source, ref] of refs) {
    const commit = await resolve(repo, ref)
    if (commit) return { source, ref, commit }
  }
  return null
}

async function taskCommits(repo, ref, job) {
  const log = checked(await run(repo, ['log', '--format=%H%x1f%s', '-n', '1000', ref, '--']))
  const commits = parseLog(log)
  const found = Object.create(null)
  for (const id of taskIds(job)) {
    const match = commits.find((item) => item.subject.endsWith(`(${id})`))
    if (match) found[id] = match
  }
  return found
}

function landingMatchers(id, job) {
  const pr = typeof job.pr === 'string' && job.pr.match(/(\d+)\s*$/)
  return {
    pr: pr ? `(#${pr[1]})` : null,
    merge: `Merge branch 'factory/${id}'`,
    bead: typeof job.bead === 'string' && job.bead ? `${job.bead}: ` : null,
  }
}

async function landingCommit(repo, base, id, job) {
  if (!(await resolve(repo, base))) return null
  const commits = parseLog(checked(await run(repo, ['log', '--format=%H%x1f%s', '-n', '5000', base, '--'])))
  const matchers = landingMatchers(id, job)
  if (matchers.pr) {
    const match = commits.find((item) => item.subject.endsWith(matchers.pr))
    if (match) return match
  }
  const merge = commits.find((item) => item.subject === matchers.merge)
  if (merge) return merge
  if (matchers.bead) return commits.find((item) => item.subject.startsWith(matchers.bead)) || null
  return null
}

function parseCount(value) {
  return value === '-' ? null : Number(value)
}

function numstat(text) {
  return text.split('\n').filter(Boolean).map((line) => {
    const first = line.indexOf('\t')
    const second = line.indexOf('\t', first + 1)
    if (first < 0 || second < 0) return null
    return {
      path: line.slice(second + 1),
      added: parseCount(line.slice(0, first)),
      removed: parseCount(line.slice(first + 1, second)),
    }
  }).filter(Boolean)
}

function totals(files) {
  return files.reduce((out, file) => {
    if (file.added !== null) out.added += file.added
    if (file.removed !== null) out.removed += file.removed
    return out
  }, { added: 0, removed: 0 })
}

async function showNumstat(repo, commit) {
  const args = ['show', '--numstat', '--format=', '--no-ext-diff', '--no-color', commit]
  return numstat(checked(await run(repo, args)))
}

async function diffNumstat(repo, args) {
  const full = ['diff', '--numstat', '--no-ext-diff', '--no-color', ...args]
  return numstat(checked(await run(repo, full)))
}

async function inspect(repo, id, job, base) {
  const ref = await jobRef(repo, id)
  const tasks = ref ? await taskCommits(repo, ref.ref, job) : Object.create(null)
  let landing = null
  if (job.stage === 'merged') landing = await landingCommit(repo, base, id, job)
  return { base, ref, tasks, landing }
}

function emptyChanges() {
  return {
    source: null,
    tasks: {},
    job: { kind: null, commit: null, files: [], added: 0, removed: 0 },
  }
}

async function changes(repo, id, job, base) {
  const found = await inspect(repo, id, job, base)
  const out = emptyChanges()
  if (found.ref) out.source = found.ref.source
  for (const [taskId, commit] of Object.entries(found.tasks)) {
    out.tasks[taskId] = {
      commit: commit.commit,
      subject: commit.subject,
      files: await showNumstat(repo, commit.commit),
    }
  }

  let files = null
  if (job.stage === 'merged' && found.landing) {
    out.job.kind = 'landing'
    out.job.commit = found.landing.commit
    files = await diffNumstat(repo, [`${found.landing.commit}^1`, found.landing.commit])
  } else if (job.stage !== 'merged' && found.ref && await resolve(repo, found.base)) {
    out.job.kind = 'branch'
    out.job.commit = found.ref.commit
    files = await diffNumstat(repo, [`${found.base}...${found.ref.ref}`])
  }
  if (files) {
    out.job.files = files
    Object.assign(out.job, totals(files))
  }
  return out
}

function result(status, text, truncated = false) {
  return { status, text, truncated }
}

function diffCapLabel() {
  return Number((DIFF_CAP / (1024 * 1024)).toPrecision(3)).toString()
}

async function diffText(repo, args) {
  const full = [...args]
  const output = await run(repo, full, DIFF_CAP + 1)
  if (output.code !== 0) throw new Error((output.stderr || '').trim() || 'git command failed')
  const text = output.stdout || ''
  const bytes = Buffer.from(text, 'utf8')
  if (!output.overflow && bytes.length <= DIFF_CAP) return result(200, text)
  const cut = bytes.subarray(0, DIFF_CAP).toString('utf8')
  return result(200, `${cut}\n… diff truncated at ${diffCapLabel()} MB\n`, true)
}

async function diff(repo, id, job, selector = {}, base) {
  const hasTask = selector.task !== undefined && selector.task !== null
  const hasCommit = selector.commit !== undefined && selector.commit !== null
  if (hasTask && hasCommit) return result(400, 'Choose either task or commit')

  if (hasTask && !taskIds(job).includes(selector.task)) return result(400, 'Unknown task id')
  if (hasCommit && !/^[0-9a-f]{7,40}$/.test(selector.commit)) return result(400, 'Invalid commit')

  const found = await inspect(repo, id, job, base)
  if (hasTask) {
    const task = found.tasks[selector.task]
    if (!task) return result(404, 'Task commits are no longer available for this job')
    return diffText(repo, ['show', '--format=', '--no-ext-diff', '--no-color', task.commit])
  }

  if (hasCommit) {
    const candidates = [...Object.values(found.tasks).map((item) => item.commit)]
    if (found.landing) candidates.push(found.landing.commit)
    const commit = candidates.find((candidate) => candidate.startsWith(selector.commit))
    if (!commit) return result(404, 'Commit is not part of this job')
    return diffText(repo, ['show', '--format=', '--no-ext-diff', '--no-color', commit])
  }

  if (job.stage === 'merged' && found.landing) {
    return diffText(repo, ['diff', '--no-ext-diff', '--no-color', `${found.landing.commit}^1`, found.landing.commit])
  }
  if (job.stage !== 'merged' && found.ref && await resolve(repo, found.base)) {
    return diffText(repo, ['diff', '--no-ext-diff', '--no-color', `${found.base}...${found.ref.ref}`])
  }
  return result(404, 'No diff for this job yet')
}

module.exports = { changes, diff }
