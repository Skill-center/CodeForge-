/**
 * The page's own requests to the host (Phase 6 W5): language features ask
 * the host, which asks the language server, and each request is answered
 * by one `response` from the host, or times out here.
 */
import type { ErrorCode, PageRequests, PageRequestType, PageResults } from '../protocol/types';

/** A request that failed: the host's error code, or the page's own. */
export class RequestError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
  ) {
    super(message);
  }
}

export interface PendingRequest<T> {
  /** The request's envelope id, for cancelling it. */
  readonly id: string;
  /** Its result, checked; rejects with a [RequestError]. */
  readonly result: Promise<T>;
}

export interface PageRequester {
  request<K extends PageRequestType>(type: K, payload: PageRequests[K], timeoutMs: number): PendingRequest<PageResults[K]>;
  /** Gives up on request [id]: its result rejects as `cancelled`, and the host is told. */
  cancel(id: string): void;
}

/**
 * How long the page waits for each answer: a second longer than the host
 * gives the server (application/lsp/lsp_features.dart), so the host's
 * timeout, with its message, is what the user sees.
 */
export const REQUEST_TIMEOUT_MS: Record<PageRequestType, number> = {
  'lsp.complete': 3000,
  'lsp.resolve': 4000,
  'lsp.hover': 4000,
  'lsp.definition': 11000,
  'lsp.prepareRename': 11000,
};
