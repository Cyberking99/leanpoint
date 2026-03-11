import { useEffect, useState } from 'react';
import { StatusCard } from './components/StatusCard';
import { UpstreamsTable } from './components/UpstreamsTable';
import { fetchStatus, fetchUpstreams, fetchHealth } from './api/client';
import { Status, UpstreamsResponse } from './types';
import './styles/App.css';

function App() {
  const [status, setStatus] = useState<Status | null>(null);
  const [upstreams, setUpstreams] = useState<UpstreamsResponse | null>(null);
  const [healthy, setHealthy] = useState<boolean>(true);
  const [statusLoading, setStatusLoading] = useState(true);
  const [upstreamsLoading, setUpstreamsLoading] = useState(true);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [upstreamsError, setUpstreamsError] = useState<string | null>(null);

  const loadStatus = async () => {
    try {
      setStatusLoading(true);
      setStatusError(null);
      const data = await fetchStatus();
      setStatus(data);
    } catch (err) {
      setStatusError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setStatusLoading(false);
    }
  };

  const loadUpstreams = async () => {
    try {
      setUpstreamsLoading(true);
      setUpstreamsError(null);
      const data = await fetchUpstreams();
      setUpstreams(data);
    } catch (err) {
      setUpstreamsError(err instanceof Error ? err.message : 'Unknown error');
    } finally {
      setUpstreamsLoading(false);
    }
  };

  const checkHealth = async () => {
    try {
      const result = await fetchHealth();
      setHealthy(result.healthy);
    } catch {
      setHealthy(false);
    }
  };

  useEffect(() => {
    loadStatus();
    loadUpstreams();
    checkHealth();

    const statusInterval = setInterval(loadStatus, 5000);
    const upstreamsInterval = setInterval(loadUpstreams, 10000);
    const healthInterval = setInterval(checkHealth, 5000);

    return () => {
      clearInterval(statusInterval);
      clearInterval(upstreamsInterval);
      clearInterval(healthInterval);
    };
  }, []);

  return (
    <div className="app">
      <header>
        <div className="header-content">
          <div className="logo">
            <h1>⚡ Leanpoint</h1>
          </div>
          <div className={`health-badge ${healthy ? 'healthy' : 'unhealthy'}`}>
            <span className="status-dot"></span>
            {healthy ? 'Operational' : 'Degraded'}
          </div>
        </div>
      </header>

      <main>
        <section className="section">
          <div className="section-header">
            <h2 className="section-title">Checkpoint Status</h2>
          </div>
          <StatusCard status={status} loading={statusLoading} error={statusError} />
        </section>

        <section className="section">
          <div className="section-header">
            <h2 className="section-title">Upstream Lean Nodes</h2>
          </div>
          <UpstreamsTable data={upstreams} loading={upstreamsLoading} error={upstreamsError} />
        </section>

        <section className="section">
          <div className="section-header">
            <h2 className="section-title">About</h2>
          </div>
          <p style={{ color: 'var(--text-secondary)', lineHeight: 1.6 }}>
            Leanpoint is a lightweight checkpoint sync provider for Lean Ethereum. It monitors
            multiple lean nodes and requires 50%+ consensus before serving finality data. This
            ensures Byzantine fault tolerance and data integrity across diverse client
            implementations.
          </p>
          <div style={{ marginTop: '1rem', padding: '1rem', backgroundColor: 'rgba(99, 102, 241, 0.05)', borderRadius: '0.5rem' }}>
            <h3 style={{ fontSize: '1rem', fontWeight: 600, marginBottom: '0.5rem' }}>Quick Start</h3>
            <pre style={{ fontSize: '0.875rem', color: 'var(--text-secondary)', overflowX: 'auto' }}>
{`# Poll status endpoint
curl ${typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5555'}/status

# View Prometheus metrics
curl ${typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5555'}/metrics

# Health check
curl ${typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5555'}/healthz`}
            </pre>
            <p style={{ fontSize: '0.875rem', color: 'var(--text-secondary)', marginTop: '0.75rem', marginBottom: 0 }}>
              <strong>API — Finalized state (SSZ):</strong>{' '}
              <code style={{ wordBreak: 'break-all' }}>
                {typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5555'}/lean/v0/states/finalized
              </code>
            </p>
          </div>
        </section>
      </main>

      <footer>
        <p>Built with ⚡ by the Lean Ethereum community | Inspired by checkpointz</p>
      </footer>
    </div>
  );
}

export default App;
