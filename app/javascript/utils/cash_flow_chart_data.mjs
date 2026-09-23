// Decimal strings remain authoritative on the wire. Conversion to Number is
// exclusively for D3 geometry and locale formatting, never financial totals.
export function cashFlowChartData(body) {
  const graph = body.sankey;
  if (
    !/^[A-Z]{3,5}$/.test(body.currency) ||
    graph?.basis !== "net_by_category" ||
    !Array.isArray(graph.nodes) ||
    !Array.isArray(graph.links)
  ) {
    throw new Error("Invalid cash flow graph");
  }
  const number = (value) => {
    if (
      typeof value !== "string" ||
      !/^\d+(\.\d+)?$/.test(value) ||
      !Number.isFinite(Number(value))
    ) {
      throw new Error("Invalid cash flow value");
    }
    return Number(value);
  };
  const ids = new Set();
  const nodes = graph.nodes.map((node) => {
    if (
      typeof node.id !== "string" ||
      ids.has(node.id) ||
      typeof node.name !== "string" ||
      !["income", "expense", "cash_flow", "surplus", "deficit"].includes(
        node.kind,
      )
    ) {
      throw new Error("Invalid cash flow node");
    }
    ids.add(node.id);
    const color = /^#[0-9a-f]{6}$/i.test(node.color)
      ? node.color
      : ["expense", "deficit"].includes(node.kind)
        ? "var(--color-destructive)"
        : "var(--color-success)";
    const value = number(node.value),
      percentage = number(node.percentage);
    if (value <= 0 || percentage > 100)
      throw new Error("Invalid cash flow node value");
    return { ...node, value, percentage, color };
  });
  const links = graph.links.map((link) => {
    if (
      ![link.source, link.target].every(
        (index) =>
          Number.isInteger(index) && index >= 0 && index < nodes.length,
      ) ||
      link.source === link.target
    ) {
      throw new Error("Invalid cash flow link");
    }
    const value = number(link.value),
      percentage = number(link.percentage);
    if (value <= 0 || percentage > 100)
      throw new Error("Invalid cash flow link value");
    return { ...link, value, percentage };
  });
  const indegree = nodes.map(() => 0);
  const outgoing = nodes.map(() => []);
  links.forEach(({ source, target }) => {
    indegree[target]++;
    outgoing[source].push(target);
  });
  const queue = indegree.flatMap((count, index) =>
    count === 0 ? [index] : [],
  );
  for (let i = 0; i < queue.length; i++) {
    outgoing[queue[i]].forEach((target) => {
      if (--indegree[target] === 0) queue.push(target);
    });
  }
  if (queue.length !== nodes.length) throw new Error("Cyclic cash flow graph");
  return { nodes, links };
}

// Sure also supports currencies (such as DOGE/USDC) outside Intl's three-letter
// currency identifiers. Preserve the unit in that display-only fallback.
export function formatCashFlowCurrency(value, currency, locale) {
  try {
    return Number(value).toLocaleString(locale, {
      style: "currency",
      currency,
    });
  } catch (error) {
    if (!(error instanceof RangeError)) throw error;
    return `${Number(value).toLocaleString(locale, { maximumFractionDigits: 8 })} ${currency}`;
  }
}
