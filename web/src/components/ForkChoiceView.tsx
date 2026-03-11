import type { ForkChoiceNode, ForkChoiceResponse } from '../types';

function shortRoot(root: string): string {
  if (root.startsWith('0x')) return `0x${root.slice(2, 10)}`;
  return root.slice(0, 10);
}

function buildChildrenMap(nodes: ForkChoiceNode[]): Map<string, ForkChoiceNode[]> {
  const byRoot = new Map<string, ForkChoiceNode>();
  for (const n of nodes) byRoot.set(n.root, n);
  const children = new Map<string, ForkChoiceNode[]>();
  for (const n of nodes) {
    const key = n.parent_root;
    if (!children.has(key)) children.set(key, []);
    children.get(key)!.push(n);
  }
  return children;
}

function getRoots(nodes: ForkChoiceNode[]): ForkChoiceNode[] {
  const rootSet = new Set(nodes.map((n) => n.root));
  return nodes.filter((n) => !rootSet.has(n.parent_root));
}

interface BlockNodeProps {
  node: ForkChoiceNode;
  childrenMap: Map<string, ForkChoiceNode[]>;
  headRoot: string;
  justifiedRoot: string;
  finalizedRoot: string;
  safeTargetRoot: string;
  depth: number;
  isLast: boolean;
}

function BlockNode({
  node,
  childrenMap,
  headRoot,
  justifiedRoot,
  finalizedRoot,
  safeTargetRoot,
  depth,
  isLast,
}: BlockNodeProps) {
  const isHead = node.root === headRoot;
  const isJustified = node.root === justifiedRoot;
  const isFinalized = node.root === finalizedRoot;
  const isSafeTarget = node.root === safeTargetRoot;
  const children = childrenMap.get(node.root) ?? [];
  const labels: string[] = [];
  if (isHead) labels.push('head');
  if (isJustified) labels.push('justified');
  if (isFinalized) labels.push('finalized');
  if (isSafeTarget) labels.push('safe_target');

  return (
    <div style={{ marginLeft: depth * 16 }}>
      <div
        style={{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 8,
          flexWrap: 'wrap',
          marginBottom: 4,
        }}
      >
        <span style={{ color: 'var(--text-secondary)', fontFamily: 'monospace', fontSize: 12 }}>
          {depth > 0 && (isLast ? '└── ' : '├── ')}
        </span>
        <span
          className="fork-choice-block"
          style={{
            padding: '4px 8px',
            borderRadius: 4,
            fontFamily: 'monospace',
            fontSize: 13,
            border: '1px solid var(--border-color)',
            background:
              isHead
                ? 'rgba(16, 185, 129, 0.15)'
                : isJustified
                  ? 'rgba(99, 102, 241, 0.15)'
                  : isFinalized
                    ? 'rgba(245, 158, 11, 0.15)'
                    : isSafeTarget
                      ? 'rgba(139, 92, 246, 0.15)'
                      : 'var(--card-bg)',
            color:
              isHead
                ? 'var(--success-color)'
                : isJustified
                  ? 'var(--primary-color)'
                  : isFinalized
                    ? 'var(--warning-color)'
                    : isSafeTarget
                      ? 'var(--secondary-color)'
                      : 'var(--text-primary)',
          }}
        >
          {shortRoot(node.root)} (slot {node.slot}, weight {node.weight})
        </span>
        {labels.length > 0 && (
          <span style={{ fontSize: 11, color: 'var(--text-secondary)' }}>
            [{labels.join(', ')}]
          </span>
        )}
      </div>
      {children.map((child, i) => (
        <BlockNode
          key={child.root}
          node={child}
          childrenMap={childrenMap}
          headRoot={headRoot}
          justifiedRoot={justifiedRoot}
          finalizedRoot={finalizedRoot}
          safeTargetRoot={safeTargetRoot}
          depth={depth + 1}
          isLast={i === children.length - 1}
        />
      ))}
    </div>
  );
}

interface ForkChoiceViewProps {
  data: ForkChoiceResponse;
  upstreamName: string;
  onClose: () => void;
}

export function ForkChoiceView({ data }: ForkChoiceViewProps) {
  const childrenMap = buildChildrenMap(data.nodes);
  const roots = getRoots(data.nodes);

  return (
    <>
        <div style={{ padding: '1rem 1.25rem', overflow: 'auto', flex: 1 }}>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))',
              gap: 12,
              marginBottom: 16,
            }}
          >
            <div style={{ padding: 8, background: 'rgba(16,185,129,0.1)', borderRadius: 8 }}>
              <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>Head</div>
              <div style={{ fontFamily: 'monospace', fontSize: 12 }}>
                {shortRoot(data.head.root)} (slot {data.head.slot})
              </div>
            </div>
            <div style={{ padding: 8, background: 'rgba(99,102,241,0.1)', borderRadius: 8 }}>
              <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>Justified</div>
              <div style={{ fontFamily: 'monospace', fontSize: 12 }}>
                {shortRoot(data.justified.root)} (slot {data.justified.slot})
              </div>
            </div>
            <div style={{ padding: 8, background: 'rgba(245,158,11,0.1)', borderRadius: 8 }}>
              <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>Finalized</div>
              <div style={{ fontFamily: 'monospace', fontSize: 12 }}>
                {shortRoot(data.finalized.root)} (slot {data.finalized.slot})
              </div>
            </div>
            <div style={{ padding: 8, background: 'rgba(139,92,246,0.1)', borderRadius: 8 }}>
              <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>Safe target</div>
              <div style={{ fontFamily: 'monospace', fontSize: 12 }}>
                {shortRoot(data.safe_target.root)}
              </div>
            </div>
          </div>
          <div style={{ fontSize: 12, color: 'var(--text-secondary)', marginBottom: 8 }}>
            Validators: {data.validator_count} · Blocks: {data.nodes.length}
          </div>
          <div
            style={{
              fontFamily: 'monospace',
              fontSize: 13,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-all',
            }}
          >
            {roots.length === 0 ? (
              <div style={{ color: 'var(--text-secondary)' }}>No nodes in fork choice</div>
            ) : (
              roots.map((node, i) => (
                <BlockNode
                  key={node.root}
                  node={node}
                  childrenMap={childrenMap}
                  headRoot={data.head.root}
                  justifiedRoot={data.justified.root}
                  finalizedRoot={data.finalized.root}
                  safeTargetRoot={data.safe_target.root}
                  depth={0}
                  isLast={i === roots.length - 1 && (childrenMap.get(node.root)?.length ?? 0) === 0}
                />
              ))
            )}
          </div>
        </div>
    </>
  );
}
