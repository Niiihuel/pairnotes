import {Database, Transaction} from './database';

/** Revoking a location source also revokes consent; re-login never silently resumes it. */
export async function revokeLocationDevice(db: Database, tx: Transaction, uid: string, deviceId: string): Promise<void> {
  const user = (await tx.get(db.doc(`users/${uid}`))).data();
  if (!user?.activePairId) return;
  const ref = db.doc(`pairs/${user.activePairId}/locationConsent/${uid}`), consent = (await tx.get(ref)).data();
  if (!consent?.enabled || consent.deviceId !== deviceId) return;
  tx.set(ref, {enabled: false, deviceId: null, version: consent.version + 1, lastSequence: 0, lastCapturedAt: 0});
  const pair = (await tx.get(db.doc(`pairs/${user.activePairId}`))).data();
  for (const member of pair?.members ?? [uid]) tx.delete(db.doc(`locationPrivate/${member}`));
  tx.delete(db.doc(`pairs/${user.activePairId}/distance/current`));
}
