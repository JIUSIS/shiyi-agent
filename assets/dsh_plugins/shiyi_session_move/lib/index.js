// shiyi-session-move: HOST half.
// Cross-workspace session move for 拾忆. Official DSH freezes header.cwd,
// so insertSessionBefore cannot move a session to another folder.
// Adapted from dsh-session-move (MIT): rewrite zstd header cwd, relocate
// the log directory, then detach/attach via workspaceRegistry.
//
// POST /__shiyi/move-session  {sessionId, workspaceId}

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { promisify } from "node:util";
import { constants, zstdCompress, zstdDecompress } from "node:zlib";

const name = "shiyi-session-move";
const inject = ["sessions"];
const zstdCompressAsync = promisify(zstdCompress)
const zstdDecompressAsync = promisify(zstdDecompress)
const CHECKSUM_OPTIONS = { params: { [constants.ZSTD_c_checksumFlag]: 1 } }
const ZSTD_MAGIC = 0xfd2fb528

const SESSION_ID_RE = /^(session-)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function parseHeaderRecord(text) {
  const raw = String(text).replace(/^\uFEFF/, '')
  const line = raw.split(/\r?\n/).find((item) => item.trim().length > 0) ?? ''
  try {
    return JSON.parse(line)
  } catch (error) {
    try {
      return JSON.parse(raw)
    } catch {
      throw error
    }
  }
}

class MoveError extends Error {
  constructor(message, status = 400) {
    super(message)
    this.status = status
  }
}

// --- path helpers ------------------------------------------------------------

function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
}

function sessionsRoot() {
  return path.join(dshHome(), 'sessions')
}

// Reproduce the JSONL backend's projectKey() slug encoding so the session
// directory can be located/moved without depending on the internal package.
// Separators become '-'; unsafe code units become ~XXXX (uppercase hex);
// leading '-' runs are stripped; the result is wrapped in '--...--'.
function projectKey(cwd) {
  if (!cwd || cwd.length === 0) throw new Error('cannot encode an empty project path')
  let readable = ''
  let separatorRun = false
  for (let i = 0; i < cwd.length; i++) {
    const code = cwd.charCodeAt(i)
    const ch = String.fromCharCode(code)
    if (ch === '/' || ch === '\\' || ch === ':') {
      if (!separatorRun) readable += '-'
      separatorRun = true
    } else if (ch !== '~' && /^[A-Za-z0-9._-]$/.test(ch)) {
      readable += ch
      separatorRun = false
    } else {
      readable += '~' + code.toString(16).toUpperCase().padStart(4, '0')
      separatorRun = false
    }
  }
  const slug = readable.replace(/^-+/, '') || 'root'
  return `--${slug.slice(0, 251)}--`
}

// Session ids appear in two spellings in different stores (raw uuid and
// `session-<uuid>`); try both when scanning for on-disk directories.
function sessionIdVariants(sessionId) {
  const variants = new Set([sessionId])
  if (sessionId.startsWith('session-')) {
    variants.add(sessionId.slice('session-'.length))
  } else if (SESSION_ID_RE.test(sessionId)) {
    variants.add(`session-${sessionId}`)
  }
  return [...variants]
}

// Locate every on-disk session directory across all slug folders.
function findSessionDirs(sessionId) {
  const root = sessionsRoot()
  const variants = sessionIdVariants(sessionId)
  let entries = []
  try {
    entries = fs.readdirSync(root, { withFileTypes: true })
  } catch {
    return []
  }
  const found = []
  for (const e of entries) {
    if (!e.isDirectory()) continue
    for (const variant of variants) {
      const candidate = path.join(root, e.name, variant)
      try {
        if (fs.statSync(candidate).isDirectory() && !found.includes(candidate)) found.push(candidate)
      } catch { /* keep scanning */ }
    }
  }
  return found
}

// --- zstd frame helpers (concatenated-frame container, like the backend) -----

// Structurally scan complete zstd frames; EOF inside the final frame is
// reported via tornStart (not needed for our read-modify-write path, but
// kept for safety when patching the first frame).
function scanZstdFrames(buffer) {
  const frames = []
  let offset = 0
  while (offset < buffer.length) {
    const start = offset
    if (buffer.length - offset < 4) return frames
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) {
      throw new Error(`corrupt zstd session log: invalid frame magic at byte ${offset}`)
    }
    offset += 4
    if (offset === buffer.length) return frames
    const descriptor = buffer.readUInt8(offset)
    offset += 1
    if ((descriptor & 0x18) !== 0) {
      throw new Error(`corrupt zstd session log: reserved frame-header bit at byte ${offset - 1}`)
    }
    const contentSizeFlag = descriptor >>> 6
    const singleSegment = (descriptor & 0x20) !== 0
    const checksum = (descriptor & 0x04) !== 0
    const dictionaryFlag = descriptor & 0x03
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes
    if (buffer.length - offset < remainingHeaderBytes) return frames
    offset += remainingHeaderBytes
    for (;;) {
      if (buffer.length - offset < 3) return frames
      const blockHeader = buffer.readUIntLE(offset, 3)
      offset += 3
      const lastBlock = (blockHeader & 1) !== 0
      const blockType = (blockHeader >>> 1) & 0x03
      const blockSize = blockHeader >>> 3
      if (blockType === 0x03) throw new Error('corrupt zstd session log: reserved block type')
      const payloadBytes = blockType === 0x01 ? 1 : blockSize
      if (buffer.length - offset < payloadBytes) return frames
      offset += payloadBytes
      if (lastBlock) break
    }
    if (checksum) {
      if (buffer.length - offset < 4) return frames
      offset += 4
    }
    frames.push({ start, end: offset })
  }
  return frames
}

// Read the session header line: decompress the first frame, parse its JSON.
async function readSessionHeader(sessionDirPath) {
  const file = path.join(sessionDirPath, 'session.jsonl.zstd')
  if (!fs.existsSync(file)) {
    // Plaintext fallback (compression: none) — just in case.
    const plain = path.join(sessionDirPath, 'session.jsonl')
    if (fs.existsSync(plain)) {
      const first = fs.readFileSync(plain, 'utf8')
      return { header: parseHeaderRecord(first), frameBytes: null, frameIndex: [] }
    }
    throw new MoveError(`session log not found in ${sessionDirPath}`, 500)
  }
  const bytes = fs.readFileSync(file)
  const frames = scanZstdFrames(bytes)
  if (frames.length === 0) throw new MoveError(`cannot locate header frame of ${file}`, 500)
  const first = bytes.subarray(frames[0].start, frames[0].end)
  const plaintext = await zstdDecompressAsync(first)
  return { header: parseHeaderRecord(plaintext.toString('utf8')), frameBytes: first, frameIndex: frames }
}

// Patch the header line's cwd and rewrite the artifact: new first frame
// (recompressed) + untouched trailing frames. The header line is JSONL: it
// MUST end with '\n' (the backend's parseHeaderRecord requires the last byte
// to be 0x0A), so serialize with a trailing newline exactly like the
// original writer.
async function rewriteHeaderCwd(sessionDirPath, header, firstFrameBytes, frames, newCwd) {
  const patched = { ...header, cwd: newCwd }
  const line = `${JSON.stringify(patched)}\n`
  const zstdFile = path.join(sessionDirPath, 'session.jsonl.zstd')
  const plainFile = path.join(sessionDirPath, 'session.jsonl')
  if (!firstFrameBytes || !fs.existsSync(zstdFile)) {
    if (!fs.existsSync(plainFile)) throw new Error(`session log not found in ${sessionDirPath}`)
    const text = fs.readFileSync(plainFile, 'utf8')
    const nl = text.search(/\r?\n/)
    const remainder = nl === -1 ? '' : text.slice(nl).replace(/^\r?\n/, '')
    const out = remainder ? line + remainder : line
    const tmp = `${plainFile}.move-tmp-${process.pid}`
    fs.writeFileSync(tmp, out)
    fs.renameSync(tmp, plainFile)
    return
  }
  const newFirst = await zstdCompressAsync(line, CHECKSUM_OPTIONS)
  const bytes = fs.readFileSync(zstdFile)
  const trailing = frames.slice(1).map((f) => bytes.subarray(f.start, f.end))
  const out = Buffer.concat([newFirst, ...trailing])
  const tmp = `${zstdFile}.move-tmp-${process.pid}`
  fs.writeFileSync(tmp, out)
  fs.renameSync(tmp, zstdFile)
}

// --- storage helpers ---------------------------------------------------------

// Stop a live agent before anything moves (cancel + bounded quiescence).
async function stopAgentIfRunning(ctx, sessionId) {
  const agents = ctx.get('agents')
  if (!agents || typeof agents.get !== 'function') return false
  const agent = agents.get(sessionId)
  if (!agent) return false
  if (typeof agent.cancel === 'function') {
    try { agent.cancel({ kind: 'user' }) } catch { /* already settling */ }
  }
  if (typeof agent.whenIdle === 'function') {
    try {
      await Promise.race([
        agent.whenIdle(),
        new Promise((resolve) => setTimeout(resolve, 15000)),
      ])
    } catch { /* proceed anyway */ }
  }
  return true
}

// Release the live agent from the agents registry so the host stops reporting
// the session as running and — crucially — any later re-open of the moved
// session does not hang. The agent factory's waitForDrainingConfiguredIdentity
// waits for BOTH the session AND the agent to leave their registries (it
// listens for `session/disposed` and `agent/disposed`) before rebuilding a
// live session; cancelling the turn alone leaves the agent registered, so the
// wait never resolves and the moved session can never be re-opened/resumed.
// Mirrors detachLiveSession for the sessions store (same posture as the
// delete plugin). No-op when the session is already cold.
function releaseAgentIfLive(ctx, sessionId) {
  const agents = ctx.get('agents')
  if (!agents || typeof agents.get !== 'function') return false
  const store = agents.store
  if (!store || typeof store.get !== 'function') return false
  let released = false
  for (const variant of sessionIdVariants(sessionId)) {
    const entry = store.get(variant)
    if (entry === undefined) continue
    if (typeof agents.detachEntered === 'function') {
      agents.detachEntered(entry)
      released = true
    } else if (typeof store.delete === 'function') {
      store.delete(variant)
      released = true
    }
  }
  return released
}

// Flush a live session so dispose-time teardown has no pending writes that
// could recreate the old log path after we move the directory.
async function flushSessionIfLive(ctx, sessionId) {
  const sessions = ctx.get('sessions')
  if (!sessions || typeof sessions.get !== 'function') return false
  let flushed = false
  for (const variant of sessionIdVariants(sessionId)) {
    const session = sessions.get(variant)
    if (!session) continue
    if (typeof sessions.flush === 'function') {
      try { await sessions.flush(session); flushed = true } catch { /* ignore */ }
    }
  }
  return flushed
}

// Read workspace registry state (id -> {path,title,sessionIds}) via the
// storageDomain, plus the live registry's view where available.
async function readWorkspaces(ctx) {
  const out = []
  const sd = ctx.get('storageDomain')
  if (sd && typeof sd.get === 'function') {
    const ws = sd.get('workspace')
    if (ws && typeof ws.table === 'function') {
      try {
        const table = ws.table('workspaces')
        for (const [id, rec] of table.entries()) {
          if (!rec || typeof rec !== 'object') continue
          out.push({
            workspaceId: id,
            path: typeof rec.path === 'string' ? rec.path : null,
            title: typeof rec.title === 'string' ? rec.title : null,
            sessionIds: Array.isArray(rec.sessionIds) ? rec.sessionIds : [],
          })
        }
      } catch { /* unit closed or table absent */ }
    }
  }
  return out
}

// Rewrite the session's projection-cache identity cwd in place (rows — stats,
// title, goal — are preserved). The projection cache binds a record to the log
// identity {id, createdAt, cwd} it was folded from and is the source the web
// session list / cold transcript reads use to resolve the log path. A move
// rewrites the on-disk header cwd and relocates the log directory, so the
// cached identity must follow — otherwise every cold read resolves the OLD
// projectKey slug and fails with ENOENT, and the UI shows the session as
// ungrouped. Fail-soft: if the unit is absent or the record is gone (no cache
// row yet), there is nothing to fix — the next cold read folds from the header.
async function refreshProjectionCwd(ctx, sessionId, newCwd) {
  const sd = ctx.get('storageDomain')
  if (!sd || typeof sd.get !== 'function') return false
  const proj = sd.get('session_projcache')
  if (!proj || typeof proj.table !== 'function') return false
  try {
    const sessions = proj.table('sessions')
    let updated = false
    for (const variant of sessionIdVariants(sessionId)) {
      const rec = sessions.get(variant)
      if (
        rec &&
        rec.identity &&
        typeof rec.identity === 'object' &&
        rec.identity.cwd !== newCwd
      ) {
        await sessions.put(variant, { ...rec, identity: { ...rec.identity, cwd: newCwd } })
        updated = true
      }
    }
    return updated
  } catch (e) {
    ctx.logger?.warn?.('[dsh-session-move] projection cache cwd refresh failed:', e?.message ?? e)
    return false
  }
}

// Reconcile stale projection-cache identities at boot. The web session list
// serves a cold session's projections (title, stats, ...) from the cache's
// identity-checked record: cachedSnapshot returns the stored row only when
// record.identity {id, createdAt, cwd} matches the on-disk header. A record
// whose cwd went stale — written before the header's cwd changed (an earlier
// half-applied move, a manual reorg, …) — fails that check; the row is served
// WITHOUT projections, and the client falls back to the workspace-folder
// placeholder name (e.g. "闲聊") until the session is opened (the open path
// cold-reads and writes the row back with the current identity). Rewrite the
// stale identity.cwd in place (rows preserved) and flush, so the list shows
// real titles from the first render. Fail-soft; retries until the storage
// units are ready (apply may run before the projcache table initializes).
async function reconcileProjectionIdentities(ctx, { attempts = 10, delayMs = 1000 } = {}) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const sd = ctx.get('storageDomain')
    const proj = sd && typeof sd.get === 'function' ? sd.get('session_projcache') : undefined
    if (proj && typeof proj.table === 'function') {
      let table
      try { table = proj.table('sessions') } catch { table = undefined }
      if (table) {
        let scanned = 0
        let repaired = 0
        const failures = []
        try {
          const ids = [...table.keys()]
          for (const id of ids) {
            const rec = table.get(id)
            if (!rec || !rec.identity || typeof rec.identity !== 'object') continue
            scanned++
            const dirs = findSessionDirs(id)
            if (dirs.length === 0) continue // record without files: leave for GC
            let header
            try {
              ;({ header } = await readSessionHeader(dirs[0]))
            } catch {
              continue // header unreadable: cannot verify
            }
            if (!header || typeof header.cwd !== 'string' || header.cwd.length === 0) continue
            if (rec.identity.cwd === header.cwd) continue
            await table.put(id, { ...rec, identity: { ...rec.identity, cwd: header.cwd } })
            repaired++
          }
          if (repaired > 0) {
            try { await sd.flush() } catch { /* best-effort */ }
          }
        } catch (e) {
          failures.push(String(e?.message ?? e))
        }
        if (repaired > 0 || failures.length > 0) {
          ctx.logger?.info?.(
            `[dsh-session-move] projection-cache reconcile: scanned=${scanned} repaired=${repaired}` +
            (failures.length ? ` failures=${failures.join('; ')}` : '')
          )
        }
        return { scanned, repaired }
      }
    }
    if (attempt < attempts) await new Promise((r) => setTimeout(r, delayMs))
  }
  return { scanned: 0, repaired: 0 }
}

// --- core move ---------------------------------------------------------------

async function moveSessionCore(ctx, sessionId, workspaceId, workspacePath) {
  if (!SESSION_ID_RE.test(sessionId)) {
    throw new MoveError(`invalid session id: ${sessionId}`)
  }

  const workspaces = await readWorkspaces(ctx)
  let target = workspaces.find((w) => w.workspaceId === workspaceId)
  const fallbackPath = typeof workspacePath === 'string' ? workspacePath.trim() : ''
  if ((!target || !target.path) && fallbackPath) {
    target = {
      workspaceId,
      path: fallbackPath,
      title: target && target.title ? target.title : null,
      sessionIds: target && Array.isArray(target.sessionIds) ? target.sessionIds : [],
    }
  }
  if (!target || !target.path) {
    throw new MoveError(`workspace not found: ${workspaceId}`, 404)
  }

  // 1. Refuse while a live agent owns the session: moving would desync the
  //    in-memory header from the on-disk one. We stop + flush first (mirrors
  //    the delete plugin's safety posture) so the move is never half-applied.
  const stopped = await stopAgentIfRunning(ctx, sessionId)
  await flushSessionIfLive(ctx, sessionId)

  // 2. Locate the on-disk session directory and read its header cwd.
  const dirs = findSessionDirs(sessionId)
  if (dirs.length === 0) throw new MoveError(`session not found: ${sessionId}`, 404)
  const sessionDirPath = dirs[0]
  const { header, frameBytes, frameIndex } = await readSessionHeader(sessionDirPath)
  const oldCwd = header.cwd

  // 3. When the session already lives in the target directory, the physical
  //    move is a no-op — but the workspace accounting might still be missing
  //    (e.g. after a failed attach in a previous move attempt). Detect and
  //    repair that case instead of returning silently.
  const oldWorkspace = workspaces.find((w) => w.path === oldCwd) || null
  if (oldCwd === target.path) {
    // Check whether the session is actually recorded in the target workspace.
    const alreadyAccounted = target.sessionIds.includes(sessionId)
    // The physical state may already be right while the projection cache still
    // carries the old identity (e.g. a previous half-applied move). Refresh it
    // so the web resolves the correct slug either way.
    await refreshProjectionCwd(ctx, sessionId, target.path)
    if (alreadyAccounted) {
      return {
        moved: false,
        sessionId,
        oldCwd,
        newCwd: target.path,
        oldWorkspaceId: oldWorkspace ? oldWorkspace.workspaceId : null,
        newWorkspaceId: target.workspaceId,
      }
    }
    // Session is in the right directory but missing from the workspace table —
    // fall through to the attach step below. Refresh in-memory caches first.
    const reg = ctx.get('workspaceRegistry')
    if (reg && typeof reg === 'object') {
      try {
        const liveSessions = ctx.get('sessions')
        const live = liveSessions && typeof liveSessions.get === 'function'
          ? liveSessions.get(sessionId) : undefined
        if (live && live.header) {
          try { live.header.cwd = target.path } catch { /* frozen */ }
          // A live session's header is a frozen snapshot restored from
          // persistence; the in-place patch above cannot take effect. Replace
          // the whole header object when the property is writable.
          try {
            if (Object.isFrozen(live.header)) live.header = { ...live.header, cwd: target.path }
          } catch { /* read-only getter: detach below handles it */ }
        }
        const updatedHeader = { ...header, cwd: target.path }
        if (typeof reg.headers?.set === 'function') reg.headers.set(sessionId, updatedHeader)
        if (typeof reg.sessionPaths?.set === 'function') reg.sessionPaths.set(sessionId, target.path)
        if (typeof reg.invalidSessionPaths?.delete === 'function') reg.invalidSessionPaths.delete(sessionId)
      } catch { /* best-effort */ }
    }
    // The workspace attach validates the session's cwd through the registry's
    // readSessionHeader, which prefers the LIVE agents store — and a live
    // session's header is a frozen snapshot that the patch above cannot
    // rewrite. A stale live cwd would fail the attach and leave the session
    // ungrouped. Detach the session from the live agents store (same posture
    // as the delete plugin) so the attach validates against the refreshed
    // header cache / on-disk header, and the session reloads cold from its
    // new location. Release the agent first so a later re-open of this
    // session is not blocked by the stale registration. No-op when the
    // session is already cold.
    const agentReleased = releaseAgentIfLive(ctx, sessionId)
    detachLiveSession(ctx, sessionId)
    // Now attach. If oldCwd belongs to a different workspace, detach first.
    if (oldWorkspace && oldWorkspace.workspaceId !== target.workspaceId) {
      const entity = reg && typeof reg.get === 'function' ? reg.get(oldWorkspace.workspaceId) : undefined
      if (entity && typeof entity.detachSession === 'function') {
        try { await entity.detachSession(sessionId) } catch { /* ignore */ }
      }
    }
    let attachError = null
    const newEntity = reg && typeof reg.get === 'function' ? reg.get(target.workspaceId) : undefined
    if (newEntity && typeof newEntity.attachSession === 'function') {
      try { await newEntity.attachSession(sessionId) } catch (e) {
        attachError = String(e?.message ?? e)
      }
    }
    // Ensure the workspace table is persisted to disk so the attach survives
    // a restart (storageDomain may batch writes).
    const projRefreshed = await refreshProjectionCwd(ctx, sessionId, target.path)
    try {
      const sd = ctx.get('storageDomain')
      if (sd && typeof sd.flush === 'function') await sd.flush()
    } catch { /* best-effort flush */ }
    return {
      moved: false,
      reattached: !alreadyAccounted && attachError === null,
      projRefreshed,
      agentReleased,
      sessionId,
      oldCwd,
      newCwd: target.path,
      oldWorkspaceId: oldWorkspace ? oldWorkspace.workspaceId : null,
      newWorkspaceId: target.workspaceId,
      ...(attachError !== null ? { attachError } : {}),
    }
  }

  // 4. Move the physical directory first: old slug -> new slug.
  const newSlug = projectKey(target.path)
  const newSessionDir = path.join(sessionsRoot(), newSlug, sessionDirPath.split(path.sep).pop())
  try {
    fs.mkdirSync(path.dirname(newSessionDir), { recursive: true })
    fs.renameSync(sessionDirPath, newSessionDir)
  } catch (error) {
    throw new MoveError(`failed to move session directory: ${error.message}`, 500)
  }

  // 5. Rewrite the header cwd in the new location.
  try {
    await rewriteHeaderCwd(newSessionDir, header, frameBytes, frameIndex, target.path)
  } catch (error) {
    // Roll the directory back so a failed header patch never leaves the
    // session stranded under the new slug with the old cwd.
    try { fs.renameSync(newSessionDir, sessionDirPath) } catch { /* keep going */ }
    throw new MoveError(`failed to rewrite session header: ${error.message}`, 500)
  }

  // 6. Refresh the workspace registry's in-memory header/path index for this
  //    session BEFORE detach/attach. attachSession validates through
  //    readSessionHeader, which prefers the in-memory cache (live session
  //    header, then the headers map) over the on-disk artifact — if we only
  //    rewrote the file, the cache still carries the old cwd and the attach
  //    would fail its path check. Mirroring the cache keeps the UI consistent
  //    without a restart.
  const reg = ctx.get('workspaceRegistry')
  if (reg && typeof reg === 'object') {
    try {
      const liveSessions = ctx.get('sessions')
      const live = liveSessions && typeof liveSessions.get === 'function'
        ? liveSessions.get(sessionId)
        : undefined
      const updatedHeader = { ...header, cwd: target.path }
      if (live && live.header) {
        // A live session's header is authoritative for readSessionHeader.
        // Patch the live header object's cwd in place (it is a plain record
        // on the session entity; the on-disk artifact was already rewritten,
        // so keeping the in-memory view aligned is safe).
        try { live.header.cwd = target.path } catch { /* frozen or read-only */ }
        // A live session's header is often a frozen snapshot restored from
        // persistence, so the in-place patch cannot take effect. Replace the
        // whole header object when the property is writable.
        try {
          if (Object.isFrozen(live.header)) live.header = { ...live.header, cwd: target.path }
        } catch { /* read-only getter: the detach below handles it */ }
      }
      if (typeof reg.headers?.set === 'function') {
        reg.headers.set(sessionId, updatedHeader)
      }
      if (typeof reg.sessionPaths?.set === 'function') {
        reg.sessionPaths.set(sessionId, target.path)
      }
      if (typeof reg.invalidSessionPaths?.delete === 'function') {
        reg.invalidSessionPaths.delete(sessionId)
      }
    } catch (e) {
      ctx.logger?.warn?.('[dsh-session-move] registry index refresh failed:', e?.message ?? e)
    }
  }

  // 7. Update workspace accounting: detach from the old workspace, attach to
  //    the new one (attachSession validates the header cwd == target path —
  //    now satisfied by the refreshed in-memory index — and re-accounts the
  //    session under the target workspace). First detach the session from the
  //    live agents store: a live session's header is a frozen snapshot that
  //    the patch above cannot rewrite, and readSessionHeader prefers the live
  //    store, so a stale live cwd would fail the attach and leave the session
  //    ungrouped. Removing it from the live store (same posture as the delete
  //    plugin) makes the attach validate against the refreshed cache and lets
  //    the session reload cold from its new location. Release the agent first
  //    so a later re-open of this session is not blocked by the stale
  //    registration. No-op when cold.
  const agentReleased = releaseAgentIfLive(ctx, sessionId)
  detachLiveSession(ctx, sessionId)
  let oldWorkspaceId = null
  if (oldWorkspace) {
    oldWorkspaceId = oldWorkspace.workspaceId
    const entity = reg && typeof reg.get === 'function' ? reg.get(oldWorkspaceId) : undefined
    if (entity && typeof entity.detachSession === 'function') {
      try { await entity.detachSession(sessionId) } catch (e) {
        ctx.logger?.warn?.('[dsh-session-move] detach failed:', e?.message ?? e)
      }
    }
  }
  const newEntity = reg && typeof reg.get === 'function' ? reg.get(target.workspaceId) : undefined
  let attachError = null
  if (newEntity && typeof newEntity.attachSession === 'function') {
    try { await newEntity.attachSession(sessionId) } catch (e) {
      attachError = String(e?.message ?? e)
      ctx.logger?.warn?.('[dsh-session-move] attach failed:', e?.message ?? e)
    }
  }
  // Refresh the projection-cache identity so the web resolves the new slug,
  // then persist the workspace table so the attach survives a restart.
  const projRefreshed = await refreshProjectionCwd(ctx, sessionId, target.path)
  try {
    const sd = ctx.get('storageDomain')
    if (sd && typeof sd.flush === 'function') await sd.flush()
  } catch { /* best-effort flush */ }

  return {
    moved: true,
    stopped,
    agentReleased,
    projRefreshed,
    sessionId,
    oldCwd,
    newCwd: target.path,
    oldWorkspaceId,
    newWorkspaceId: target.workspaceId,
    ...(attachError !== null ? { attachError } : {}),
  }
}

// --- live session detach -----------------------------------------------------

// Remove the session from the in-memory store so host session lists stop
// returning it and no flush can re-materialize its files. Mirrors the
// delete-session plugin's approach (detachEntered is the store's own teardown
// path); falls back to raw store.delete defensively.
function detachLiveSession(ctx, sessionId) {
  const sessions = ctx.get('sessions')
  if (!sessions) return false
  let detached = false
  try {
    const store = sessions.store
    for (const variant of sessionIdVariants(sessionId)) {
      const entry = store && typeof store.get === 'function' ? store.get(variant) : undefined
      if (entry === undefined) continue
      if (typeof sessions.detachEntered === 'function') {
        sessions.detachEntered(entry)
        detached = true
      } else if (store && typeof store.delete === 'function') {
        store.delete(variant)
        detached = true
      }
    }
  } catch { /* ignore */ }
  return detached
}

function sendJson(res, status, obj) {
  const payload = JSON.stringify(obj)
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  })
  res.end(payload)
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on("data", (c) => chunks.push(c))
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")))
    req.on("error", reject)
  })
}

function apply(ctx) {
  function registerHttp(host, targetCtx) {
    targetCtx.effect(() => host.register({
      kind: "exact",
      path: "/__shiyi/move-session",
      handler: async (req, res) => {
        if (req.method !== "POST") {
          sendJson(res, 405, { error: "method not allowed" })
          return
        }
        let args = {}
        try {
          const body = await readBody(req)
          if (body) args = JSON.parse(body)
        } catch {
          sendJson(res, 400, { error: "bad json body" })
          return
        }
        const sessionId = String(args.sessionId || "").trim()
        const workspaceId = String(args.workspaceId || "").trim()
        const workspacePath = String(args.workspacePath || "").trim()
        if (!sessionId || !workspaceId) {
          sendJson(res, 400, { error: "sessionId and workspaceId required" })
          return
        }
        try {
          const result = await moveSessionCore(ctx, sessionId, workspaceId, workspacePath)
          sendJson(res, 200, { ok: true, ...result })
        } catch (e) {
          const status = e instanceof MoveError ? e.status : 500
          sendJson(res, status, { error: e.message, code: "session-move-failed" })
        }
      },
    }))
  }

  const ws = ctx.get("webServer")
  if (ws !== undefined) {
    registerHttp(ws, ctx)
  } else {
    ctx.inject(["webServer"], (sub) => {
      registerHttp(sub.webServer, sub)
    })
  }
  void reconcileProjectionIdentities(ctx).catch(() => {})
}

export { apply, inject, name, moveSessionCore }
