export interface Status {
  justified_slot: number;
  finalized_slot: number;
  last_updated_ms: number;
  last_success_ms: number;
  stale: boolean;
  error_count: number;
  last_error: string | null;
}

export interface Upstream {
  name: string;
  url: string;
  path: string;
  healthy: boolean;
  last_success_ms: number | null;
  error_count: number;
  last_error: string | null;
  last_justified_slot: number | null;
  last_finalized_slot: number | null;
  /** true/false from /lean/v0/admin/aggregator when the client supports it */
  is_aggregator: boolean | null;
  /** head.slot from /lean/v0/fork_choice when available */
  head_slot: number | null;
}

export interface UpstreamsResponse {
  upstreams: Upstream[];
  consensus: {
    total_upstreams: number;
    responding_upstreams: number;
    consensus_threshold: number;
    has_consensus: boolean;
  };
}

export interface HistoricalCheckpoint {
  slot: number;
  timestamp: number;
  finalized: boolean;
}

export interface ForkChoiceCheckpoint {
  slot: number;
  root: string;
}

export interface ForkChoiceNode {
  slot: number;
  root: string;
  parent_root: string;
  weight: number;
}

export interface ForkChoiceResponse {
  head: ForkChoiceCheckpoint;
  justified: ForkChoiceCheckpoint;
  finalized: ForkChoiceCheckpoint;
  safe_target: { root: string };
  validator_count: number;
  nodes: ForkChoiceNode[];
}
