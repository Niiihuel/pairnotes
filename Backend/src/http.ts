import express, {Request, Response, ErrorRequestHandler} from 'express';
import {HttpsError} from './errors';
import {PairNotesService, Caller, fail} from './service';

const codes: Record<string, number> = {'unauthenticated': 401, 'permission-denied': 403, 'invalid-argument': 400,
  'not-found': 404, 'already-exists': 409, 'aborted': 409, 'failed-precondition': 400, 'resource-exhausted': 429, 'internal': 500};
function sendError(response: Response, error: unknown, callable: boolean): void {
  const known = error instanceof HttpsError;
  const reason = known ? error.message : 'internal';
  const status = known ? error.code : 'internal';
  response.status(codes[status] ?? 500).json(callable
    ? {error: {status: status.toUpperCase().replaceAll('-', '_'), message: reason, details: {reason}}} : {reason});
}
function bearer(request: Request): string {
  const value = request.header('authorization');
  if (!value?.startsWith('Bearer ') || value.length > 8192) fail('authentication_required', 'unauthenticated');
  return value.slice(7);
}
export function decodeCallable(value: unknown, depth = 0): unknown {
  if (depth > 16) fail('invalid_request', 'invalid-argument');
  if (Array.isArray(value)) return value.map(item => decodeCallable(item, depth + 1));
  if (value && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    if ('@type' in object) {
      if (!['type.googleapis.com/google.protobuf.Int64Value', 'type.googleapis.com/google.protobuf.UInt64Value'].includes(String(object['@type']))
        || typeof object.value !== 'string' || !/^-?[0-9]+$/.test(object.value) || Object.keys(object).length !== 2) fail('invalid_request', 'invalid-argument');
      const number = Number(object.value);
      if (!Number.isSafeInteger(number) || (String(object['@type']).includes('UInt64') && number < 0)) fail('unsafe_integer', 'invalid-argument');
      return number;
    }
    return Object.fromEntries(Object.entries(object).map(([key, item]) => [key, decodeCallable(item, depth + 1)]));
  }
  if (typeof value === 'number' && !Number.isFinite(value)) fail('invalid_request', 'invalid-argument');
  return value;
}

export interface AuthenticationAPI {
  authenticate(token: string): Promise<Caller>;
  challenge(input: Record<string, unknown>): Promise<unknown>;
  exchange(input: Record<string, unknown>, existingAccessToken?: string): Promise<unknown>;
  refresh(input: Record<string, unknown>): Promise<unknown>;
  session(token: string): Promise<unknown>;
  signout(token: string, input: Record<string, unknown>): Promise<unknown>;
}
/** PostgreSQL sessions authorize app calls; widget credentials have a separate, narrow scope. */
export function createHTTPApp(options: {service: PairNotesService; auth: AuthenticationAPI; ready?: () => boolean}) {
  const app = express();
  app.disable('x-powered-by');
  app.use((_request, response, next) => {response.set('Cache-Control', 'private, no-store'); next();});
  // Do not trust spoofable forwarded headers. Behind an edge this bounds attempts per proxy;
  // configure platform WAF limits before widening this small private-app deployment.
  app.set('trust proxy', false);
  const attempts = new Map<string, {until: number; count: number}>();
  let concurrentAuthentication = 0;
  app.use('/auth', (request, response, next) => {
    const now = Date.now(), key = request.ip ?? 'unknown';
    for (const [ip, limit] of attempts) if (limit.until <= now) attempts.delete(ip);
    const limit = attempts.get(key);
    if (concurrentAuthentication >= 8 || (!limit && attempts.size >= 4096) || (limit && limit.count >= 60)) {
      response.status(429).json({error: {status: 'RESOURCE_EXHAUSTED', message: 'rate_limited', details: {reason: 'rate_limited'}}}); return;
    }
    attempts.set(key, {until: limit?.until ?? now + 60_000, count: (limit?.count ?? 0) + 1});
    concurrentAuthentication++;
    response.once('close', () => {concurrentAuthentication--;});
    next();
  });
  app.put('/upload', async (request, response, next) => {
    try {response.locals.caller = await options.auth.authenticate(bearer(request)); next();}
    catch (error) {sendError(response, error, false);}
  }, express.raw({type: ['application/octet-stream', 'image/png'], limit: '20mb'}), async (request, response) => {
    try {
      const identity = response.locals.caller as Caller;
      if (typeof request.query.sessionId !== 'string' || typeof request.query.role !== 'string' || !Buffer.isBuffer(request.body)) fail('invalid_upload', 'invalid-argument');
      response.json(await options.service.upload(identity, request.query.sessionId, request.query.role, request.body,
        request.header('content-type') ?? '', request.header('x-content-sha256') ?? ''));
    } catch (error) {sendError(response, error, false);}
  });
  for (const route of ['profileAvatar', 'memoryPhoto', 'couplePhoto'] as const) {
    app.put(`/${route}`, async (request, response, next) => {
      try {response.locals.caller = await options.auth.authenticate(bearer(request)); next();}
      catch (error) {sendError(response, error, false);}
    }, express.raw({type: ['image/png', 'image/jpeg'], limit: '5mb'}), async (request, response) => {
      try {
        if (!Buffer.isBuffer(request.body)) fail('invalid_image', 'invalid-argument');
        const caller = response.locals.caller as Caller;
        response.json(route === 'profileAvatar'
          ? await options.service.couple.profileAvatar(caller, request.body, request.header('content-type') ?? '')
          : route === 'memoryPhoto' ? await options.service.couple.memoryPhoto(caller, {...request.query, pairEpoch: Number(request.query.pairEpoch)},
            request.body, request.header('content-type') ?? '')
          : await options.service.photos.send(caller, {...request.query, pairEpoch: Number(request.query.pairEpoch)},
            request.body, request.header('content-type') ?? ''));
      } catch (error) {sendError(response, error, false);}
    });
  }
  for (const role of ['photo', 'drawing', 'audio'] as const) {
    const route = role === 'photo' ? '/letterPhoto' : role === 'drawing' ? '/letterDrawing' : '/letterAudio';
    app.put(route, async (request, response, next) => {
      try {response.locals.caller = await options.auth.authenticate(bearer(request)); next();}
      catch (error) {sendError(response, error, false);}
    }, express.raw({type: role !== 'audio' ? ['image/png', 'image/jpeg'] : ['audio/wav'], limit: role !== 'audio' ? '5mb' : '2mb'}), async (request, response) => {
      try {
        if (!Buffer.isBuffer(request.body)) fail('invalid_asset', 'invalid-argument');
        response.json(await options.service.affection.letterAsset(response.locals.caller, {...request.query, pairEpoch: Number(request.query.pairEpoch)},
          role, request.body, request.header('content-type')));
      } catch (error) {sendError(response, error, false);}
    });
    app.get(route, async (request, response) => {
      try {
        const caller = await options.auth.authenticate(bearer(request));
        const bytes = await options.service.affection.letterAsset(caller, {...request.query, pairEpoch: Number(request.query.pairEpoch)}, role);
        response.type(role !== 'audio' ? 'image/png' : 'audio/wav').send(bytes);
      } catch (error) {sendError(response, error, false);}
    });
  }
  app.use(express.json({limit: '32kb', strict: true}));
  for (const name of ['challenge', 'exchange', 'refresh'] as const) {
    app.post(`/auth/${name}`, async (request, response) => {
      try {
        if (!request.body || typeof request.body !== 'object' || Array.isArray(request.body)) fail('invalid_request', 'invalid-argument');
        // No access/refresh credentials or identity tokens are written to logs.
        const token = request.header('authorization') ? bearer(request) : undefined;
        response.json(name === 'exchange' ? await options.auth.exchange(request.body, token) : await options.auth[name](request.body));
      } catch (error) {sendError(response, error, true);}
    });
  }
  app.get('/auth/session', async (request, response) => {
    try {response.json(await options.auth.session(bearer(request)));} catch (error) {sendError(response, error, true);}
  });
  app.post('/auth/signout', async (request, response) => {
    try {response.json(await options.auth.signout(bearer(request), request.body ?? {}));} catch (error) {sendError(response, error, true);}
  });
  app.get('/image', async (request, response) => {
    try {
      const identity = await options.auth.authenticate(bearer(request));
      if (typeof request.query.path !== 'string') fail('invalid_asset_path', 'invalid-argument');
      response.type(request.query.path.endsWith('/source') ? 'application/octet-stream' : 'image/png')
        .send(await options.service.image(identity, request.query.path));
    } catch (error) {sendError(response, error, false);}
  });
  app.get('/profileAvatar', async (request, response) => {
    try {
      const identity = await options.auth.authenticate(bearer(request));
      if (typeof request.query.uid !== 'string' || (request.query.avatarId !== undefined && typeof request.query.avatarId !== 'string')) fail('invalid_user_id', 'invalid-argument');
      response.type('image/png').send(await options.service.couple.avatar(identity, request.query.uid, request.query.avatarId));
    } catch (error) {sendError(response, error, false);}
  });
  app.get('/memoryPhoto', async (request, response) => {
    try {
      const identity = await options.auth.authenticate(bearer(request));
      response.type('image/png').send(await options.service.couple.memoryPhoto(identity,
        {...request.query, pairEpoch: Number(request.query.pairEpoch)}));
    } catch (error) {sendError(response, error, false);}
  });
  app.get('/couplePhoto', async (request, response) => {
    try {
      const identity = await options.auth.authenticate(bearer(request));
      response.type('image/png').send(await options.service.photos.image(identity,
        {...request.query, pairEpoch: Number(request.query.pairEpoch)}));
    } catch (error) {sendError(response, error, false);}
  });
  app.get('/healthz', (_request, response) => {
    const ready = options.ready?.() ?? true;
    response.status(ready ? 200 : 503).json({status: ready ? 'ok' : 'starting'});
  });
  const operations = ['upsertProfile', 'getPairState', 'createInvite', 'acceptInvite', 'revokeInvite', 'closePair',
    'createUploadSession', 'finalizeNote', 'timeline', 'note', 'latestReceivedNote', 'markNoteViewed', 'registerDevice', 'unregisterDevice', 'issueWidgetSession',
    'getCoupleSpace', 'updatePersonalization', 'restoreMemory', 'updatePairDetails', 'upsertMemory', 'memories', 'deleteMemory', 'deleteMemoryPhoto', 'deleteProfileAvatar',
    'getPhoto', 'setPhotoReaction', 'sendGesture', 'reactions', 'setReaction', 'letters', 'saveLetterDraft', 'sealLetter', 'openLetter', 'deleteLetterDraft', 'removeLetterAsset',
    'sendMessage', 'messages', 'setLocationConsent', 'updateLocation'] as const;
  for (const name of operations) {
    app.post(`/${name}`, async (request, response) => {
      try {
        const identity = await options.auth.authenticate(bearer(request));
        const data = decodeCallable(request.body?.data) as Record<string, unknown>;
        if (!data || typeof data !== 'object' || Array.isArray(data) || Object.keys(request.body).some(key => key !== 'data')) fail('invalid_request', 'invalid-argument');
        const result = await options.service[name](identity, data);
        response.json({result});
      } catch (error) {sendError(response, error, true);}
    });
  }
  app.get('/widgetSnapshot', async (request, response) => {
    try {response.json(await options.service.widgetSnapshot(bearer(request)));}
    catch (error) {sendError(response, error, false);}
  });
  app.post('/widgetLocation', async (request, response) => {
    try {
      if (!request.body || typeof request.body !== 'object' || Array.isArray(request.body)) fail('invalid_request', 'invalid-argument');
      response.json(await options.service.widgetLocation(bearer(request), request.body));
    } catch (error) {sendError(response, error, false);}
  });
  app.get('/widgetImage', async (request, response) => {
    try {
      if (typeof request.query.noteId !== 'string') fail('invalid_note_id', 'invalid-argument');
      response.type('image/png').send(await options.service.widgetImage(bearer(request), request.query.noteId));
    } catch (error) {sendError(response, error, false);}
  });
  app.get('/widgetAvatar', async (request, response) => {
    try {
      if (typeof request.query.uid !== 'string' || (request.query.avatarId !== undefined && typeof request.query.avatarId !== 'string')) fail('invalid_user_id', 'invalid-argument');
      response.type('image/png').send(await options.service.widgetAvatar(bearer(request), request.query.uid, request.query.avatarId));
    } catch (error) {sendError(response, error, false);}
  });
  app.get('/widgetPhoto', async (request, response) => {
    try {
      if (typeof request.query.photoId !== 'string' || typeof request.query.assetId !== 'string') fail('invalid_photo_id', 'invalid-argument');
      response.type('image/png').send(await options.service.widgetPhoto(bearer(request), request.query.photoId, request.query.assetId));
    } catch (error) {sendError(response, error, false);}
  });
  app.post('/widgetPhotoReaction', async (request, response) => {
    try {
      if (!request.body || typeof request.body !== 'object' || Array.isArray(request.body)) fail('invalid_request', 'invalid-argument');
      response.json(await options.service.widgetPhotoReaction(bearer(request), request.body));
    } catch (error) {sendError(response, error, false);}
  });
  app.post('/widgetPushRegistration', async (request, response) => {
    try {response.json(await options.service.widgetPushRegistration(bearer(request), request.body ?? {}));}
    catch (error) {sendError(response, error, false);}
  });
  app.use((_request, response) => {response.status(404).json({reason: 'not_found'});});
  const malformed: ErrorRequestHandler = (_error, _request, response, _next) => {
    response.status(400).json({error: {status: 'INVALID_ARGUMENT', message: 'invalid_request', details: {reason: 'invalid_request'}}});
  };
  app.use(malformed);
  return app;
}
