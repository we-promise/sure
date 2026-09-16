// Compare financial inputs before D3 mutates them. IDs replace array indexes;
// amounts use the legacy chart's two-decimal precision (percentages use one).
// Labels, colors, API-only metadata and layout coordinates are not compared.
export function compareSankeyData(legacy, preview) {
  try {
    const aliases = syntheticAliases(preview);
    return JSON.stringify(normalize(legacy, aliases)) === JSON.stringify(normalize(preview))
      ? "match"
      : "mismatch";
  } catch {
    // Missing or invalid inputs are not evidence of a financial mismatch.
    return null;
  }
}

// Legacy synthetic IDs contain translated names; real categories use UUIDs.
// Alias only the known synthetic categories, never arbitrary category names.
function syntheticAliases(preview) {
  const aliases = new Map();
  for (const node of preview.nodes) {
    if (/^(income|expense)_(uncategorized|other_investments)$/.test(node.id) &&
      node.category_id == null && typeof node.name === "string") {
      const side = node.id.split("_")[0];
      aliases.set(`${side}_${node.name}`, node.id);
    }
  }
  return aliases;
}

function normalize(graph, aliases = new Map()) {
  if (!Array.isArray(graph?.nodes) || !Array.isArray(graph?.links))
    throw new Error("Missing graph");
  const ids = new Set();
  const nodes = graph.nodes.map((node) => {
    const id = aliases.get(node.id) || node.id;
    if (typeof id !== "string" || ids.has(id))
      throw new Error("Invalid node identity");
    ids.add(id);
    return [id, number(node.value, 2), number(node.percentage, 1)];
  });
  const links = graph.links.map((link) => {
    const endpoints = [link.source, link.target].map((index) => {
      if (!Number.isInteger(index) || !nodes[index])
        throw new Error("Invalid endpoint");
      return nodes[index][0];
    });
    return [...endpoints, number(link.value, 2), number(link.percentage, 1)];
  });
  // The legacy builder emits a zero-valued center even when no chart is drawn.
  const visibleNodes = links.length ? nodes : nodes.filter((node) => node[1] !== 0);
  const sort = (items) => items.map((item) => JSON.stringify(item)).sort();
  return { nodes: sort(visibleNodes), links: sort(links) };
}

function number(value, precision) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0)
    throw new Error("Invalid numeric value");
  // Shift the decimal before rounding to avoid cases such as 1.005 * 100
  // becoming 100.49999999999999. Handle scientific notation as well.
  const [coefficient, exponent = "0"] = String(value).split("e");
  const shifted = Number(`${coefficient}e${Number(exponent) + precision}`);
  if (!Number.isFinite(shifted)) throw new Error("Value exceeds comparison range");
  return Math.round(shifted) / 10 ** precision;
}
