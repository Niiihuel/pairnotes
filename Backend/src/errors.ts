export type ErrorCode = 'failed-precondition' | 'invalid-argument' | 'permission-denied' | 'unauthenticated' | 'resource-exhausted' | 'already-exists' | 'aborted' | 'not-found' | 'internal';
export class HttpsError extends Error {
  constructor(readonly code: ErrorCode, message: string, readonly details?: {reason: string}) {super(message);}
}
