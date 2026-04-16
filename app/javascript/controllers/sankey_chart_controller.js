import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { sankey } from "d3-sankey";

// Connects to data-controller="sankey-chart"
export default class extends Controller {
  static values = {
    data: Object,
    nodeWidth: { type: Number, default: 15 },
    nodePadding: { type: Number, default: 20 },
    currencySymbol: { type: String, default: "$" }
  };

  // Visual constants
  static HOVER_OPACITY = 0.4;
  static HOVER_FILTER = "saturate(1.3) brightness(1.1)";
  static EXTENT_MARGIN = 16;
  static MIN_NODE_PADDING = 4;
  static MAX_PADDING_RATIO = 0.4;
  static CORNER_RADIUS = 8;
  static DEFAULT_COLOR = "var(--color-gray-400)";
  static CSS_VAR_MAP = {
    "var(--color-success)": "#10A861",
    "var(--color-destructive)": "#EC2222",
    "var(--color-gray-400)": "#9E9E9E",
    "var(--color-gray-500)": "#737373"
  };
  static SPLIT_ROLE_ORDER = {
    income_sub: 10,
    income: 20,
    transfer_in: 30,
    cash_flow: 40,
    transfer_out: 50,
    expense: 60,
    expense_sub: 70,
    surplus: 80,
    other: 99
  };
  static SPLIT_LABEL_PRIORITY = {
    cash_flow: 0,
    transfer_in: 1,
    transfer_out: 1,
    income: 2,
    expense: 2,
    income_sub: 3,
    expense_sub: 3,
    surplus: 4,
    other: 5
  };
  static MIN_LABEL_SPACING = 28; // Minimum vertical space needed for labels (2 lines)
  static DIALOG_MIN_HEIGHT = 900;
  static DIALOG_MAX_HEIGHT = 2600;
  static DIALOG_NODE_HEIGHT = 42;
  static TRANSFER_OVERLAY_OPACITY = 0.82;
  static TRANSFER_OVERLAY_COLOR_START = "#444CE7";
  static TRANSFER_OVERLAY_COLOR_END = "#9EA4FF";

  connect() {
    this.resizeObserver = new ResizeObserver(() => this.#draw());
    this.resizeObserver.observe(this.element);
    this.tooltip = null;
    this.chartUid = Math.random().toString(36).slice(2, 10);
    this.#createTooltip();
    this.#draw();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    this.tooltip?.remove();
    this.tooltip = null;
  }

  #draw() {
    const { nodes = [], links = [] } = this.dataValue || {};
    if (!nodes.length || !links.length) return;

    this.#ensureDialogChartHeight(nodes.length);

    // Hide tooltip and reset any hover states before redrawing
    this.#hideTooltip();

    d3.select(this.element).selectAll("svg").remove();

    const width = this.element.clientWidth || 600;
    const height = this.element.clientHeight || 400;

    const svg = d3.select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height);

    const effectivePadding = this.#calculateNodePadding(nodes.length, height);
    const sankeyData = this.#generateSankeyData(nodes, links, width, height, effectivePadding);

    this.#createGradients(svg, sankeyData.links);

    const linkPaths = this.#drawLinks(svg, sankeyData.links);
    const transferOverlayPaths = this.#drawTransferOverlays(svg, sankeyData.nodes);
    const { nodeGroups, hiddenLabels } = this.#drawNodes(svg, sankeyData.nodes, width);

    this.#attachHoverEvents(linkPaths, nodeGroups, sankeyData, hiddenLabels, transferOverlayPaths);
  }

  // Dynamic padding prevents padding from dominating when there are many nodes
  #calculateNodePadding(nodeCount, height) {
    const margin = this.constructor.EXTENT_MARGIN;
    const availableHeight = height - (margin * 2);
    const maxPaddingTotal = availableHeight * this.constructor.MAX_PADDING_RATIO;
    const gaps = Math.max(nodeCount - 1, 1);
    const dynamicPadding = Math.min(this.nodePaddingValue, Math.floor(maxPaddingTotal / gaps));
    return Math.max(this.constructor.MIN_NODE_PADDING, dynamicPadding);
  }

  #generateSankeyData(nodes, links, width, height, nodePadding) {
    const margin = this.constructor.EXTENT_MARGIN;
    const sankeyGenerator = sankey()
      .nodeWidth(this.nodeWidthValue)
      .nodePadding(nodePadding)
      .extent([[margin, margin], [width - margin, height - margin]]);

    const splitNodeComparator = this.#buildSplitNodeComparator(nodes);
    if (splitNodeComparator) {
      this.splitLayerConfig = this.#buildSplitLayerConfig(nodes);
      sankeyGenerator.linkSort(this.#buildSplitLinkComparator(nodes));
      sankeyGenerator.nodeAlign((node, n) => this.#splitNodeLayer(node, n));
    } else {
      this.splitLayerConfig = null;
    }

    return sankeyGenerator({
      nodes: nodes.map(d => ({ ...d })),
      links: links.map(d => ({ ...d })),
    });
  }

  #buildSplitNodeComparator(nodes) {
    const hasLaneOrdering = nodes.some(node => Number.isFinite(node?.lane_order));
    if (!hasLaneOrdering) return null;

    return (a, b) => {
      const laneA = Number.isFinite(a?.lane_order) ? a.lane_order : Number.MAX_SAFE_INTEGER;
      const laneB = Number.isFinite(b?.lane_order) ? b.lane_order : Number.MAX_SAFE_INTEGER;
      if (laneA !== laneB) return laneA - laneB;

      const roleA = this.constructor.SPLIT_ROLE_ORDER[a?.node_role] ?? this.constructor.SPLIT_ROLE_ORDER.other;
      const roleB = this.constructor.SPLIT_ROLE_ORDER[b?.node_role] ?? this.constructor.SPLIT_ROLE_ORDER.other;
      if (roleA !== roleB) return roleA - roleB;

      return String(a?.name || "").localeCompare(String(b?.name || ""));
    };
  }

  #buildSplitLinkComparator(nodes) {
    return (a, b) => {
      const sourceLaneA = this.#splitLaneOrderForEndpoint(a?.source, nodes);
      const sourceLaneB = this.#splitLaneOrderForEndpoint(b?.source, nodes);
      if (sourceLaneA !== sourceLaneB) return sourceLaneA - sourceLaneB;

      const targetLaneA = this.#splitLaneOrderForEndpoint(a?.target, nodes);
      const targetLaneB = this.#splitLaneOrderForEndpoint(b?.target, nodes);
      if (targetLaneA !== targetLaneB) return targetLaneA - targetLaneB;

      const sourceRoleA = this.#splitRoleOrderForEndpoint(a?.source, nodes);
      const sourceRoleB = this.#splitRoleOrderForEndpoint(b?.source, nodes);
      if (sourceRoleA !== sourceRoleB) return sourceRoleA - sourceRoleB;

      return d3.descending(a?.value ?? 0, b?.value ?? 0);
    };
  }

  #splitNodeLayer(node, columns) {
    const layerConfig = this.splitLayerConfig || { left: 0, middle: 0, right: 0 };
    const maxColumn = Math.max(0, (Number.isFinite(columns) && columns > 0 ? columns : 1) - 1);
    const role = node?.node_role;

    if (role === "cash_flow") return Math.min(maxColumn, layerConfig.middle);

    if (this.#isSplitLeftRole(role)) {
      return Math.min(maxColumn, layerConfig.left);
    }

    if (this.#isSplitRightRole(role)) {
      return Math.min(maxColumn, layerConfig.right);
    }

    return Math.min(maxColumn, layerConfig.middle);
  }

  #buildSplitLayerConfig(nodes) {
    const hasLeftColumn = nodes.some(node => this.#isSplitLeftRole(node?.node_role));
    const hasRightColumn = nodes.some(node => this.#isSplitRightRole(node?.node_role));

    if (hasLeftColumn && hasRightColumn) {
      return { left: 0, middle: 1, right: 2 };
    }

    if (hasLeftColumn) {
      return { left: 0, middle: 1, right: 1 };
    }

    if (hasRightColumn) {
      return { left: 0, middle: 0, right: 1 };
    }

    return { left: 0, middle: 0, right: 0 };
  }

  #isSplitLeftRole(role) {
    return role === "income" || role === "income_sub" || role === "transfer_in";
  }

  #isSplitRightRole(role) {
    return role === "expense" || role === "expense_sub" || role === "transfer_out" || role === "surplus";
  }

  #splitLaneOrderForEndpoint(endpoint, nodes) {
    if (Number.isFinite(endpoint?.lane_order)) return endpoint.lane_order;
    if (Number.isFinite(endpoint)) return nodes[endpoint]?.lane_order ?? Number.MAX_SAFE_INTEGER;
    return Number.MAX_SAFE_INTEGER;
  }

  #splitRoleOrderForEndpoint(endpoint, nodes) {
    const role = endpoint?.node_role || (Number.isFinite(endpoint) ? nodes[endpoint]?.node_role : null);
    return this.constructor.SPLIT_ROLE_ORDER[role] ?? this.constructor.SPLIT_ROLE_ORDER.other;
  }

  #createGradients(svg, links) {
    const defs = svg.append("defs");

    links.forEach((link, i) => {
      const gradientId = this.#gradientId(link, i);
      const isTransferFlow = link?.flow_type === "transfer_in" || link?.flow_type === "transfer_out";
      const gradientOpacity = isTransferFlow ? 0.2 : 0.1;
      const sourceColor = isTransferFlow ? link.color : link.source.color;
      const targetColor = isTransferFlow ? link.color : link.target.color;
      const gradient = defs.append("linearGradient")
        .attr("id", gradientId)
        .attr("gradientUnits", "userSpaceOnUse")
        .attr("x1", link.source.x1)
        .attr("x2", link.target.x0);

      gradient.append("stop")
        .attr("offset", "0%")
        .attr("stop-color", this.#colorWithOpacity(sourceColor, gradientOpacity));

      gradient.append("stop")
        .attr("offset", "100%")
        .attr("stop-color", this.#colorWithOpacity(targetColor, gradientOpacity));
    });
  }

  #gradientId(link, index) {
    return `link-gradient-${link.source.index}-${link.target.index}-${index}`;
  }

  #colorWithOpacity(nodeColor, opacity = 0.1) {
    const defaultColor = this.constructor.DEFAULT_COLOR;
    let colorStr = nodeColor || defaultColor;

    // Map CSS variables to hex values for d3 color manipulation
    colorStr = this.constructor.CSS_VAR_MAP[colorStr] || colorStr;

    // Unmapped CSS vars cannot be manipulated, return as-is
    if (colorStr.startsWith("var(--")) return colorStr;

    const d3Color = d3.color(colorStr);
    return d3Color ? d3Color.copy({ opacity }) : defaultColor;
  }

  #drawLinks(svg, links) {
    return svg.append("g")
      .attr("fill", "none")
      .selectAll("path")
      .data(links)
      .join("path")
      .attr("class", "sankey-link")
      .attr("d", d => d3.linkHorizontal()({
        source: [d.source.x1, d.y0],
        target: [d.target.x0, d.y1]
      }))
      .attr("stroke", (d, i) => `url(#${this.#gradientId(d, i)})`)
      .attr("stroke-width", d => Math.max(1, d.width))
      .style("transition", "opacity 0.3s ease");
  }

  #drawTransferOverlays(svg, nodes) {
    const overlays = Array.isArray(this.dataValue?.transfer_overlays) ? this.dataValue.transfer_overlays : [];
    const validOverlays = overlays.filter((overlay) => (
      Number.isFinite(overlay?.source)
      && Number.isFinite(overlay?.target)
      && overlay.source !== overlay.target
      && nodes[overlay.source]
      && nodes[overlay.target]
      && Number(overlay.value) > 0
    ));

    if (!validOverlays.length) return null;

    const defs = this.#ensureTransferOverlayDefs(svg);
    const gradientId = this.#transferOverlayGradientId();
    const markerId = this.#transferOverlayMarkerId();
    const maxValue = d3.max(validOverlays, d => Number(d.value)) || 1;
    const widthScale = d3.scaleLinear().domain([0, maxValue]).range([1.5, 8]);

    const overlayGroup = svg.append("g").attr("class", "sankey-transfer-overlays");

    return overlayGroup.selectAll("path")
      .data(validOverlays)
      .join("path")
      .attr("class", "sankey-transfer-overlay")
      .attr("d", d => this.#transferOverlayPath(d, nodes))
      .attr("fill", "none")
      .attr("stroke", `url(#${gradientId})`)
      .attr("stroke-width", d => widthScale(Number(d.value)))
      .attr("stroke-linecap", "round")
      .attr("stroke-opacity", this.constructor.TRANSFER_OVERLAY_OPACITY)
      .attr("marker-end", `url(#${markerId})`)
      .style("pointer-events", "stroke")
      .style("transition", "opacity 0.3s ease");
  }

  #transferOverlayPath(overlay, nodes) {
    const sourceNode = nodes[overlay.source];
    const targetNode = nodes[overlay.target];
    if (!sourceNode || !targetNode) return "";

    const sourceX = sourceNode.x1;
    const targetX = targetNode.x0;
    const sourceY = (sourceNode.y0 + sourceNode.y1) / 2;
    const targetY = (targetNode.y0 + targetNode.y1) / 2;
    const turnOffset = Math.max(90, Math.abs(sourceY - targetY) * 0.55);
    const turnX = Math.max(sourceX, targetX) + turnOffset;

    return `M ${sourceX},${sourceY} C ${turnX},${sourceY} ${turnX},${targetY} ${targetX},${targetY}`;
  }

  #ensureTransferOverlayDefs(svg) {
    const defs = svg.select("defs").empty() ? svg.append("defs") : svg.select("defs");
    const gradientId = this.#transferOverlayGradientId();
    const markerId = this.#transferOverlayMarkerId();

    if (defs.select(`#${gradientId}`).empty()) {
      const gradient = defs.append("linearGradient")
        .attr("id", gradientId)
        .attr("gradientUnits", "objectBoundingBox")
        .attr("x1", "0%")
        .attr("x2", "100%")
        .attr("y1", "0%")
        .attr("y2", "0%");

      gradient.append("stop")
        .attr("offset", "0%")
        .attr("stop-color", this.constructor.TRANSFER_OVERLAY_COLOR_START)
        .attr("stop-opacity", 0.95);

      gradient.append("stop")
        .attr("offset", "100%")
        .attr("stop-color", this.constructor.TRANSFER_OVERLAY_COLOR_END)
        .attr("stop-opacity", 0.8);
    }

    if (defs.select(`#${markerId}`).empty()) {
      defs.append("marker")
        .attr("id", markerId)
        .attr("viewBox", "0 -5 10 10")
        .attr("refX", 9)
        .attr("refY", 0)
        .attr("markerWidth", 7)
        .attr("markerHeight", 7)
        .attr("orient", "auto")
        .append("path")
        .attr("d", "M0,-5L10,0L0,5")
        .attr("fill", this.constructor.TRANSFER_OVERLAY_COLOR_START)
        .attr("fill-opacity", 0.9);
    }

    return defs;
  }

  #transferOverlayGradientId() {
    return `transfer-overlay-gradient-${this.chartUid}`;
  }

  #transferOverlayMarkerId() {
    return `transfer-overlay-arrow-${this.chartUid}`;
  }

  #drawNodes(svg, nodes, width) {
    const nodeGroups = svg.append("g")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .style("transition", "opacity 0.3s ease");

    nodeGroups.append("path")
      .attr("d", d => this.#nodePath(d))
      .attr("fill", d => d.color || this.constructor.DEFAULT_COLOR)
      .attr("stroke", d => d.color ? "none" : "var(--color-gray-500)");

    const hiddenLabels = this.#addNodeLabels(nodeGroups, width, nodes);

    return { nodeGroups, hiddenLabels };
  }

  #nodePath(node) {
    const { x0, y0, x1, y1 } = node;
    const height = y1 - y0;
    const radius = Math.max(0, Math.min(this.constructor.CORNER_RADIUS, height / 2));

    const isSourceNode = node.sourceLinks?.length > 0 && !node.targetLinks?.length;
    const isTargetNode = node.targetLinks?.length > 0 && !node.sourceLinks?.length;

    // Too small for rounded corners
    if (height < radius * 2) {
      return this.#rectPath(x0, y0, x1, y1);
    }

    if (isSourceNode) {
      return this.#roundedLeftPath(x0, y0, x1, y1, radius);
    }

    if (isTargetNode) {
      return this.#roundedRightPath(x0, y0, x1, y1, radius);
    }

    return this.#rectPath(x0, y0, x1, y1);
  }

  #rectPath(x0, y0, x1, y1) {
    return `M ${x0},${y0} L ${x1},${y0} L ${x1},${y1} L ${x0},${y1} Z`;
  }

  #roundedLeftPath(x0, y0, x1, y1, r) {
    return `M ${x0 + r},${y0}
            L ${x1},${y0}
            L ${x1},${y1}
            L ${x0 + r},${y1}
            Q ${x0},${y1} ${x0},${y1 - r}
            L ${x0},${y0 + r}
            Q ${x0},${y0} ${x0 + r},${y0} Z`;
  }

  #roundedRightPath(x0, y0, x1, y1, r) {
    return `M ${x0},${y0}
            L ${x1 - r},${y0}
            Q ${x1},${y0} ${x1},${y0 + r}
            L ${x1},${y1 - r}
            Q ${x1},${y1} ${x1 - r},${y1}
            L ${x0},${y1} Z`;
  }

  #addNodeLabels(nodeGroups, width, nodes) {
    const controller = this;
    const hiddenLabels = this.#calculateHiddenLabels(nodes);

    nodeGroups.append("text")
      .attr("x", d => d.x0 < width / 2 ? d.x1 + 6 : d.x0 - 6)
      .attr("y", d => (d.y1 + d.y0) / 2)
      .attr("dy", "-0.2em")
      .attr("text-anchor", d => d.x0 < width / 2 ? "start" : "end")
      .attr("class", "text-xs font-medium text-primary fill-current select-none")
      .style("cursor", "default")
      .style("opacity", d => hiddenLabels.has(d.index) ? 0 : 1)
      .style("transition", "opacity 0.2s ease")
      .each(function (d) {
        const textEl = d3.select(this);
        textEl.selectAll("tspan").remove();

        textEl.append("tspan").text(d.name);

        textEl.append("tspan")
          .attr("x", textEl.attr("x"))
          .attr("dy", "1.2em")
          .attr("class", "font-mono text-secondary")
          .style("font-size", "0.65rem")
          .text(controller.#formatCurrency(d.value));
      });

    return hiddenLabels;
  }

  #ensureDialogChartHeight(nodeCount) {
    if (!this.#isInDialog()) return;

    const preferredHeight = Math.max(
      this.constructor.DIALOG_MIN_HEIGHT,
      Math.min(this.constructor.DIALOG_MAX_HEIGHT, nodeCount * this.constructor.DIALOG_NODE_HEIGHT)
    );

    const currentHeight = Number.parseInt(this.element.style.height, 10);
    if (currentHeight !== preferredHeight) {
      this.element.style.height = `${preferredHeight}px`;
    }
  }

  #isInDialog() {
    return Boolean(this.element.closest("dialog"));
  }

  // Calculate which labels should be hidden to prevent overlap
  #calculateHiddenLabels(nodes) {
    const hiddenLabels = new Set();
    const height = this.element.clientHeight || 400;
    const isLargeGraph = height > 600;
    const minSpacing = isLargeGraph ? this.constructor.MIN_LABEL_SPACING * 0.7 : this.constructor.MIN_LABEL_SPACING;

    // Group nodes by column (using depth which d3-sankey assigns)
    const columns = new Map();
    nodes.forEach(node => {
      const depth = node.depth;
      if (!columns.has(depth)) columns.set(depth, []);
      columns.get(depth).push(node);
    });

    // For each column, check for overlapping labels
    columns.forEach(columnNodes => {
      // Sort by vertical position
      columnNodes.sort((a, b) => ((a.y0 + a.y1) / 2) - ((b.y0 + b.y1) / 2));

      let lastVisible = null;

      columnNodes.forEach(node => {
        const nodeY = (node.y0 + node.y1) / 2;
        const nodeHeight = node.y1 - node.y0;
        const currentPriority = this.#labelPriority(node);

        if (isLargeGraph && nodeHeight > minSpacing * 1.5) {
          lastVisible = { node, y: nodeY };
          return;
        }

        if (!lastVisible) {
          lastVisible = { node, y: nodeY };
          return;
        }

        if (nodeY - lastVisible.y < minSpacing) {
          // If labels overlap, keep the higher-priority one for stable split-lane readability.
          const lastPriority = this.#labelPriority(lastVisible.node);
          if (currentPriority < lastPriority) {
            hiddenLabels.add(lastVisible.node.index);
            lastVisible = { node, y: nodeY };
          } else {
            hiddenLabels.add(node.index);
          }
          return;
        }

        lastVisible = { node, y: nodeY };
      });
    });

    return hiddenLabels;
  }

  #labelPriority(node) {
    if (!Number.isFinite(node?.lane_order)) return 50;

    return this.constructor.SPLIT_LABEL_PRIORITY[node?.node_role] ?? this.constructor.SPLIT_LABEL_PRIORITY.other;
  }

  #attachHoverEvents(linkPaths, nodeGroups, sankeyData, hiddenLabels, transferOverlayPaths = null) {
    const applyHover = (targetLinks) => {
      const targetSet = new Set(targetLinks);
      const connectedNodes = new Set(targetLinks.flatMap(l => [l.source, l.target]));

      linkPaths
        .style("opacity", d => targetSet.has(d) ? 1 : this.constructor.HOVER_OPACITY)
        .style("filter", d => targetSet.has(d) ? this.constructor.HOVER_FILTER : "none");

      nodeGroups.style("opacity", d => connectedNodes.has(d) ? 1 : this.constructor.HOVER_OPACITY);

      transferOverlayPaths
        ?.style("opacity", this.constructor.HOVER_OPACITY)
        .style("filter", "none");

      // Show labels for connected nodes (even if normally hidden)
      nodeGroups.selectAll("text")
        .style("opacity", d => connectedNodes.has(d) ? 1 : (hiddenLabels.has(d.index) ? 0 : this.constructor.HOVER_OPACITY));
    };

    const resetHover = () => {
      linkPaths.style("opacity", 1).style("filter", "none");
      nodeGroups.style("opacity", 1);
      transferOverlayPaths
        ?.style("opacity", this.constructor.TRANSFER_OVERLAY_OPACITY)
        .style("filter", "none");

      // Restore hidden labels to hidden state
      nodeGroups.selectAll("text")
        .style("opacity", d => hiddenLabels.has(d.index) ? 0 : 1);
    };

    linkPaths
      .on("mouseenter", (event, d) => {
        applyHover([d]);
        this.#showTooltip(event, d.value, d.percentage, this.#linkTooltipTitle(d));
      })
      .on("mousemove", event => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });

    // Hover on node rectangles (not just text)
    nodeGroups.selectAll("path")
      .style("cursor", "default")
      .on("mouseenter", (event, d) => {
        const connectedLinks = sankeyData.links.filter(l => l.source === d || l.target === d);
        applyHover(connectedLinks);
        this.#showTooltip(event, d.value, d.percentage, d.name);
      })
      .on("mousemove", event => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });

    nodeGroups.selectAll("text")
      .on("mouseenter", (event, d) => {
        const connectedLinks = sankeyData.links.filter(l => l.source === d || l.target === d);
        applyHover(connectedLinks);
        this.#showTooltip(event, d.value, d.percentage, d.name);
      })
      .on("mousemove", event => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });

    transferOverlayPaths
      ?.on("mouseenter", (event, d) => {
        const sourceNode = sankeyData.nodes[d.source];
        const targetNode = sankeyData.nodes[d.target];
        const sourceName = d.source_name || sourceNode?.name || "Source account";
        const targetName = d.target_name || targetNode?.name || "Destination account";
        const connectedNodeIndices = new Set([ d.source, d.target ]);

        linkPaths.style("opacity", this.constructor.HOVER_OPACITY).style("filter", "none");
        transferOverlayPaths.style("opacity", overlay => (overlay === d ? 1 : this.constructor.HOVER_OPACITY));
        nodeGroups.style("opacity", node => connectedNodeIndices.has(node.index) ? 1 : this.constructor.HOVER_OPACITY);
        nodeGroups.selectAll("text")
          .style("opacity", node => connectedNodeIndices.has(node.index) ? 1 : (hiddenLabels.has(node.index) ? 0 : this.constructor.HOVER_OPACITY));

        this.#showTooltip(event, d.value, null, `${sourceName} -> ${targetName}`);
      })
      .on("mousemove", event => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });
  }

  // Tooltip methods

  #createTooltip() {
    const dialog = this.element.closest("dialog");
    this.tooltip = d3.select(dialog || document.body)
      .append("div")
      .attr("class", "bg-gray-700 text-white text-sm p-2 rounded pointer-events-none absolute z-50 top-0")
      .style("opacity", 0)
      .style("pointer-events", "none");
  }

  #showTooltip(event, value, percentage, title = null) {
    if (!this.tooltip) this.#createTooltip();

    const hasPercentage = Number.isFinite(Number(percentage));
    const valueText = hasPercentage
      ? `${this.#formatCurrency(value)} (${percentage || 0}%)`
      : `${this.#formatCurrency(value)}`;

    const content = title
      ? `${title}<br/>${valueText}`
      : valueText;

    const isInDialog = this.#isInDialog();
    const x = isInDialog ? event.clientX : event.pageX;
    const y = isInDialog ? event.clientY : event.pageY;

    this.tooltip
      .html(content)
      .style("position", isInDialog ? "fixed" : "absolute")
      .style("left", `${x + 10}px`)
      .style("top", `${y - 10}px`)
      .transition()
      .duration(100)
      .style("opacity", 1);
  }

  #updateTooltipPosition(event) {
    if (this.tooltip) {
      const isInDialog = this.#isInDialog();
      const x = isInDialog ? event.clientX : event.pageX;
      const y = isInDialog ? event.clientY : event.pageY;

      this.tooltip
        ?.style("left", `${x + 10}px`)
        .style("top", `${y - 10}px`);
    }
  }

  #hideTooltip() {
    if (this.tooltip) {
      this.tooltip
        ?.transition()
        .duration(100)
        .style("opacity", 0)
        .style("pointer-events", "none");
    }
  }

  #formatCurrency(value) {
    const formatted = Number.parseFloat(value).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
    return this.currencySymbolValue + formatted;
  }

  #linkTooltipTitle(link) {
    const sourceName = link?.source?.name || "Source";
    const targetName = link?.target?.name || "Destination";
    return `${sourceName} -> ${targetName}`;
  }
}
