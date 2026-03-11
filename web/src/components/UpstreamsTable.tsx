import { useState } from 'react';
import { fetchForkChoice } from '../api/client';
import { ForkChoiceView } from './ForkChoiceView';
import type { ForkChoiceResponse, UpstreamsResponse } from '../types';

interface UpstreamsTableProps {
  data: UpstreamsResponse | null;
  loading: boolean;
  error: string | null;
}

export const UpstreamsTable = ({ data, loading, error }: UpstreamsTableProps) => {
  const [forkChoiceUpstream, setForkChoiceUpstream] = useState<string | null>(null);
  const [forkChoiceData, setForkChoiceData] = useState<ForkChoiceResponse | null>(null);
  const [forkChoiceLoading, setForkChoiceLoading] = useState(false);
  const [forkChoiceError, setForkChoiceError] = useState<string | null>(null);

  const handleUpstreamNameClick = async (name: string) => {
    setForkChoiceUpstream(name);
    setForkChoiceData(null);
    setForkChoiceError(null);
    setForkChoiceLoading(true);
    try {
      const fc = await fetchForkChoice(name);
      setForkChoiceData(fc);
    } catch (err) {
      setForkChoiceError(err instanceof Error ? err.message : 'Failed to load fork choice');
    } finally {
      setForkChoiceLoading(false);
    }
  };

  const closeForkChoice = () => {
    setForkChoiceUpstream(null);
    setForkChoiceData(null);
    setForkChoiceError(null);
  };

  if (loading) {
    return <div className="loading">Loading upstreams...</div>;
  }

  if (error) {
    return <div className="error-message">Error: {error}</div>;
  }

  if (!data || data.upstreams.length === 0) {
    return <div className="loading">No upstreams configured</div>;
  }

  const formatTime = (ms: number | null) => {
    if (!ms) return 'Never';
    const seconds = Math.floor((Date.now() - ms) / 1000);
    if (seconds < 60) return `${seconds}s ago`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    return `${Math.floor(seconds / 3600)}h ago`;
  };

  return (
    <>
      {data.consensus && (
        <div className="consensus-info">
          <div className="consensus-item">
            <span className="consensus-label">Total Upstreams</span>
            <span className="consensus-value">{data.consensus.total_upstreams}</span>
          </div>
          <div className="consensus-item">
            <span className="consensus-label">Responding</span>
            <span className="consensus-value">{data.consensus.responding_upstreams}</span>
          </div>
          <div className="consensus-item">
            <span className="consensus-label">Threshold</span>
            <span className="consensus-value">{data.consensus.consensus_threshold}%</span>
          </div>
          <div className="consensus-item">
            <span className="consensus-label">Consensus</span>
            <span className="consensus-value">
              <span className={`status-badge ${data.consensus.has_consensus ? 'healthy' : 'unhealthy'}`}>
                {data.consensus.has_consensus ? 'Reached' : 'Not Reached'}
              </span>
            </span>
          </div>
        </div>
      )}

      <table className="upstreams-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Finalized</th>
            <th>Justified</th>
            <th>Errors</th>
            <th>Last Success</th>
          </tr>
        </thead>
        <tbody>
          {data.upstreams.map((upstream) => (
            <tr key={upstream.name}>
              <td>
                <button
                  type="button"
                  onClick={() => handleUpstreamNameClick(upstream.name)}
                  style={{
                    background: 'none',
                    border: 'none',
                    padding: 0,
                    cursor: 'pointer',
                    textAlign: 'left',
                    color: 'inherit',
                  }}
                  title="View fork choice tree"
                >
                  <div className="upstream-name" style={{ textDecoration: 'underline', color: 'var(--primary-color)' }}>
                    {upstream.name}
                  </div>
                </button>
                <div className="upstream-url">{upstream.url}</div>
              </td>
              <td>
                <span className={`status-badge ${upstream.healthy ? 'healthy' : 'unhealthy'}`}>
                  {upstream.healthy ? 'Healthy' : 'Unhealthy'}
                </span>
              </td>
              <td>
                {upstream.last_finalized_slot !== null
                  ? upstream.last_finalized_slot.toLocaleString()
                  : 'N/A'}
              </td>
              <td>
                {upstream.last_justified_slot !== null
                  ? upstream.last_justified_slot.toLocaleString()
                  : 'N/A'}
              </td>
              <td>{upstream.error_count}</td>
              <td>{formatTime(upstream.last_success_ms)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      {data.upstreams.some((u) => u.last_error) && (
        <div style={{ marginTop: '1rem' }}>
          {data.upstreams
            .filter((u) => u.last_error)
            .map((upstream) => (
              <div key={upstream.name} className="error-message" style={{ marginBottom: '0.5rem' }}>
                <strong>{upstream.name}:</strong> {upstream.last_error}
              </div>
            ))}
        </div>
      )}

      {forkChoiceUpstream != null && (
        <div
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(0,0,0,0.6)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
            padding: 24,
          }}
          onClick={(e) => e.target === e.currentTarget && closeForkChoice()}
        >
          <div
            style={{
              background: 'var(--card-bg)',
              border: '1px solid var(--border-color)',
              borderRadius: 12,
              maxWidth: 900,
              maxHeight: '85vh',
              overflow: 'hidden',
              display: 'flex',
              flexDirection: 'column',
              boxShadow: '0 20px 40px rgba(0,0,0,0.3)',
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <div
              style={{
                padding: '1rem 1.25rem',
                borderBottom: '1px solid var(--border-color)',
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
              }}
            >
              <h2 style={{ fontSize: 1.25, fontWeight: 600, margin: 0 }}>
                Fork choice: {forkChoiceUpstream}
              </h2>
              <button
                type="button"
                onClick={closeForkChoice}
                style={{
                  background: 'transparent',
                  border: '1px solid var(--border-color)',
                  color: 'var(--text-secondary)',
                  borderRadius: 6,
                  padding: '6px 12px',
                  cursor: 'pointer',
                  fontSize: 14,
                }}
              >
                Close
              </button>
            </div>
            <div style={{ padding: '1rem 1.25rem', overflow: 'auto', flex: 1 }}>
              {forkChoiceLoading && (
                <div className="loading">Loading fork choice...</div>
              )}
              {forkChoiceError && (
                <div className="error-message">{forkChoiceError}</div>
              )}
              {!forkChoiceLoading && !forkChoiceError && forkChoiceData != null && (
                <ForkChoiceView
                  data={forkChoiceData}
                  upstreamName={forkChoiceUpstream}
                  onClose={closeForkChoice}
                />
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
};
