const CASH_FLOW_NODE_ID = "cash_flow_node";
const CASH_FLOW_NODE_NAME = "Cash Flow";

export function sankeyNodeHasChildren(data, nodeId) {
  const graph = buildGraph(data);
  const nodeIndex = graph.indexById.get(nodeId);
  if (nodeIndex === undefined || graph.cashFlowIndex < 0) return false;

  return childIndexesFor(graph, nodeIndex).length > 0;
}

export function zoomSankeyData(data, rootNodeId) {
  const graph = buildGraph(data);
  const rootIndex = graph.indexById.get(rootNodeId);
  if (rootIndex === undefined || graph.cashFlowIndex < 0) return data;

  const includedIndexes = descendantIndexesFor(graph, rootIndex);
  if (includedIndexes.size <= 1) return data;

  const orderedIndexes = graph.nodes
    .map((_, index) => index)
    .filter((index) => includedIndexes.has(index));
  const reindexed = new Map(
    orderedIndexes.map((index, newIndex) => [index, newIndex]),
  );

  return {
    ...data,
    nodes: orderedIndexes.map((index) => ({ ...graph.nodes[index] })),
    links: graph.links
      .filter(
        (link) =>
          includedIndexes.has(link.sourceIndex) &&
          includedIndexes.has(link.targetIndex),
      )
      .map((link) => ({
        ...link.original,
        source: reindexed.get(link.sourceIndex),
        target: reindexed.get(link.targetIndex),
      })),
  };
}

function buildGraph(data) {
  const nodes = data?.nodes || [];
  const links = (data?.links || []).map((link) => {
    const sourceIndex = linkIndex(link.source);
    const targetIndex = linkIndex(link.target);

    return {
      original: link,
      sourceIndex,
      targetIndex,
    };
  });

  const indexById = new Map(
    nodes.map((node, index) => [nodeId(node, index), index]),
  );
  const cashFlowIndex = nodes.findIndex(
    (node) =>
      nodeId(node, -1) === CASH_FLOW_NODE_ID ||
      node.name === CASH_FLOW_NODE_NAME,
  );

  return {
    nodes,
    links,
    indexById,
    cashFlowIndex,
    outbound: groupLinksBy(links, "sourceIndex"),
    inbound: groupLinksBy(links, "targetIndex"),
  };
}

function nodeId(node, index) {
  return node?.id ?? index;
}

function linkIndex(endpoint) {
  return typeof endpoint === "object" ? endpoint.index : endpoint;
}

function groupLinksBy(links, key) {
  const groups = new Map();

  links.forEach((link) => {
    const index = link[key];
    if (!groups.has(index)) groups.set(index, []);
    groups.get(index).push(link);
  });

  return groups;
}

function descendantIndexesFor(graph, rootIndex) {
  const included = new Set([rootIndex]);
  const queue = [rootIndex];

  while (queue.length) {
    const currentIndex = queue.shift();

    childIndexesFor(graph, currentIndex).forEach((childIndex) => {
      if (included.has(childIndex)) return;

      included.add(childIndex);
      queue.push(childIndex);
    });
  }

  return included;
}

function childIndexesFor(graph, nodeIndex) {
  if (nodeIndex === graph.cashFlowIndex) {
    return (graph.outbound.get(nodeIndex) || []).map((link) => link.targetIndex);
  }

  if (canReach(graph, graph.cashFlowIndex, nodeIndex)) {
    return (graph.outbound.get(nodeIndex) || []).map((link) => link.targetIndex);
  }

  if (canReach(graph, nodeIndex, graph.cashFlowIndex)) {
    return (graph.inbound.get(nodeIndex) || []).map((link) => link.sourceIndex);
  }

  return [];
}

function canReach(graph, startIndex, targetIndex) {
  if (startIndex === targetIndex) return true;

  const visited = new Set([startIndex]);
  const queue = [startIndex];

  while (queue.length) {
    const currentIndex = queue.shift();

    for (const link of graph.outbound.get(currentIndex) || []) {
      if (link.targetIndex === targetIndex) return true;
      if (visited.has(link.targetIndex)) continue;

      visited.add(link.targetIndex);
      queue.push(link.targetIndex);
    }
  }

  return false;
}
