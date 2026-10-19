const { randomUUID } = require("node:crypto");

class TableLockStore {
  constructor({ ttlMs, now = Date.now, newId = randomUUID }) {
    this.ttlMs = ttlMs;
    this.now = now;
    this.newId = newId;
    this.leases = new Map();
    this.revoked = new Map();
  }

  get(tableId) { return this.leases.get(String(tableId)); }
  entries() { return this.leases.entries(); }

  list() {
    const locks = {};
    for (const [id, lease] of this.leases) {
      if (lease.expiresAt > this.now()) locks[id] = this.summary(lease);
    }
    return locks;
  }

  summary(lease) {
    return lease ? {
      lockId: lease.lockId,
      status: lease.expiresAt > this.now() ? "attivo" : "scaduto",
      expiresAt: lease.expiresAt
    } : { status: "libero" };
  }

  acquire({ tableId, token, lockId, replaceLockId, explicitAcquire = false }) {
    tableId = String(tableId);
    const current = this.get(tableId);
    const conflict = () => ({ ok: false, locked: Boolean(current && current.expiresAt > this.now()), ...this.summary(current) });
    // A confirmation and a heartbeat both refer to a specific lease, never a future owner.
    if (replaceLockId && (!current || current.lockId !== replaceLockId)) return conflict();
    if (lockId && (!current || current.token !== token || current.lockId !== lockId)) return conflict();
    if (this.revoked.get(tableId)?.has(token) && !explicitAcquire) return conflict();
    if (current && current.expiresAt > this.now() && current.token !== token && !replaceLockId) return conflict();

    if (current && current.token !== token) {
      if (!this.revoked.has(tableId)) this.revoked.set(tableId, new Set());
      this.revoked.get(tableId).add(current.token);
    }
    if (explicitAcquire) this.revoked.get(tableId)?.delete(token);
    const lease = current && current.token === token ? current : { token, lockId: this.newId() };
    lease.status = "attivo";
    lease.expiresAt = this.now() + this.ttlMs;
    this.leases.set(tableId, lease);
    return { ok: true, ...this.summary(lease) };
  }

  release({ tableId, token, lockId }) {
    const current = this.get(tableId);
    if (current && current.token === token && (!lockId || current.lockId === lockId)) {
      this.leases.delete(String(tableId));
    }
  }
}

module.exports = { TableLockStore };
