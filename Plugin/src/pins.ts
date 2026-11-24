// Durable repository-root pins for session instructions (AF08, round 4; docs/features/opencode-config.md).
//
// A session's repository root is rediscovered from its folder at every prompt. The first lookup that succeeds pins
// the session to that root: its canonical path and its folder identity (device and inode). Pins live in a folder the
// app owns (`OpenCodeDirectories.instructionPinsDirectory`, outside every code root, so an agent cannot write it), one
// small file per session, so a restarted server, another plugin instance or an evicted in-memory entry finds the same
// pin. A later lookup must find the same root folder (same identity), or the session gets no repository instructions.
//
// A watermark records the newest session creation time that may lack a pin it should have: the time the store was
// first set up (every session older than that predates durable pins; its root was only ever pinned in memory) and,
// when the bounded store overflows and its oldest pins are removed, the newest creation time among them. A session
// with no pin created at or before the watermark is not provably new, so it is pinned only when its folder's path
// holds no link at all (`instructionLookup` with `unlinked`): a checkout folder that became a link to another one
// gets no repository instructions (fail closed). A session created after the watermark is new and pinned as found.

import { closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readSync, readdirSync, renameSync, unlinkSync, writeSync } from "fs"
import { join } from "path"
import type { RootIdentity } from "./project.ts"

export type RootPin = {
  /** The session folder as opencode records it when the pin was made. */
  directory: string
  /** The canonical repository root the lookup found. */
  root: string
  /** The root folder's identity at that time. */
  identity: RootIdentity
  /** The session's creation time (ms), for the eviction watermark. */
  created: number
}

/** `pins`: the most pin files kept; overflow prunes down to `keep`. `fileBytes`: the largest pin file read. */
export const PIN_LIMITS = { pins: 10_000, keep: 9_000, fileBytes: 4096, pruneEvery: 256 }

const NOFOLLOW = (constants as any).O_NOFOLLOW ?? 0
const NONBLOCK = (constants as any).O_NONBLOCK ?? 0
const SESSION_ID = /^[A-Za-z0-9_-]{1,200}$/
const PIN_FILE = /^[A-Za-z0-9_-]{1,200}\.json$/

/** "none": the session has never been pinned here. "unreadable": a pin exists (or may) but cannot be trusted. */
export type PinRead = RootPin | "none" | "unreadable"

function validIdentity(value: any): value is RootIdentity {
  return typeof value?.dev === "string" && typeof value?.ino === "string" && /^\d+$/.test(value.dev) && /^\d+$/.test(value.ino)
}

function parsePin(text: string, sessionID: string): RootPin | undefined {
  const value = JSON.parse(text)
  if (value?.version !== 1 || value.sessionID !== sessionID) return undefined
  if (typeof value.directory !== "string" || typeof value.root !== "string" || !value.root.startsWith("/")) return undefined
  if (!validIdentity(value.identity) || typeof value.created !== "number") return undefined
  return { directory: value.directory, root: value.root, identity: { dev: value.identity.dev, ino: value.identity.ino }, created: value.created }
}

/** A small file read without following a link and without blocking; undefined unless it is a regular file. */
function readSmall(path: string, limit: number): string | undefined {
  let fd: number | undefined
  try {
    fd = openSync(path, constants.O_RDONLY | NOFOLLOW | NONBLOCK)
    const info = fstatSync(fd)
    if (!info.isFile() || info.size > limit) return undefined
    const buffer = Buffer.alloc(info.size)
    let offset = 0
    while (offset < info.size) {
      const count = readSync(fd, buffer, offset, info.size - offset, offset)
      if (count <= 0) break
      offset += count
    }
    return buffer.subarray(0, offset).toString("utf8")
  } catch {
    return undefined
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {}
    }
  }
}

function exists(path: string): boolean | undefined {
  try {
    lstatSync(path)
    return true
  } catch (error: any) {
    return error?.code === "ENOENT" ? false : undefined
  }
}

/** Writes `text` to `path` atomically (a new private file renamed over it). */
function writeAtomic(folder: string, path: string, text: string): boolean {
  const temp = join(folder, `.${process.pid}-${Math.random().toString(36).slice(2)}.tmp`)
  let fd: number | undefined
  try {
    fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW, 0o600)
    const data = Buffer.from(text, "utf8")
    let offset = 0
    while (offset < data.length) offset += writeSync(fd, data, offset, data.length - offset)
    closeSync(fd)
    fd = undefined
    renameSync(temp, path)
    return true
  } catch {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {}
    }
    try {
      unlinkSync(temp)
    } catch {}
    return false
  }
}

export class PinStore {
  private writes = 0
  private readonly watermarkFolder: string

  constructor(
    readonly folder: string,
    private readonly limits = PIN_LIMITS,
  ) {
    this.watermarkFolder = join(folder, "watermark")
  }

  /** Creates the folders (private) and checks they are real folders, not links. False when the store cannot be used. */
  ready(): boolean {
    try {
      mkdirSync(this.watermarkFolder, { recursive: true, mode: 0o700 })
      return lstatSync(this.folder).isDirectory() && lstatSync(this.watermarkFolder).isDirectory()
    } catch {
      return false
    }
  }

  private file(sessionID: string): string {
    return join(this.folder, `${sessionID}.json`)
  }

  read(sessionID: string): PinRead {
    if (!SESSION_ID.test(sessionID) || !this.ready()) return "unreadable"
    const path = this.file(sessionID)
    const present = exists(path)
    if (present === false) return "none"
    if (present === undefined) return "unreadable"
    try {
      return parsePin(readSmall(path, this.limits.fileBytes) ?? "", sessionID) ?? "unreadable"
    } catch {
      return "unreadable"
    }
  }

  /** Records the pin; false when it could not be stored (the caller then hands over nothing). */
  write(sessionID: string, pin: RootPin): boolean {
    if (!SESSION_ID.test(sessionID) || !this.ready()) return false
    const text = JSON.stringify({ version: 1, sessionID, ...pin })
    if (text.length > this.limits.fileBytes) return false
    if (!writeAtomic(this.folder, this.file(sessionID), text)) return false
    if (++this.writes % this.limits.pruneEvery === 0) this.prune()
    return true
  }

  /** The recorded watermark markers (decimal milliseconds), or undefined when the folder cannot be read. */
  private markers(): number[] | undefined {
    try {
      return readdirSync(this.watermarkFolder)
        .filter((name) => /^\d{1,16}$/.test(name))
        .map(Number)
    } catch {
      return undefined
    }
  }

  /**
   * Records the store's creation time as the first watermark, when no watermark is recorded yet (a new store, or one
   * whose markers were removed). Called when the plugin starts, before any session it serves can be new. False when
   * the store cannot be used.
   */
  initialise(now = Date.now()): boolean {
    if (!this.ready()) return false
    const markers = this.markers()
    if (markers === undefined) return false
    if (markers.length > 0) return true
    return writeAtomic(this.watermarkFolder, join(this.watermarkFolder, String(Math.ceil(now))), "")
  }

  /**
   * The newest creation time a session can have and still lack a pin it should have (`initialise` and `prune`).
   * With no marker recorded, one is recorded now. Infinity when it cannot be read or recorded: then no unpinned
   * session counts as new.
   */
  watermark(): number {
    if (!this.ready()) return Infinity
    let markers = this.markers()
    if (markers !== undefined && markers.length === 0) markers = this.initialise() ? this.markers() : undefined
    if (markers === undefined || markers.length === 0) return Infinity
    return Math.max(...markers)
  }

  /**
   * Removes the oldest pins (by when they were written) once there are more than `limits.pins`, down to
   * `limits.keep`. The watermark is recorded before any pin is removed; if it cannot be, nothing is removed.
   */
  prune(): void {
    try {
      if (!this.ready()) return
      const names = readdirSync(this.folder)
      for (const name of names) {
        if (!name.startsWith(".") || !name.endsWith(".tmp")) continue
        try {
          if (Date.now() - lstatSync(join(this.folder, name)).mtimeMs > 60_000) unlinkSync(join(this.folder, name))
        } catch {}
      }
      const pins = names.filter((name) => PIN_FILE.test(name))
      if (pins.length <= this.limits.pins) return
      const dated = pins
        .map((name) => {
          try {
            return { name, time: lstatSync(join(this.folder, name)).mtimeMs }
          } catch {
            return { name, time: 0 }
          }
        })
        .sort((a, b) => a.time - b.time || (a.name < b.name ? -1 : 1))
      const victims = dated.slice(0, pins.length - this.limits.keep)
      let through = 0
      for (const victim of victims) {
        const sessionID = victim.name.slice(0, -".json".length)
        const pin = this.read(sessionID)
        // A pin whose time cannot be read could belong to any session: everything up to now is covered.
        through = Math.max(through, typeof pin === "object" ? pin.created : Date.now())
      }
      // Never lower: the store's creation time (or an earlier eviction) may already be the newer mark.
      const marker = Math.max(Math.ceil(through), ...(this.markers() ?? []))
      if (!writeAtomic(this.watermarkFolder, join(this.watermarkFolder, String(marker)), "")) return
      for (const name of readdirSync(this.watermarkFolder)) {
        if (/^\d{1,16}$/.test(name) && Number(name) < marker) {
          try {
            unlinkSync(join(this.watermarkFolder, name))
          } catch {}
        }
      }
      for (const victim of victims) {
        try {
          unlinkSync(join(this.folder, victim.name))
        } catch {}
      }
    } catch {}
  }
}
