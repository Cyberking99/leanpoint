import { Component, type ErrorInfo, type ReactNode } from 'react';

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false, error: null };

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo): void {
    console.error('ErrorBoundary caught an error:', error, errorInfo);
  }

  render(): ReactNode {
    if (this.state.hasError && this.state.error) {
      return (
        <div
          className="error-message"
          style={{
            margin: '2rem',
            padding: '1.5rem',
            maxWidth: 600,
          }}
        >
          <strong>Something went wrong</strong>
          <p style={{ marginTop: '0.75rem', marginBottom: 0 }}>
            {this.state.error.message}
          </p>
          <p style={{ marginTop: '0.5rem', fontSize: '0.875rem', color: 'var(--text-secondary)' }}>
            Try refreshing the page. If the problem continues, the server or upstream may be returning unexpected data.
          </p>
        </div>
      );
    }
    return this.props.children;
  }
}
